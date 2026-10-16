# Architecture

Calendario is a native macOS app (SwiftUI, macOS 15+). The Mac's calendar database is
the source of truth: every account in System Settings > Internet Accounts reaches the
app through EventKit, and the system does all syncing. The app adds one direct server
connection, to Google, for the two things EventKit can't do: Google Meet links and
invitees.

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│ App (Calendario/)                                  macOS only │
│  Views (SwiftUI)  ·  stores (@Observable)  ·  menus, menu bar │
│  CalendarStore · ReminderStore · GoogleAccountsStore · EventSaver
└──────────────┬──────────────────────────┬────────────────────┘
               │ protocols                │ concrete client
┌──────────────▼───────────┐  ┌───────────▼────────────────────┐
│ EventKitProvider         │  │ GoogleCalendarAPI              │
│ CalendarProvider +       │  │ OAuth + PKCE, token refresh,   │
│ TaskProvider on EventKit │  │ Calendar API v3, Keychain store│
│ macOS only               │  │ Foundation (+ Keychain on Mac) │
└──────────────┬───────────┘  └───────────┬────────────────────┘
               └──────────┬───────────────┘
┌─────────────────────────▼────────────────────────────────────┐
│ CalendarDomain                                Foundation only │
│ Event, TaskItem, CalendarInfo, CalendarSource, RecurrenceRule │
│ EventDraft, TaskDraft, EditScope, SaveRoute, PendingEvents    │
│ CalendarMath, DayLayout, TaskLayout, CalendarMatcher          │
│ CalendarProvider / TaskProvider protocols                     │
└──────────────────────────────────────────────────────────────┘
```

The three lower layers are targets of the Swift package `Packages/CalendarKit`; the app
target links them.

### CalendarDomain (portable)

Our own types and all pure logic, with no EventKit, SwiftUI or AppKit. Conventions every
layer relies on:

- Event `end` is exclusive. All-day events run from local midnight to the next
  midnight. EventKit's "23:59:59" all-day ends are normalized on the way in and out.
- `timeZone == nil` means floating time.
- Day arithmetic always goes through the injected `Calendar`, so week start, time zone
  and DST come from the system. Nothing adds 86,400 seconds.
- `DateInterval.containsHalfOpen` is used instead of `contains`, which includes the end.

Logic that lives here, and is unit-tested:

- **Date math and layout:** week start, DST days, the month grid, day bucketing, and overlap columns.
- **Event drafts:** edit scopes for repeating events, repeat presets, alert presets, and the reminder due-date rules.
- **Google matching:** matching Mac calendars to Google calendars, deciding where a save goes (`SaveRoute`), and de-duplication (`PendingEvents`).

### Provider protocols

`CalendarProvider` and `TaskProvider` are the only way the UI reads or writes data.
Every call is `async` (a network-backed provider needs it). It also keeps the UI
responsive: EventKit's calls block on a system daemon, and once froze the app's launch
when that daemon stalled.

### EventKitProvider (macOS)

One `EKEventStore` for events and reminders. It maps EventKit objects to domain types
in `EventKitMapping`, the only file that knows both. Notes:

- Editing "this event" looks up the exact occurrence by date. `event(withIdentifier:)`
  returns the first occurrence of a series.
- Repeat rules are written only when they changed. Reminder alarms are written only
  when they changed, so location-based alerts survive.
- `EKEventStoreChanged` feeds `changes()`. The stores reload and bump a `revision` that
  windows key their loads on.

### GoogleCalendarAPI

- **OAuth 2.0 with PKCE** for an "iOS"-type client, which has no client secret. The
  redirect goes to the reversed client ID scheme. The scopes are
  `calendar.events.owned` and `calendar.calendarlist.readonly`, plus `openid email`.
- **`GoogleAuthService`** (an actor) stores one credential per account email. It
  refreshes tokens silently, one refresh per account at a time. On `invalid_grant` it
  marks the account "needs reconnect".
- **`GoogleCalendarClient`** lists owned calendars and creates events
  (`conferenceDataVersion=1`, Meet `createRequest`). It updates an event by looking it
  up by iCalUID and sending a PATCH with only the changed fields.
- **HTTP is behind a protocol**, so all of it is tested without the network.
- **The Keychain store** (`KeychainTokenStore`) is the only Apple-specific part.

### App

- **`CalendarStore` / `ReminderStore`:** access status, accounts, lists, hidden
  calendars, writes, and a `revision` counter.
- **`WindowState`:** per window, it holds the period, date, loaded events and tasks,
  and open editors. Menu commands reach the frontmost window through `FocusedValues`.
- **`EventSaver`:** asks `SaveRoute` where a change goes. Ordinary edits go through
  EventKit. Only a new Meet link or an invitee change goes through Google, so an event
  is never written twice.
- **Pending events:** an event created through Google is shown at once from
  `PendingEvents`, then dropped when the synced copy with the same iCalUID arrives (or
  after 15 minutes). The app also asks EventKit to refresh.
- **`SyncMonitor`:** EventKit hides sync errors, so for each connected Google account
  the app asks Google which events changed in the last 3 days (`updatedMin`,
  occurrences expanded). It then checks those iCalUIDs against the system calendar
  (`SyncHealth.evaluate`). Changes older than 45 minutes that are still missing mean
  macOS has stopped syncing that account, and a banner says so. Deleted events and
  Google-only event types are skipped. The check runs every 15 minutes, every 2 while
  an account is behind, and on ⌘R. It only reads.
- **Colors:** custom calendar and list colors are Calendario-only (`ColorOverrides` in
  user defaults), applied over the account colors from EventKit. Apple Calendar and
  other devices are unaffected.
- **Concurrency:** UI code is main-actor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION`).
  Callbacks the system runs on background queues must be explicitly `@Sendable`; one
  that wasn't crashed the Google sign-in.

