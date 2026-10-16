import CalendarDomain
import SwiftUI

/// A list of upcoming days that have events or reminders.
struct AgendaView: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    let interval: DateInterval
    let events: [Event]
    let tasks: [TaskItem]
    let math: CalendarMath

    var body: some View {
        let layout = DayLayout(math: math)
        let days = math.days(in: interval)
            .map { day in
                (day, DayItem.merged(events: layout.events(events, on: day), tasks: TaskLayout.tasks(tasks, dueOn: day, math: math)))
            }
            .filter { !$0.1.isEmpty }

        if days.isEmpty {
            ContentUnavailableView("No Events", systemImage: "calendar", description: Text("Nothing scheduled in this period."))
        } else {
            List {
                ForEach(days, id: \.0) { day, items in
                    Section {
                        ForEach(items) { item in
                            switch item {
                            case .event(let event): AgendaRow(event: event, day: day, math: math)
                            case .task(let task): AgendaTaskRow(task: task)
                            }
                        }
                    } header: {
                        HStack {
                            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            if math.calendar.isDateInToday(day) {
                                Text("Today").foregroundStyle(Color.accentColor)
                            }
                        }
                        .font(.headline)
                    }
                }
            }
        }
    }
}

private struct AgendaRow: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    let event: Event
    let day: Date
    let math: CalendarMath
    @State private var showingDetail = false

    var body: some View {
        let calendar = store.calendar(id: event.calendarID)
        Button { showingDetail = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(theme.accent(calendar?.color ?? .gray))
                    .frame(width: 9, height: 9)
                Text(timeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .strikethrough(event.status == .canceled)
                    if let location = event.location {
                        Text(location).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let calendar {
                    Text(calendar.title).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
            EventDetailView(event: event)
        }
    }

    /// Multi-day timed events show where this day falls in the span.
    private var timeText: String {
        if event.isAllDay { return String(localized: "All day") }
        let dayInterval = math.dayInterval(containing: day)
        let startsToday = event.start >= dayInterval.start
        let endsToday = event.end <= dayInterval.end
        switch (startsToday, endsToday) {
        case (true, true): return EventText.timeRange(event)
        case (true, false): return String(localized: "from \(EventText.startTime(event))")
        case (false, true): return String(localized: "until \(event.end.formatted(date: .omitted, time: .shortened))")
        case (false, false): return String(localized: "All day")
        }
    }
}

private struct AgendaTaskRow: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.taskActions) private var actions
    let task: TaskItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TaskCheckbox(task: task)
            Text(timeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(task.title)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
            Spacer()
            if let list = reminders.list(id: task.listID) {
                Text(list.title).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { actions.edit(task) }
        .contextMenu { TaskContextMenu(task: task) }
    }

    private var timeText: String {
        if case .time(let date) = task.due { return date.formatted(date: .omitted, time: .shortened) }
        return String(localized: "Reminder")
    }
}
