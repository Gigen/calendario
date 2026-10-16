import AppKit
import CalendarDomain
import SwiftUI

/// The completion checkbox, in the list's color.
struct TaskCheckbox: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.taskActions) private var actions
    let task: TaskItem

    var body: some View {
        let color = theme.accent(reminders.list(id: task.listID)?.color ?? .gray)
        Button {
            actions.setCompleted(!task.isCompleted, task)
        } label: {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .disabled(!reminders.canModify(task))
        .help(task.isCompleted ? "Mark as Not Completed" : "Mark as Completed")
    }
}

/// A one-line reminder in the calendar views: checkbox, optional time, title.
struct TaskChip: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(\.taskActions) private var actions
    let task: TaskItem

    var body: some View {
        HStack(spacing: 4) {
            TaskCheckbox(task: task)
            if case .time(let date) = task.due {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(task.title)
                .lineLimit(1)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { actions.edit(task) }
        .contextMenu { TaskContextMenu(task: task) }
    }
}

struct TaskContextMenu: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.taskActions) private var actions
    let task: TaskItem

    var body: some View {
        Button(task.isCompleted ? "Mark as Not Completed" : "Mark as Completed") {
            actions.setCompleted(!task.isCompleted, task)
        }
        .disabled(!reminders.canModify(task))
        Button("Edit…") { actions.edit(task) }
        Divider()
        Button("Delete Reminder", role: .destructive) { actions.delete(task) }
            .disabled(!reminders.canModify(task))
    }
}

enum TaskText {
    static func due(_ due: TaskDue, math: CalendarMath) -> String {
        let calendar = math.calendar
        let date = due.date
        let day: String
        if calendar.isDateInToday(date) {
            day = String(localized: "Today")
        } else if calendar.isDateInTomorrow(date) {
            day = String(localized: "Tomorrow")
        } else if calendar.isDateInYesterday(date) {
            day = String(localized: "Yesterday")
        } else {
            day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        guard due.hasTime else { return day }
        return day + ", " + date.formatted(date: .omitted, time: .shortened)
    }

    static func priorityMarks(_ level: PriorityLevel) -> String {
        switch level {
        case .none: ""
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }
}

// MARK: - Reminders list

/// All open reminders in the visible lists, grouped by list.
struct RemindersView: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.taskActions) private var actions
    @AppStorage("showCompletedReminders") private var showCompleted = false
    @State private var tasks: [TaskItem] = []
    @State private var loadError: String?
    private let math = CalendarMath()

    private struct LoadKey: Hashable {
        var revision: Int
        var showCompleted: Bool
    }

    var body: some View {
        Group {
            switch reminders.access {
            case .fullAccess:
                list
            case nil:
                ProgressView()
            default:
                RemindersAccessView()
            }
        }
        .task(id: LoadKey(revision: reminders.revision, showCompleted: showCompleted)) {
            do {
                // Completed in the last 30 days, so recent work is still visible.
                let since = showCompleted ? math.addingDays(-30, to: Date()) : nil
                tasks = try await reminders.allTasks(completedSince: since)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private var list: some View {
        let byList = Dictionary(grouping: tasks, by: \.listID)
        return List {
            ForEach(reminders.visibleLists) { taskList in
                let items = (byList[taskList.id] ?? []).sorted(by: TaskLayout.displayOrder)
                Section {
                    ForEach(items) { task in
                        TaskRow(task: task, math: math)
                    }
                    if taskList.allowsContentModifications {
                        Button {
                            actions.create(nil, taskList.id)
                        } label: {
                            Label("New Reminder", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Circle().fill(theme.accent(taskList.color)).frame(width: 9, height: 9)
                        Text(taskList.title)
                        Spacer()
                        Text("\(items.filter { !$0.isCompleted }.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.headline)
                }
            }
        }
        .overlay {
            if reminders.visibleLists.isEmpty {
                ContentUnavailableView("No Reminder Lists", systemImage: "checklist", description: Text("Show a list in the sidebar, or add one in Reminders."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("Show Completed", isOn: $showCompleted)
                    .toggleStyle(.checkbox)
                Spacer()
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.bar)
        }
    }
}

private struct TaskRow: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(\.taskActions) private var actions
    let task: TaskItem
    let math: CalendarMath

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TaskCheckbox(task: task)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    let marks = TaskText.priorityMarks(task.priorityLevel)
                    if !marks.isEmpty {
                        Text(marks).foregroundStyle(.orange).fontWeight(.bold)
                    }
                    Text(task.title.isEmpty ? String(localized: "New Reminder") : task.title)
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                }
                HStack(spacing: 6) {
                    if let due = task.due {
                        Text(TaskText.due(due, math: math))
                            .foregroundStyle(task.isOverdue(now: Date(), math: math) ? .red : .secondary)
                    }
                    if task.isRecurring {
                        Image(systemName: "repeat").foregroundStyle(.secondary)
                    }
                    if !task.alarms.isEmpty {
                        Image(systemName: "bell").foregroundStyle(.secondary)
                    }
                    if let notes = task.notes {
                        Text(notes).lineLimit(1).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.edit(task) }
        .contextMenu { TaskContextMenu(task: task) }
    }
}

/// Asks for Reminders access. The calendar keeps working either way.
struct RemindersAccessView: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(ReminderStore.self) private var reminders

    var body: some View {
        ContentUnavailableView {
            Label("Reminders Access", systemImage: "checklist")
        } description: {
            switch reminders.access {
            case .denied, .writeOnly:
                Text("Calendario can't see your reminders. Allow Full Access in System Settings > Privacy & Security > Reminders.")
            case .restricted:
                Text("Reminders access is restricted on this Mac.")
            default:
                if reminders.isRequestingAccess {
                    Text("Waiting for you to answer the macOS permission dialog…")
                } else {
                    Text("Allow access to show and complete your reminders next to your events.")
                }
            }
        } actions: {
            switch reminders.access {
            case .denied, .writeOnly:
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .notDetermined:
                Button("Allow Access…") { Task { await reminders.requestAccess() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(reminders.isRequestingAccess)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Events and reminders together

/// An entry in a day's list: an event or a reminder (ordering lives in the domain).
typealias DayItem = CalendarItem

struct DayItemChip: View {
    @Environment(\.calendarTheme) private var theme
    let item: DayItem

    var body: some View {
        switch item {
        case .event(let event): EventChip(event: event)
        case .task(let task): TaskChip(task: task)
        }
    }
}

/// A timed reminder in the day/week grid, at its due time.
struct TaskBlock: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.taskActions) private var actions
    let task: TaskItem

    var body: some View {
        HStack(spacing: 4) {
            TaskCheckbox(task: task)
            if case .time(let date) = task.due {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(task.title)
                .lineLimit(1)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Framed rather than filled, so reminders read differently from events.
        .background { theme.reminderBackground(reminders.list(id: task.listID)?.color ?? .gray) }
        .contentShape(Rectangle())
        .onTapGesture { actions.edit(task) }
        .contextMenu { TaskContextMenu(task: task) }
        .help(task.title)
    }
}
