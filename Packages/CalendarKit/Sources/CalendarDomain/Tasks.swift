import Foundation

/// When a task is due: on a day, or at a specific time.
public enum TaskDue: Hashable, Sendable {
    /// Due some time on this day (a local midnight).
    case day(Date)
    case time(Date)

    public var date: Date {
        switch self {
        case .day(let date), .time(let date): date
        }
    }

    public var hasTime: Bool {
        if case .time = self { return true }
        return false
    }

    /// Reads iCalendar-style date components: no hour means "due on the day".
    /// A timed due uses its own time zone if it has one, otherwise the calendar's.
    public init?(components: DateComponents, calendar: Calendar) {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        if let hour = components.hour {
            var zoned = calendar
            if let zone = components.timeZone { zoned.timeZone = zone }
            let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: components.minute ?? 0)
            guard let date = zoned.date(from: parts) else { return nil }
            self = .time(date)
        } else {
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            self = .day(date)
        }
    }

    /// The components to store. Day-only dues carry no time or zone (floating), like
    /// Reminders.app writes them.
    public func components(calendar: Calendar) -> DateComponents {
        switch self {
        case .day(let date):
            var parts = calendar.dateComponents([.year, .month, .day], from: date)
            parts.calendar = calendar
            return parts
        case .time(let date):
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            parts.calendar = calendar
            parts.timeZone = calendar.timeZone
            return parts
        }
    }
}

/// A to-do item. On macOS these are Apple Reminders; a Windows client would map
/// Google Tasks or Microsoft To Do onto the same type.
public struct TaskItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var externalID: String?
    /// The list (calendar) it belongs to.
    public var listID: String
    public var title: String
    public var notes: String?
    public var url: URL?
    public var due: TaskDue?
    public var isCompleted: Bool
    public var completionDate: Date?
    /// iCalendar priority: 0 none, 1 high ... 9 low.
    public var priority: Int
    public var alarms: [Alarm]
    /// Repeating tasks are shown and completed, but their rule isn't edited here.
    public var isRecurring: Bool

    public init(
        id: String,
        externalID: String? = nil,
        listID: String,
        title: String,
        notes: String? = nil,
        url: URL? = nil,
        due: TaskDue? = nil,
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        priority: Int = 0,
        alarms: [Alarm] = [],
        isRecurring: Bool = false
    ) {
        self.id = id
        self.externalID = externalID
        self.listID = listID
        self.title = title
        self.notes = notes
        self.url = url
        self.due = due
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.priority = priority
        self.alarms = alarms
        self.isRecurring = isRecurring
    }

    public var priorityLevel: PriorityLevel { PriorityLevel(iCalendar: priority) }

    /// Past due and not done. A day-only task is overdue from the next day on.
    public func isOverdue(now: Date, math: CalendarMath) -> Bool {
        guard !isCompleted, let due else { return false }
        switch due {
        case .day(let day): return math.startOfDay(now) > day
        case .time(let date): return now > date
        }
    }
}

public enum PriorityLevel: Int, Hashable, Sendable, CaseIterable {
    case none, low, medium, high

