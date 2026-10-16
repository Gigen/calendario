import Foundation

// Pure logic for the Google connection: matching system calendars to Google
// calendars, routing saves, and de-duplicating events created through the API.

/// A calendar in a connected Google account, as listed by the Google API.
public struct RemoteCalendar: Hashable, Sendable {
    /// Google's calendar ID (the account email for the primary calendar).
    public var id: String
    /// The name the user sees (their override if they renamed it).
    public var title: String
    public var isPrimary: Bool

    public init(id: String, title: String, isPrimary: Bool) {
        self.id = id
        self.title = title
        self.isPrimary = isPrimary
    }
}

/// A Google account the user connected over OAuth, with the calendars they own.
public struct ConnectedAccount: Hashable, Sendable {
    public var email: String
    public var calendars: [RemoteCalendar]

    public init(email: String, calendars: [RemoteCalendar]) {
        self.email = email
        self.calendars = calendars
    }
}

/// Where a system calendar lives on Google.
public struct RemoteCalendarRef: Hashable, Sendable {
    public var accountEmail: String
    public var calendarID: String

    public init(accountEmail: String, calendarID: String) {
        self.accountEmail = accountEmail
        self.calendarID = calendarID
    }
}

public enum CalendarMatcher {
    /// Maps system calendar IDs to Google calendars.
    ///
    /// EventKit exposes neither the server nor Google's calendar IDs, so this matches
    /// by name: first the account (a source titled with the account's email), then each
    /// calendar by title. The primary calendar may be titled with the email or with
    /// its Google name. Names that appear twice in a source are skipped rather than
    /// guessed, so an event is never sent to the wrong calendar.
    public static func match(
        sources: [CalendarSource],
        calendars: [CalendarInfo],
        accounts: [ConnectedAccount]
    ) -> [String: RemoteCalendarRef] {
        var result: [String: RemoteCalendarRef] = [:]
        for account in accounts {
            let email = normalized(account.email)
            var matchingSources = sources.filter { source in
                normalized(source.accountEmail ?? "") == email || normalized(source.title) == email
            }
            // Some setups title the account just "Google"; then look for the source
            // whose primary calendar carries the account's email as its name.
            if matchingSources.isEmpty {
                matchingSources = sources.filter { source in
                    mightBeGoogle(source) && calendars.contains { $0.sourceID == source.id && normalized($0.title) == email }
                }
            }
            for source in matchingSources {
                let sourceCalendars = calendars.filter { $0.sourceID == source.id && $0.entityType == .events }
                let titleCounts = Dictionary(grouping: sourceCalendars, by: { normalized($0.title) }).mapValues(\.count)

                for remote in account.calendars {
                    var names = [normalized(remote.title)]
                    if remote.isPrimary { names.append(email) }
                    let candidates = sourceCalendars.filter { calendar in
                        let title = normalized(calendar.title)
                        return names.contains(title) && titleCounts[title] == 1
                    }
                    if candidates.count == 1, result[candidates[0].id] == nil {
                        result[candidates[0].id] = RemoteCalendarRef(accountEmail: account.email, calendarID: remote.id)
                    }
                }
            }
        }
        return result
    }

    /// Whether a source looks like a Google account, connected or not. Google sources
    /// recognized by name, or CalDAV sources titled with an email (Workspace accounts
    /// on their own domain look like this).
    public static func mightBeGoogle(_ source: CalendarSource) -> Bool {
        source.kind == .google || (source.kind == .calDAV && source.accountEmail != nil)
    }