## Apple API restrictions

These are limits of the platform, not bugs:

| Restriction | What the app does |
|---|---|
| EventKit can't add or remove invitees (`EKParticipant` is read-only). | Shows invitees read-only. For connected Google calendars, invitee changes go through the Google API. |
| EventKit can't send invitation responses (the user's own `EKParticipant` status is read-only too). | Accept / Maybe / Decline goes through the Google API (only your own `responseStatus` changes; for repeating events, just that occurrence). There's no way to respond to Exchange or iCloud invitations from here. |
| EventKit can't create conference links. | Meet links are created through the Google API. |
| EventKit exposes neither the server nor the server's calendar IDs. | Google calendars are matched by account email and calendar name. Duplicate names are skipped, not guessed. |
| No public API for an account's sync errors. | For connected Google accounts, `SyncMonitor` compares recent changes on Google with what EventKit has, and warns if changes older than 45 minutes are missing. Other accounts (iCloud, Exchange) can still go stale silently. |
| Reminders: subtasks, tags, sections, flags and early-reminder settings aren't exposed. | Not shown. The repeat rules of repeating reminders are shown and kept, but not editable. |
| The permission dialog only appears while the app is frontmost. | Access is requested when the user clicks "Allow Access…", never automatically at launch. |
| EventKit event queries span at most 4 years. | Views never ask for more than about 6 weeks at a time. |
| Ad-hoc signing changes the app's identity on every build. | Use a (free) Personal Team so permissions and Keychain items persist. |

## A Windows client

The plan, as agreed: keep this native Mac app, and build a separate Windows app later.
This section lists what carries over and what has to be replaced.

**Carries over as design (or as code, if the Windows app uses Swift):**

- `CalendarDomain`: all of it. It's Foundation-only. `ConferenceLink` deliberately
  uses a Swift regex instead of `NSDataDetector`, which Windows Foundation lacks.
- `GoogleCalendarAPI`: OAuth, the token service and the API client are Foundation-only.
  They need a SHA-256 implementation (e.g. swift-crypto instead of CryptoKit) and a
  `TokenStore` on Windows Credential Manager.
- The provider protocols, `SaveRoute`, `PendingEvents` and the tests that pin the
  behavior (DST, all-day ends, recurrence mapping, de-duplication).

If the Windows app is written in C# (WinUI/.NET), these become a specification to port,
and the unit tests are the most useful part to translate.

**Must be replaced, because EventKit and Apple Reminders don't exist on Windows:**

| Mac today | Windows replacement |
|---|---|
| `EventKitProvider` (all accounts, system sync) | One `CalendarProvider` per service, each doing its own sync: Google Calendar API (`events.list` with `syncToken`), Microsoft Graph (`/me/calendarView`, delta queries), CalDAV for iCloud (app-specific password). |
| Apple Reminders (`TaskProvider`) | Google Tasks API or Microsoft To Do (Graph). iCloud Reminders has no public API outside Apple platforms. |
| Internet Accounts (sign-in to every service) | The app signs in to each service itself, and stores tokens in Credential Manager. |
| Google OAuth: iOS client, custom-scheme redirect | Google's "Desktop app" client with a loopback redirect (`http://127.0.0.1:port`). Note that Google's token endpoint requires that client type's (non-confidential) client secret. |
| `ASWebAuthenticationSession` | The system browser plus a local loopback listener. |
| Keychain | Windows Credential Manager. |
| Local cache: none needed (EventKit is the cache) | A local store (e.g. SQLite) for offline use and incremental sync. |
| SwiftUI views, menu bar extra | WinUI views, notification-area icon. |

The biggest new piece of work on Windows is sync: on the Mac, macOS does it for every
account; on Windows the app must fetch, cache and merge changes for each service.

## Demo mode

`-demo YES` swaps in `DemoProvider` (fictional calendars, events and reminders relative
to the current week), and treats two of its calendars as connected to Google. Nothing
reaches EventKit, the Keychain or the network. `scripts/screenshots.sh` builds a demo
copy under its own bundle ID (its own sandbox container), stages each view with
`-demoStage YES` and has the app render its own window. Translucent materials (glass
toolbar backgrounds, the sidebar, popovers) can't be rendered that way, so staged runs
use opaque backgrounds and a plain sidebar layout.

## Tests

`swift test --package-path Packages/CalendarKit`, or ⌘U in Xcode. Covered: date math
and layout, edit scopes, repeat presets, reminder rules, Google matching, save routing,
de-duplication, meeting link detection, OAuth/PKCE, token refresh, request bodies and
RRULE generation. Anything that needs real accounts is in the manual checklists, run
per milestone.
