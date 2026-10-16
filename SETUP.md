# Setup

`scripts/install.sh` does all of this interactively (see the README). These are the
same steps by hand.

Everything you need to do yourself, once, to build Calendario and use its Google
features. Calendars and reminders themselves need no setup beyond the accounts in
**System Settings > Internet Accounts**.

## 1. Build and sign (free Apple ID)

1. Install Xcode 26 and sign in with your Apple ID in **Xcode > Settings > Accounts**.
   A free account gives you a "Personal Team"; that's enough to run the app on your Mac.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored) and
   set `DEVELOPMENT_TEAM` to your Team ID. This prints it:

   ```bash
   defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | grep teamID
   ```

3. Open `Calendario.xcodeproj`, choose the **Calendario** scheme, press ⌘R.

Signing with your team (instead of ad-hoc) keeps macOS's Calendar, Reminders and
Keychain permissions across rebuilds.

## 2. Google Cloud project (for Google Meet and invitees)

Without this the app works fully, just without Meet links and invitee editing.
The steps use the Google Cloud Console as of October 2026; menu names may shift.

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a
   project, e.g. "Calendario".
2. **APIs & Services > Library**: enable **Google Calendar API** and **Google People
   API** (the latter for coworker suggestions when adding invitees).
3. **Google Auth Platform > Branding**: app name "Calendario", your email as support
   and developer contact.
4. **Google Auth Platform > Audience**:
   - User type **External** (unless every account you'll connect is in one Google
     Workspace organization; then **Internal** is simpler and has no warnings).
   - Add your Google accounts under **Test users**.
   - Click **Publish app** so the status is **In production**. This matters: apps in
     **Testing** get refresh tokens that expire after 7 days, which would sign you
     out every week.
5. **Google Auth Platform > Data Access > Add or remove scopes**: add
   - `https://www.googleapis.com/auth/calendar.events.owned`
     (create and change events on calendars you own)
   - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
     (read your calendar list, to match Google calendars to the Mac's)
   - `https://www.googleapis.com/auth/directory.readonly`
     (optional: suggest coworkers from your Workspace directory as you type invitees)
   - `openid` and `.../auth/userinfo.email` (to know which account connected)
6. **Google Auth Platform > Clients > Create client**:
   - Application type **iOS**. (It's the type Google's own macOS sign-in uses. It
     needs no client secret; the app uses PKCE. Nothing about it is iPhone-specific.)
   - Bundle ID: the `PRODUCT_BUNDLE_IDENTIFIER` from your `Config/Local.xcconfig`
   - Team ID: your Apple Team ID from step 1 (optional field).
   - Create, then copy the **Client ID**.
7. Put it in `Config/Local.xcconfig`:

   ```
   GOOGLE_CLIENT_ID = 1234-abc.apps.googleusercontent.com
   ```

   It isn't a secret, but it's kept out of the repo anyway. Rebuild.

There is no client secret for this client type, and none is needed or stored.

### Connecting accounts in the app

**Calendario > Settings > Accounts > Connect Google Account…**, or the
**Connect Google Account…** button in the event editor for a Google calendar.
Connect the same Google accounts that are set up in Internet Accounts; the app
matches them by email.

Because the app isn't verified by Google, the sign-in shows **"Google hasn't verified
this app"**. Click **Advanced > Go to Calendario (unsafe)**. That's expected for a
personal app; it's your own project.

Tokens are stored in your login Keychain, one item per account
("Calendario: Google account …"), and refreshed silently.

### Google Workspace accounts

Coworker suggestions search the Workspace directory. If they never appear, the admin
may have turned off directory sharing: **Google Admin console > Directory > Directory
settings > Sharing settings > Contact sharing** must be enabled.

If a Workspace admin blocks unverified third-party apps, sign-in fails with
"Access blocked". The admin can allow the app:
**Google Admin console > Security > Access and data control > API controls >
Manage Third-Party App Access > Add app > OAuth App Name or Client ID**, search for
the client ID, and set it to **Trusted**.

### When a Google sign-in stops working

Refresh tokens also end when you revoke access in your Google account, change the
password (for some scopes), or don't use the app for 6 months. The app then shows
the account as **Sign-in expired**; click **Reconnect…** in Settings > Accounts.

## 3. Sharing the app with others (only if you decide to)

Nothing here is needed for personal use.

- **Apple:** an app signed with a free Personal Team can't be meaningfully shared;
  Gatekeeper blocks it on other Macs. Sharing needs the paid Apple Developer Program,
  a **Developer ID** certificate and **notarization**. Your Team ID changes, so update
  it on the Google iOS client too.
- **Google:** other people just connect their own Google accounts; no Cloud setup on
  their side. An unverified app can be used by at most **100 users** and shows the
  warning above. To lift both, submit the app for verification (calendar scopes are
  "sensitive": you need a home page, a privacy policy, a short demo video and a
  justification per scope; typically a few business days).