    static func normalized(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// How an event edit must be saved.
public enum SaveRoute: Equatable, Sendable {
    /// Through the system calendar (EventKit on macOS), like any other change.
    case system
    /// Created through the Google API (needed for Meet links and invitations).
    case remoteInsert(RemoteCalendarRef)
    /// Changed through the Google API.
    case remoteUpdate(RemoteCalendarRef)
    case unsupported(Reason)

    public enum Reason: Equatable, Sendable {
        /// Meet and invitees need the calendar's Google account to be connected.
        case accountNotConnected
        /// Changing invitees or adding Meet on a repeating event isn't supported here.
        case repeatingEvent
        /// Moving an event to another calendar while changing invitees or Meet.
        case calendarChange
    }

    /// The system calendar can't create Meet links or change invitees, so those
    /// changes go through Google. Everything else stays on the normal path, so the
    /// event is written in exactly one place.
    public static func decide(original: Event?, draft: EventDraft, remote: RemoteCalendarRef?) -> SaveRoute {
        let originalEmails = Set((original?.attendees ?? []).compactMap(\.email).map(CalendarMatcher.normalized))
        let draftEmails = Set(draft.attendees.compactMap(\.email).map(CalendarMatcher.normalized))
        let needsRemote = draft.addConference || originalEmails != draftEmails
        guard needsRemote else { return .system }
        guard let remote else { return .unsupported(.accountNotConnected) }
        guard let original else { return .remoteInsert(remote) }
        if original.isRecurring { return .unsupported(.repeatingEvent) }
        if original.calendarID != draft.calendarID { return .unsupported(.calendarChange) }
        return .remoteUpdate(remote)
    }
}

/// Events created through the Google API reach the system calendar only after the
/// next sync. Until then they're shown from here, and dropped as soon as the synced
/// copy (same iCalendar UID) appears, so the event never shows twice.
public struct PendingEvents: Sendable {
    public private(set) var events: [Event] = []
    /// How long to keep waiting for sync before giving up on showing the local copy.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 15 * 60) {
        self.timeout = timeout
    }

    private var addedAt: [String: Date] = [:]

    public mutating func add(_ event: Event, now: Date = Date()) {
        events.removeAll { $0.externalID == event.externalID }
        events.append(event)
        addedAt[event.id] = now
    }

    /// Combines synced events with the pending ones, and forgets pending events that
    /// have been synced or have waited too long.
    public mutating func merge(synced: [Event], in interval: DateInterval, now: Date = Date()) -> [Event] {
        let syncedIDs = Set(synced.compactMap(\.externalID))
        events.removeAll { event in
            let expired = now.timeIntervalSince(addedAt[event.id] ?? now) > timeout
            let arrived = event.externalID.map(syncedIDs.contains) ?? false
            if expired || arrived { addedAt[event.id] = nil }
            return expired || arrived
        }
        let visible = events.filter { $0.start < interval.end && $0.end > interval.start }
        return synced + visible
    }
}

/// Finds video meeting links in an event's text fields.
public enum ConferenceLink {
    private static let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]

