#if canImport(EventKit)
import CalendarDomain
import EventKit
import Foundation

/// Apple Reminders, through the same `EKEventStore` as the events.
extension EventKitCalendarProvider: TaskProvider {
    public func taskAccessStatus() async -> AccessStatus {
        AccessStatus(EKEventStore.authorizationStatus(for: .reminder))
    }

    public func requestTaskAccess() async throws -> AccessStatus {
        _ = try await store.requestFullAccessToReminders()
        return await taskAccessStatus()
    }

    public func taskSources() async throws -> [CalendarSource] {
        store.sources
            .filter { !$0.calendars(for: .reminder).isEmpty }
            .map(EventKitMapping.source(from:))
    }

    public func taskLists() async throws -> [CalendarInfo] {
        store.calendars(for: .reminder).map { EventKitMapping.calendar(from: $0, entityType: .tasks) }
    }

    public func defaultTaskListID() async -> String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    public func tasks(dueIn interval: DateInterval, listIDs: Set<String>) async throws -> [TaskItem] {
        let lists = reminderLists(listIDs)
        guard !lists.isEmpty else { return [] }
        let open = store.predicateForIncompleteReminders(withDueDateStarting: interval.start, ending: interval.end, calendars: lists)
        // Completed ones due in the interval; completion usually happens near the due
        // date, so a bounded look-back keeps the query small.
        let done = store.predicateForCompletedReminders(
            withCompletionDateStarting: interval.start.addingTimeInterval(-90 * 86_400), ending: nil, calendars: lists
        )
        let completed = await fetch(done).filter { task in
            task.due.map { interval.containsHalfOpen($0.date) } ?? false
        }
        return await fetch(open) + completed
    }

    public func tasks(inLists listIDs: Set<String>, completedSince: Date?) async throws -> [TaskItem] {
        let lists = reminderLists(listIDs)
        guard !lists.isEmpty else { return [] }
        var result = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
        if let completedSince {
            result += await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: completedSince, ending: nil, calendars: lists))
        }
        return result
    }

    @discardableResult
    public func saveTask(_ draft: TaskDraft, original: TaskItem?) async throws -> String {
        guard let list = store.calendar(withIdentifier: draft.listID) else { throw ProviderError.calendarNotFound }
        guard list.allowsContentModifications else { throw ProviderError.calendarIsReadOnly }

        let reminder: EKReminder
        if let original {
            guard let existing = store.calendarItem(withIdentifier: original.id) as? EKReminder else {
                throw ProviderError.eventNotFound
            }
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: store)
        }

        let calendar = Calendar.autoupdatingCurrent
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        reminder.dueDateComponents = draft.due?.components(calendar: calendar)
        reminder.priority = draft.priority.iCalendarValue
        // Only touch alarms when they changed, so location-based alerts survive.
        if original.map({ TaskDraft(task: $0).alarms }) != draft.alarms {
            reminder.alarms = draft.alarms.map(EventKitMapping.alarm(from:))
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    public func setCompleted(_ completed: Bool, task: TaskItem) async throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw ProviderError.eventNotFound
        }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }

    public func deleteTask(_ task: TaskItem) async throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw ProviderError.eventNotFound
        }
        try store.remove(reminder, commit: true)
    }

    // MARK: Helpers

    private func reminderLists(_ ids: Set<String>) -> [EKCalendar] {
        store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) }
    }

    /// `fetchReminders` calls back on a background queue; map to domain values there,
    /// since `EKReminder` isn't Sendable.
    private func fetch(_ predicate: NSPredicate) async -> [TaskItem] {
        let calendar = Calendar.autoupdatingCurrent
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map { EventKitMapping.task(from: $0, calendar: calendar) })
            }
        }
    }
}

extension EventKitMapping {
    static func task(from reminder: EKReminder, calendar: Calendar) -> TaskItem {
        TaskItem(
            id: reminder.calendarItemIdentifier,
            externalID: reminder.calendarItemExternalIdentifier,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            title: reminder.title ?? "",
            notes: (reminder.notes?.isEmpty ?? true) ? nil : reminder.notes,
            url: reminder.url,
            due: reminder.dueDateComponents.flatMap { TaskDue(components: $0, calendar: calendar) },
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            priority: reminder.priority,
            alarms: (reminder.alarms ?? []).map(alarm(from:)),
            isRecurring: reminder.hasRecurrenceRules
        )
    }
}
#endif
