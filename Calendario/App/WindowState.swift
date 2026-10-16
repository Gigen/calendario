import CalendarDomain
import Foundation
import Observation

/// Per-window navigation: which period is shown and the events in it.
@Observable
final class WindowState {
    var period: CalendarPeriod = .days
    /// How many days the Days view shows (Settings-wide, synced by MainView).
    var dayCount = CalendarPeriod.defaultDayCount
    /// The Reminders list replaces the calendar while this is on.
    var showsReminders = false
    var date = Date()
    private(set) var events: [Event] = []
    /// Reminders due in the visible period.
    private(set) var tasks: [TaskItem] = []
    private(set) var loadError: String?

    var taskEditor: TaskEditorSession?
    var pendingTaskDelete: TaskItem?
    var isPickingDate = false

    /// A sheet is open. Navigation shortcuts like ⌘← then belong to its text fields.
    var hasSheet: Bool { editor != nil || taskEditor != nil || isPickingDate }

    /// The view switcher's value: a calendar period or the Reminders list.
    var mode: ViewMode {
        get { showsReminders ? .reminders : ViewMode(period) }
        set {
            showsReminders = newValue == .reminders
            if let period = newValue.period { self.period = period }
        }
    }

    var editor: EditorSession?
    var pendingDelete: Event?
    /// An error from saving or deleting, shown as an alert.
    var actionError: String?

    let math = CalendarMath()

    var visibleInterval: DateInterval {
        math.visibleInterval(for: period, containing: date, dayCount: dayCount)
    }

    func goToToday() { date = Date() }
    func goForward() { date = math.step(date, by: 1, period: period, dayCount: dayCount) }
    func goBack() { date = math.step(date, by: -1, period: period, dayCount: dayCount) }

    func show(_ day: Date, as period: CalendarPeriod) {
        date = day
        self.period = period
    }

    /// The day new events default to: the shown day, or today if it's visible.
    var dayForNewEvent: Date {
        if period == .day { return math.startOfDay(date) }
        let interval = visibleInterval
        if interval.containsHalfOpen(Date()) { return math.startOfDay(Date()) }
        return period == .month ? math.monthInterval(containing: date).start : interval.start
    }

    func startNewEvent(_ request: NewEventRequest, store: CalendarStore) {
        guard let calendarID = store.calendarIDForNewEvents else {
            actionError = String(localized: "None of your calendars can be edited. Add an account in System Settings > Internet Accounts.")
            return
        }
        let draft: EventDraft = switch request {
        case .on(let day):
            .newEvent(on: day, calendarID: calendarID, math: math)
        case .at(let start):
            .newEvent(at: start, calendarID: calendarID, math: math)
        case .allDay(let day):
            EventDraft(start: math.startOfDay(day), end: math.addingDays(1, to: math.startOfDay(day)), isAllDay: true, timeZone: nil, calendarID: calendarID)
        }
        editor = EditorSession(original: nil, draft: draft)
    }

    func startEditing(_ event: Event) {
        editor = EditorSession(original: event, draft: EventDraft(event: event))
    }

    func delete(_ event: Event, scope: EditScope, store: CalendarStore) async {
        do {
            try await store.delete(event, scope: scope)
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }

    func load(from store: CalendarStore, reminders: ReminderStore) async {
        do {
            let interval = visibleInterval
            async let events = store.events(in: interval)
            async let tasks = reminders.tasks(dueIn: interval)
            (self.events, self.tasks) = try await (events, tasks)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Reminders

    func startNewTask(due: TaskDue?, listID: String? = nil, reminders: ReminderStore) {
        guard let listID = listID ?? reminders.listIDForNewTasks else {
            actionError = String(localized: "None of your reminder lists can be edited.")
            return
        }
        taskEditor = TaskEditorSession(original: nil, draft: TaskDraft(listID: listID, due: due))
    }

    func startEditing(_ task: TaskItem) {
        taskEditor = TaskEditorSession(original: task, draft: TaskDraft(task: task))
    }

    func setCompleted(_ completed: Bool, task: TaskItem, reminders: ReminderStore) async {
        // Show the change right away; the reload after saving confirms it.
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].isCompleted = completed
        }
        do {
            try await reminders.setCompleted(completed, task: task)
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }

    func delete(_ task: TaskItem, reminders: ReminderStore) async {
        do {
            try await reminders.delete(task)
        } catch {
            actionError = ErrorText.message(for: error)
        }
    }

    /// The title shown in the toolbar, formatted for the user's locale.
    var title: String {
        switch period {
        case .day:
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .days:
            let interval = visibleInterval
            let last = math.addingDays(-1, to: interval.end)
            return (interval.start..<last).formatted(.interval.day().month(.abbreviated).year())
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        case .agenda:
            let interval = visibleInterval
            let last = math.addingDays(-1, to: interval.end)
            return (interval.start..<last).formatted(.interval.day().month(.abbreviated).year())
        }
    }
}