    /// Uses a plain regex rather than `NSDataDetector`, which isn't available in
    /// Foundation on Windows.
    public static func find(in texts: [String?]) -> URL? {
        let pattern = /https?:\/\/[^\s<>"'()]+/
        for text in texts.compactMap({ $0 }) {
            for match in text.matches(of: pattern) {
                let candidate = String(match.output).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                guard let url = URL(string: candidate), let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }
}

// MARK: - Sync health

/// An event as Google last changed it, for comparing against what the Mac has synced.
public struct RemoteChange: Hashable, Sendable {
    public var iCalUID: String
    public var updated: Date
    public var start: Date
    public var end: Date

    public init(iCalUID: String, updated: Date, start: Date, end: Date) {
        self.iCalUID = iCalUID
        self.updated = updated
        self.start = start
        self.end = end
    }
}

/// Whether the system calendar is keeping up with a Google account.
///
/// EventKit doesn't report sync errors. For connected Google accounts the app can
/// compare instead: events Google changed a while ago should be on the Mac by now.
public enum SyncHealth: Equatable, Sendable {
    /// Every sufficiently old change is on the Mac.
    case healthy
    /// Nothing to compare (no recent changes on Google), or the check failed.
    case unknown
    /// Changes Google made at least `grace` ago are missing on the Mac.
    case behind(missing: Int, oldestChange: Date)

    /// How long the system may take to sync before a missing change counts. Generous,
    /// so a slow sync interval in Calendar's settings doesn't raise false alarms.
    public static let defaultGrace: TimeInterval = 45 * 60

    public static func evaluate(
        changes: [RemoteChange],
        syncedUIDs: Set<String>,
        now: Date,
        grace: TimeInterval = defaultGrace
    ) -> SyncHealth {
        let settled = changes.filter { now.timeIntervalSince($0.updated) >= grace }
        guard !settled.isEmpty else { return .unknown }
        // A repeating event's occurrences share one UID, so count UIDs, not instances.
        let missing = Dictionary(grouping: settled.filter { !syncedUIDs.contains($0.iCalUID) }, by: \.iCalUID)
        guard !missing.isEmpty else { return .healthy }
        let oldest = missing.values.flatMap { $0 }.map(\.updated).min() ?? now
        return .behind(missing: missing.count, oldestChange: oldest)
    }

    /// The span of system-calendar events to compare against.
    public static func comparisonInterval(for changes: [RemoteChange]) -> DateInterval? {
        guard let start = changes.map(\.start).min(), let end = changes.map(\.end).max() else { return nil }
        return DateInterval(start: start.addingTimeInterval(-86_400), end: max(end, start).addingTimeInterval(86_400))
    }
}

// MARK: - Pending invitation responses

/// Responses (accept, maybe, decline) sent through Google that the system calendar
/// hasn't synced yet. Applied over the synced events so the answer shows at once;
/// each is dropped when the synced event reports the same answer, or after `timeout`
/// (then the synced value wins, in case the response never arrived).
public struct PendingResponses: Sendable {
    private var entries: [String: (status: Attendee.Status, sentAt: Date)] = [:]
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30 * 60) {
        self.timeout = timeout
    }

    /// Keyed by occurrence: responding to one occurrence of a repeating event leaves
    /// the others alone. With `wholeSeries`, every occurrence of the series is covered.
    public mutating func set(_ status: Attendee.Status, for event: Event, wholeSeries: Bool = false, now: Date = Date()) {
        if wholeSeries, let series = event.seriesKey {
            entries[Self.seriesKey(series)] = (status, now)
        } else {
            entries[event.id] = (status, now)
        }
    }

    private static func seriesKey(_ seriesID: String) -> String { "series:" + seriesID }

    public mutating func apply(to events: [Event], now: Date = Date()) -> [Event] {
        entries = entries.filter { now.timeIntervalSince($0.value.sentAt) <= timeout }
        guard !entries.isEmpty else { return events }
        return events.map { event in
            let key = entries[event.id] != nil ? event.id : event.seriesKey.map(Self.seriesKey)
            guard let key, let pending = entries[key],
                  let index = event.attendees.firstIndex(where: \.isCurrentUser) else { return event }
            if event.attendees[index].status == pending.status {
                entries[key] = nil // synced
                return event
            }
            var updated = event
            updated.attendees[index].status = pending.status
            return updated
        }
    }
}

// MARK: - Invitation inbox

public enum Invitations {
    /// Upcoming events the user was invited to and hasn't answered, soonest first.
    /// A repeating invitation appears once (its next occurrence).
    public static func pending(in events: [Event], now: Date) -> [Event] {
        var seenSeries: Set<String> = []
        return withSeriesRules(events)
            .filter { $0.end > now && $0.status != .canceled && $0.invitationForCurrentUser?.status == .pending }
            .sorted { $0.start < $1.start }
            .filter { event in
                guard event.isRecurring, let series = event.seriesKey else { return true }
                return seenSeries.insert(event.calendarID + "|" + series).inserted
            }
    }

    /// Occurrences the organizer changed individually come without the series' repeat
    /// rule; borrow it from another occurrence of the same series (same UID).
    public static func withSeriesRules(_ events: [Event]) -> [Event] {
        var rules: [String: RecurrenceRule] = [:]
        for event in events {
            if let key = event.seriesKey, let rule = event.recurrence {
                let composite = event.calendarID + "|" + key
                if rules[composite] == nil { rules[composite] = rule }
            }
        }
        return events.map { event in
            guard event.recurrence == nil, let key = event.seriesKey,
                  let rule = rules[event.calendarID + "|" + key] else { return event }
            var copy = event
            copy.recurrence = rule
            return copy
        }
    }
}
