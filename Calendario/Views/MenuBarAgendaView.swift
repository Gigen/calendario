import AppKit
import CalendarDomain
import SwiftUI

/// The menu bar extra: today's and tomorrow's events and reminders.
struct MenuBarAgendaView: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    @Environment(ReminderStore.self) private var reminders
    @Environment(\.openWindow) private var openWindow
    @State private var events: [Event] = []
    @State private var tasks: [TaskItem] = []
    @State private var overdue: [TaskItem] = []
    private let math = CalendarMath()

    private struct LoadKey: Hashable {
        var calendarRevision: Int
        var reminderRevision: Int
        var today: Date
    }

    var body: some View {
        let today = math.startOfDay(Date())
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.headline)
                Spacer()
                Button("Open Calendario", action: openMainWindow)
            }

            if store.access != .fullAccess {
                Text("Open Calendario to allow calendar access.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !overdue.isEmpty {
                            section(String(localized: "Overdue"), items: overdue.map(DayItem.task), day: today)
                        }
                        section(String(localized: "Today"), items: items(on: today), day: today)
                        let tomorrow = math.addingDays(1, to: today)
                        section(String(localized: "Tomorrow"), items: items(on: tomorrow), day: tomorrow)
                    }
                }
                .frame(maxHeight: 440)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            // The app can launch with no windows; make sure data loads anyway.
            store.start()
            reminders.start()
        }
        .task(id: LoadKey(calendarRevision: store.revision, reminderRevision: reminders.revision, today: today)) {
            await load(today: today)
        }
    }

    private func items(on day: Date) -> [DayItem] {
        DayItem.merged(
            events: DayLayout(math: math).events(events, on: day),
            tasks: TaskLayout.tasks(tasks, dueOn: day, math: math)
        )
    }

    @ViewBuilder private func section(_ title: String, items: [DayItem], day: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("Nothing scheduled").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(items) { item in
                switch item {
                case .event(let event): MenuEventRow(event: event, day: day, math: math)
                case .task(let task): MenuTaskRow(task: task)
                }
            }
        }
    }

    private func load(today: Date) async {
        let interval = DateInterval(start: today, end: math.addingDays(2, to: today))
        events = (try? await store.events(in: interval)) ?? []
        tasks = (try? await reminders.tasks(dueIn: interval)) ?? []
        // Open reminders due before today.
        let past = DateInterval(start: math.addingDays(-60, to: today), end: today)
        overdue = ((try? await reminders.tasks(dueIn: past)) ?? [])
            .filter { !$0.isCompleted }
            .sorted(by: TaskLayout.displayOrder)
    }

    /// Brings a calendar window to the front, or opens one.
    private func openMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(AppWindow.main) == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: AppWindow.main)
        }
    }
}

private struct MenuEventRow: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    let event: Event
    let day: Date
    let math: CalendarMath

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(theme.accent(store.calendar(id: event.calendarID)?.color ?? .gray))
                .frame(width: 8, height: 8)
            Text(timeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(event.title)
                .lineLimit(1)
                .strikethrough(event.status == .canceled)
            Spacer(minLength: 4)
            if let link = event.conferenceURL {
                Link("Join", destination: link)
                    .font(.callout)
                    .help(link.absoluteString)
            }
        }
        .font(.callout)
    }

    private var timeText: String {
        if event.isAllDay || event.start < math.startOfDay(day) { return String(localized: "All day") }
        return EventText.startTime(event)
    }
}

private struct MenuTaskRow: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(ReminderStore.self) private var reminders
    let task: TaskItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                Task { try? await reminders.setCompleted(!task.isCompleted, task: task) }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(theme.accent(reminders.list(id: task.listID)?.color ?? .gray))
            }
            .buttonStyle(.plain)
            .disabled(!reminders.canModify(task))
            Text(timeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(task.title)
                .lineLimit(1)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private var timeText: String {
        guard let due = task.due else { return "" }
        if !due.hasTime { return String(localized: "Reminder") }
        return due.date.formatted(date: .omitted, time: .shortened)
    }
}