    public init(iCalendar value: Int) {
        switch value {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    public var iCalendarValue: Int {
        switch self {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }
}

/// The editable form of a task.
public struct TaskDraft: Hashable, Sendable {
    public var title: String
    public var notes: String
    public var listID: String
    public var due: TaskDue?
    /// An alert at a specific time, or none.
    public var alert: Date?
    public var priority: PriorityLevel
    /// Alarms the editor doesn't show (e.g. location-based), kept as they were.
    public var otherAlarms: [Alarm]

    public init(listID: String, due: TaskDue? = nil) {
        title = ""
        notes = ""
        self.listID = listID
        self.due = due
        alert = nil
        priority = .none
        otherAlarms = []
    }

    public init(task: TaskItem) {
        title = task.title
        notes = task.notes ?? ""
        listID = task.listID
        due = task.due
        priority = task.priorityLevel
        // The editor shows one absolute alert; anything else is preserved untouched.
        var alert: Date?
        var others: [Alarm] = []
        for alarm in task.alarms {
            if alert == nil, case .absolute(let date) = alarm {
                alert = date
            } else {
                others.append(alarm)
            }
        }
        self.alert = alert
        otherAlarms = others
    }

    public var alarms: [Alarm] {
        (alert.map { [Alarm.absolute($0)] } ?? []) + otherAlarms
    }

    /// The alert time to suggest when the user turns alerts on: the due time, 9:00 on
    /// the due day, or the next full hour if there's no due date.
    public func suggestedAlert(now: Date, math: CalendarMath) -> Date {
        switch due {
        case .time(let date): return date
        case .day(let day): return math.date(on: day, minute: 9 * 60)
        case nil: return math.roundedUp(now, toMinutes: 60)
        }
    }

    // MARK: Due editing

    /// Turns a due date on (today, or `day`) or off.
    public mutating func setHasDue(_ on: Bool, day: Date, math: CalendarMath) {
        due = on ? .day(math.startOfDay(day)) : nil
    }

    /// Adds a time (9:00, or the next hour if that's past today) or removes it.
    public mutating func setHasTime(_ on: Bool, now: Date, math: CalendarMath) {
        guard let due else { return }
        let day = math.startOfDay(due.date)
        if on {
            guard !due.hasTime else { return }
            var time = math.date(on: day, minute: 9 * 60)
            if time < now, math.dayInterval(containing: now).containsHalfOpen(day) {
                time = math.roundedUp(now, toMinutes: 60)
            }
            self.due = .time(time)
        } else {
            self.due = .day(day)
        }
    }

    /// Changes the day and keeps the time of day.
    public mutating func setDueDay(_ newDay: Date, math: CalendarMath) {
        switch due {
        case .day, nil:
            due = .day(math.startOfDay(newDay))
        case .time(let date):
            due = .time(math.date(on: newDay, minute: math.wallClockMinutes(of: date)))
        }
    }

    public mutating func setDueTime(_ time: Date) {
        due = .time(time)
    }
}

/// Grouping and ordering of tasks for the views.
public enum TaskLayout {
    /// Tasks due on the local day starting at `dayStart`.
    public static func tasks(_ tasks: [TaskItem], dueOn dayStart: Date, math: CalendarMath) -> [TaskItem] {
        let day = math.dayInterval(containing: dayStart)
        return tasks
            .filter { task in task.due.map { day.containsHalfOpen($0.date) } ?? false }
            .sorted(by: displayOrder)
    }

    /// Open before done; then day-only before timed, by due date; undated last; then
    /// higher priority and title.
    public static func displayOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.isCompleted != b.isCompleted { return !a.isCompleted }
        switch (a.due, b.due) {
        case (nil, .some): return false
        case (.some, nil): return true
        case let (.some(x), .some(y)) where x.date != y.date: return x.date < y.date
        case let (.some(x), .some(y)) where x.hasTime != y.hasTime: return !x.hasTime
        default: break
        }
        if a.priorityLevel != b.priorityLevel { return a.priorityLevel.rawValue > b.priorityLevel.rawValue }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

/// The UI's way to reach tasks. On macOS: Apple Reminders through EventKit.
public protocol TaskProvider: AnyObject, Sendable {
    func taskAccessStatus() async -> AccessStatus
    func requestTaskAccess() async throws -> AccessStatus

    /// Sources that own at least one task list.
    func taskSources() async throws -> [CalendarSource]
    func taskLists() async throws -> [CalendarInfo]
    func defaultTaskListID() async -> String?

    /// Open tasks due in `interval`, plus tasks completed in it.
    func tasks(dueIn interval: DateInterval, listIDs: Set<String>) async throws -> [TaskItem]
    /// All open tasks in the lists, with or without due dates, plus tasks completed
    /// since `completedSince` (nil: none).
    func tasks(inLists listIDs: Set<String>, completedSince: Date?) async throws -> [TaskItem]

    @discardableResult
    func saveTask(_ draft: TaskDraft, original: TaskItem?) async throws -> String
    func setCompleted(_ completed: Bool, task: TaskItem) async throws
    func deleteTask(_ task: TaskItem) async throws

    /// Emits whenever tasks may have changed. Each call returns an independent stream.
    func changes() -> AsyncStream<Void>
}
