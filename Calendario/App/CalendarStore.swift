import CalendarDomain
import Foundation
import Observation
import os

/// App-wide calendar state shared by all windows: access status, accounts, calendars
/// and which calendars are hidden. Windows fetch their own events for whatever range
/// they show, keyed on `revision`.
@Observable
final class CalendarStore {
    let provider: any CalendarProvider

    /// `nil` until the system has answered; that can take a moment (or stall) at launch.
    private(set) var access: AccessStatus?
    private(set) var sources: [CalendarSource] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var lastError: String?
    /// A short confirmation shown at the bottom of the window, e.g. after saving to Google.
    private(set) var notice: String?
    /// A system permission dialog is (or should be) on screen.
    private(set) var isRequestingAccess = false
    /// Bumped whenever anything a view displays may have changed.
    private(set) var revision = 0

    var hiddenCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: Self.hiddenKey)
            revision += 1
        }
    }

    /// The calendar new events go into: the last one used, else the system default.
    var calendarIDForNewEvents: String? {
        let writable = Set(writableCalendars.map(\.id))
        let lastUsed = UserDefaults.standard.string(forKey: Self.lastUsedCalendarKey)
        return [lastUsed, systemDefaultCalendarID].compactMap { $0 }.first(where: writable.contains)
            ?? writableCalendars.first?.id
    }

    var writableCalendars: [CalendarInfo] {
        calendars.filter(\.allowsContentModifications)
    }

    /// Events created through Google that the system calendar hasn't synced yet.
    private var pending = PendingEvents()
    /// Invitation responses sent through Google, shown until the sync catches up.
    private var pendingResponses = PendingResponses()

    private static let hiddenKey = "hiddenCalendarIDs"
    private static let lastUsedCalendarKey = "lastUsedCalendarID"
    private var systemDefaultCalendarID: String?
    private var calendarsByID: [String: CalendarInfo] = [:]
    /// The accounts' own colors, for "Use Account Color".
    private var systemColors: [String: RGBAColor] = [:]
    private var started = false
    private let log = Logger(subsystem: AppInfo.subsystem, category: "access")

    init(provider: any CalendarProvider) {
        self.provider = provider
        self.hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    // MARK: Lifecycle

    /// Loads, then keeps listening for changes. Every window calls this; only the first
    /// call does anything. The work runs in a task owned by the store, so closing the
    /// first window doesn't stop it.
    ///
    /// This doesn't ask for access by itself: macOS only shows the permission dialog
    /// while the app is frontmost, and at launch it may not be (e.g. behind Xcode). The
    /// request waits for the user to click "Allow Access…", which makes the app active.
    func start() {
        guard !started else { return }
        started = true
        observeSystemChanges()
        Task {
            await reloadCalendars()
            log.info("Calendar access at launch: \(String(describing: self.access), privacy: .public)")
            for await _ in provider.changes() {
                await reloadCalendars()
            }
        }
    }

    func requestAccess() async {
        // A second request while one is pending would just queue behind it.
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        log.info("Requesting full calendar access")
        do {
            access = try await provider.requestEventAccess()
        } catch {
            access = await provider.eventAccessStatus()
            lastError = error.localizedDescription
            log.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
        }
        log.info("Calendar access is now \(String(describing: self.access), privacy: .public)")
        await reloadCalendars()
    }

    func reloadCalendars() async {
        access = await provider.eventAccessStatus()
        guard access == .fullAccess else {
            sources = []
            calendars = []
            calendarsByID = [:]
            revision += 1
            return
        }
        do {
            sources = try await provider.sources()
                .sorted { ($0.kind.sortRank, $0.title.lowercased()) < ($1.kind.sortRank, $1.title.lowercased()) }
            let loaded = try await provider.eventCalendars()
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            systemColors = Dictionary(loaded.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first })
            calendars = ColorOverrides.apply(to: loaded, systemColors: systemColors)
            calendarsByID = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            systemDefaultCalendarID = await provider.defaultCalendarIDForNewEvents()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        revision += 1
    }

    /// Time zone, locale (week start, 12/24 h) and the date can change while the app runs.
    private func observeSystemChanges() {
        let names: [Notification.Name] = [.NSSystemTimeZoneDidChange, .NSCalendarDayChanged, NSLocale.currentLocaleDidChangeNotification]
        for name in names {
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                    self?.revision += 1
                }
            }
        }
    }

    // MARK: Queries

    func calendar(id: String) -> CalendarInfo? { calendarsByID[id] }

    func calendars(in source: CalendarSource) -> [CalendarInfo] {
        calendars.filter { $0.sourceID == source.id }
    }

    var visibleCalendarIDs: Set<String> {
        Set(calendars.map(\.id)).subtracting(hiddenCalendarIDs)
    }

    func isVisible(_ calendar: CalendarInfo) -> Bool {
        !hiddenCalendarIDs.contains(calendar.id)
    }

    func setVisible(_ visible: Bool, for calendar: CalendarInfo) {
        if visible {
            hiddenCalendarIDs.remove(calendar.id)
        } else {
            hiddenCalendarIDs.insert(calendar.id)
        }
    }

    func setVisible(_ visible: Bool, forAllIn source: CalendarSource) {
        let ids = Set(calendars(in: source).map(\.id))
        hiddenCalendarIDs = visible ? hiddenCalendarIDs.subtracting(ids) : hiddenCalendarIDs.union(ids)
    }

    /// Pending events (created through Google, not yet synced) can't be edited yet.
    /// A Calendario-only color for a calendar; `nil` goes back to the account's color.
    func setColor(_ color: RGBAColor?, for calendar: CalendarInfo) {
        // Views read colors from the list itself, so no reload is needed.
        ColorOverrides.set(color, for: calendar.id)
        calendars = ColorOverrides.apply(to: calendars, systemColors: systemColors)
        calendarsByID = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func hasCustomColor(_ calendar: CalendarInfo) -> Bool {
        ColorOverrides.all()[calendar.id] != nil
    }

    func canModify(_ event: Event) -> Bool {
        event.seriesID != nil && (calendar(id: event.calendarID)?.allowsContentModifications ?? false)
    }

    func rememberCalendarForNewEvents(_ calendarID: String) {
        UserDefaults.standard.set(calendarID, forKey: Self.lastUsedCalendarKey)
        if hiddenCalendarIDs.contains(calendarID) { hiddenCalendarIDs.remove(calendarID) }
    }

    /// Shows an invitation response everywhere right away; see `PendingResponses`.
    func noteResponse(_ status: Attendee.Status, to event: Event, wholeSeries: Bool = false) {
        pendingResponses.set(status, for: event, wholeSeries: wholeSeries)
        revision += 1
        Task { await provider.requestSync() }
    }

    /// Unanswered invitations in the next 6 months, from every calendar (hidden ones
    /// too: an invitation shouldn't be missed because its calendar is hidden).
    func pendingInvitations(now: Date = Date()) async -> [Event] {
        guard access == .fullAccess else { return [] }
        let interval = DateInterval(start: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(180 * 86_400))
        let events = (try? await provider.events(in: interval, calendarIDs: Set(calendars.map(\.id)))) ?? []
        return Invitations.pending(in: pendingResponses.apply(to: events), now: now)
    }

    /// The repeat rule of the series `event` belongs to. Occurrences changed
    /// individually don't carry it, so look at the series' other occurrences.
    func seriesRecurrence(for event: Event) async -> RecurrenceRule? {
        if let rule = event.recurrence { return rule }
        guard event.isRecurring, let key = event.seriesKey else { return nil }
        let interval = DateInterval(start: event.start.addingTimeInterval(-90 * 86_400), end: event.start.addingTimeInterval(365 * 86_400))
        let siblings = (try? await provider.events(in: interval, calendarIDs: [event.calendarID])) ?? []
        return siblings.first { $0.seriesKey == key && $0.recurrence != nil }?.recurrence
    }

    func requestSync() async {
        await provider.requestSync()
    }

    func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(6))
            if notice == text { notice = nil }
        }
    }

    // MARK: Writing

    func save(_ draft: EventDraft, original: Event?, scope: EditScope) async throws {
        try await provider.saveEvent(draft, original: original, scope: scope)
        if original == nil {
            UserDefaults.standard.set(draft.calendarID, forKey: Self.lastUsedCalendarKey)
        }
        // A hidden target calendar would make the new event seem to vanish.
        if hiddenCalendarIDs.contains(draft.calendarID) {
            hiddenCalendarIDs.remove(draft.calendarID)
        }
        revision += 1
    }

    func delete(_ event: Event, scope: EditScope) async throws {
        try await provider.deleteEvent(event, scope: scope)
        revision += 1
    }

    /// Shows an event created through Google right away; it's replaced by the synced
    /// copy (same iCalendar UID) as soon as that arrives. Also nudges the sync.
    func addPending(_ event: Event) {
        pending.add(event)
        revision += 1
        Task { await provider.requestSync() }
    }

    /// Events in visible calendars overlapping `interval`, plus pending ones.
    func events(in interval: DateInterval) async throws -> [Event] {
        guard access == .fullAccess else { return [] }
        let visible = visibleCalendarIDs
        let synced = try await provider.events(in: interval, calendarIDs: visible)
        let merged = pending.merge(synced: synced, in: interval).filter { visible.contains($0.calendarID) }
        return pendingResponses.apply(to: merged)
    }
}
