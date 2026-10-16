#if canImport(EventKit)
import CalendarDomain
import CoreGraphics
import EventKit
import Foundation

/// `CalendarProvider` backed by the system calendar database. Every account set up in
/// System Settings > Internet Accounts (iCloud, Google, Exchange, CalDAV) shows up here;
/// the system does the syncing.
///
/// `EKEventStore` is documented as safe to use from multiple threads, hence `@unchecked Sendable`.
public final class EventKitCalendarProvider: CalendarProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedStore: EKEventStore?

    public init() {}

    /// Created on first use, which is always off the main thread (see below).
    var store: EKEventStore {
        lock.withLock {
            if let cachedStore { return cachedStore }
            let store = EKEventStore()
            cachedStore = store
            return store
        }
    }

    // MARK: Access

    // Every method here is nonisolated and async, so it runs off the main thread.
    // EventKit makes synchronous calls to the calendar daemon, which can be slow or stall.

    public func eventAccessStatus() async -> AccessStatus {
        AccessStatus(EKEventStore.authorizationStatus(for: .event))
    }

    public func requestEventAccess() async throws -> AccessStatus {
        _ = try await store.requestFullAccessToEvents()
        return await eventAccessStatus()
    }

    // MARK: Reading

    public func sources() async throws -> [CalendarSource] {
        store.sources
            .filter { !$0.calendars(for: .event).isEmpty }
            .map(EventKitMapping.source(from:))
    }

    public func eventCalendars() async throws -> [CalendarInfo] {
        store.calendars(for: .event).map { EventKitMapping.calendar(from: $0, entityType: .events) }
    }

    public func events(in interval: DateInterval, calendarIDs: Set<String>) async throws -> [Event] {
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        let calendar = Calendar.autoupdatingCurrent
        return store.events(matching: predicate).map { EventKitMapping.event(from: $0, calendar: calendar) }
    }

    // MARK: Writing

    public func defaultCalendarIDForNewEvents() async -> String? {
        store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    @discardableResult
    public func saveEvent(_ draft: EventDraft, original: Event?, scope: EditScope) async throws -> String? {
        guard let calendar = store.calendar(withIdentifier: draft.calendarID) else {
            throw ProviderError.calendarNotFound
        }
        guard calendar.allowsContentModifications else { throw ProviderError.calendarIsReadOnly }

        let event: EKEvent
        if let original {
            guard let existing = occurrence(of: original) else { throw ProviderError.eventNotFound }
            event = existing
        } else {
            event = EKEvent(eventStore: store)
        }

        EventKitMapping.apply(draft, to: event, calendar: calendar, recurrenceChanged: draft.recurrence != original?.recurrence)
        try store.save(event, span: EventKitMapping.span(scope), commit: true)
        return event.eventIdentifier
    }

    public func deleteEvent(_ event: Event, scope: EditScope) async throws {
        guard let existing = occurrence(of: event) else { throw ProviderError.eventNotFound }
        guard existing.calendar?.allowsContentModifications ?? false else { throw ProviderError.calendarIsReadOnly }
        try store.remove(existing, span: EventKitMapping.span(scope), commit: true)
    }

    /// Finds the exact occurrence behind `event`. For repeating events
    /// `event(withIdentifier:)` returns the first occurrence, so editing "this event"
    /// through it would change the wrong day; look the occurrence up by date instead.
    private func occurrence(of event: Event) -> EKEvent? {
        guard let seriesID = event.seriesID else { return nil }
        guard event.isRecurring else { return store.event(withIdentifier: seriesID) }

        let target = event.occurrenceDate ?? event.start
        let window = DateInterval(
            start: min(target, event.start).addingTimeInterval(-2 * 86_400),
            end: max(target, event.end).addingTimeInterval(2 * 86_400)
        )
        let calendars = store.calendar(withIdentifier: event.calendarID).map { [$0] }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        return store.events(matching: predicate).first {
            $0.eventIdentifier == seriesID && $0.occurrenceDate == target
        }
    }

    public func requestSync() async {
        store.refreshSourcesIfNecessary()
    }

    // MARK: Changes

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            // `object: nil` so subscribing doesn't create the store on the caller's thread.
            // The app has a single store, so there's nothing else to filter out.
            let observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: nil
            ) { _ in
                continuation.yield()
            }
            let token = ObserverToken(observer)
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token.observer)
            }
        }
    }
}

/// Lets a notification observer cross into the `@Sendable` termination handler.
private final class ObserverToken: @unchecked Sendable {
    let observer: any NSObjectProtocol
    init(_ observer: any NSObjectProtocol) { self.observer = observer }
}

extension AccessStatus {
    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .fullAccess: self = .fullAccess
        case .writeOnly: self = .writeOnly
        @unknown default: self = .denied
        }
    }
}
#endif
