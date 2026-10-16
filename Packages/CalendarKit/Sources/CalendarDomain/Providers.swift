import Foundation

/// The UI's only way to reach calendar data.
///
/// On macOS this is backed by EventKit. A Windows client would implement it on top of
/// the Google Calendar API, Microsoft Graph and CalDAV. That's why every data call is
/// `async throws`, even though EventKit itself is synchronous. It also keeps the UI
/// responsive: EventKit calls block on a system daemon and must stay off the main thread.
public protocol CalendarProvider: AnyObject, Sendable {
    func eventAccessStatus() async -> AccessStatus
    func requestEventAccess() async throws -> AccessStatus

    /// Accounts that own at least one event calendar.
    func sources() async throws -> [CalendarSource]
    func eventCalendars() async throws -> [CalendarInfo]

    /// All occurrences overlapping `interval` in the given calendars, recurring events expanded.
    func events(in interval: DateInterval, calendarIDs: Set<String>) async throws -> [Event]

    /// The calendar the user picked as default in their system settings, if any.
    func defaultCalendarIDForNewEvents() async -> String?

    /// Creates an event (`original == nil`) or updates `original`. For a repeating
    /// event `scope` says whether to change only this occurrence or this and all
    /// later ones. Returns the saved event's series identifier.
    @discardableResult
    func saveEvent(_ draft: EventDraft, original: Event?, scope: EditScope) async throws -> String?

    func deleteEvent(_ event: Event, scope: EditScope) async throws

    /// Asks the system to fetch remote changes soon (e.g. after creating an event
    /// directly on the server). Best effort.
    func requestSync() async

    /// Emits whenever the underlying data changed, locally or through sync.
    /// Each call returns an independent stream.
    func changes() -> AsyncStream<Void>
}
