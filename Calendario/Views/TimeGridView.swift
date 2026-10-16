import CalendarDomain
import SwiftUI

/// Day and week views: one column per day, an all-day strip and a scrolling 24-hour grid.
struct TimeGridView: View {
    @Environment(\.calendarTheme) private var theme
    let days: [Date]
    let events: [Event]
    let tasks: [TaskItem]
    let math: CalendarMath
    var onOpenDay: (Date) -> Void

    /// ⌘+ / ⌘− change this (see `GridZoom`).
    @AppStorage(GridZoom.key) private var zoom = 1.0
    private var hourHeight: CGFloat { GridZoom.baseHourHeight * GridZoom.clamped(zoom) }
    private let gutter: CGFloat = 56
    /// Rows in the all-day strip (all-day events and reminders) before "N more".
    private var maxAllDayRows: Int { days.count == 1 ? 8 : 3 }

    private var layout: DayLayout { DayLayout(math: math) }

    var body: some View {
        VStack(spacing: 0) {
            header
            allDayStrip
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        ForEach(days) { day in
                            Divider()
                            DayColumn(day: day, placements: layout.placements(for: events, tasks: tasks, on: day), math: math, hourHeight: hourHeight)
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .background(alignment: .top) { hourLines }
                    .background { theme.pageBackground.padding(.leading, gutter) }
                }
                .onAppear { proxy.scrollTo(initialScrollHour, anchor: .top) }
            }
        }
    }

    /// Start around the current hour when today is visible, else at 8:00.
    private var initialScrollHour: Int {
        if Demo.isCapturing { return 8 }
        let now = Date()
        if days.contains(where: { math.dayInterval(containing: $0).containsHalfOpen(now) }) {
            return max(0, math.calendar.component(.hour, from: now) - 2)
        }
        return 8
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days) { day in
                let isToday = math.calendar.isDateInToday(day)
                Button { onOpenDay(day) } label: {
                    HStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day()))
                            .fontWeight(.semibold)
                            .foregroundStyle(isToday ? Color.white : Color.primary)
                            .padding(.horizontal, 5)
                            .background { if isToday { Capsule().fill(Color.accentColor) } }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Day")
            }
        }
        .padding(.vertical, 6)
    }

    @Environment(\.eventActions) private var actions

    private var allDayStrip: some View {
        let perDay = days.map { day in
            DayItem.merged(
                events: layout.events(events, on: day).filter(\.isAllDay),
                // Timed reminders are in the grid at their time; only day-only ones here.
                tasks: TaskLayout.tasks(tasks, dueOn: day, math: math).filter { $0.due?.hasTime == false }
            )
        }
        let hasAny = perDay.contains { !$0.isEmpty }
        return HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: gutter, alignment: .trailing)
                .padding(.trailing, 4)
                .opacity(hasAny ? 1 : 0)
            ForEach(Array(zip(days, perDay)), id: \.0) { day, allDay in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allDay.prefix(maxAllDayRows)) { item in
                        DayItemChip(item: item)
                    }
                    if allDay.count > maxAllDayRows {
                        Button("\(allDay.count - maxAllDayRows) more") { onOpenDay(day) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { actions.create(.allDay(day: day)) }
            }
        }
        .padding(.bottom, 4)
        .help("Double-click to add an all-day event")
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter - 6, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -7)
                    .opacity(hour == 0 ? 0 : 1)
                    .id(hour)
            }
        }
        .padding(.trailing, 6)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                VStack(spacing: 0) {
                    Divider()
                    Spacer(minLength: 0)
                }
                .frame(height: hourHeight)
            }
        }
        .padding(.leading, gutter)
    }

    /// "13" or "1 PM", depending on the user's 12/24-hour setting.
    private func hourLabel(_ hour: Int) -> String {
        let reference = math.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: days.first ?? Date()) ?? Date()
        return reference.formatted(.dateTime.hour())
    }
}

private struct DayColumn: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(\.eventActions) private var actions
    let day: Date
    let placements: [DayLayout.Placement]
    let math: CalendarMath
    let hourHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                // Double-click empty space for a new event at that quarter hour.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { location in
                        let minute = math.snappedMinute(Int(location.y / hourHeight * 60), toMinutes: 15)
                        actions.create(.at(start: math.date(on: day, minute: minute)))
                    }
                ForEach(placements, id: \.item.id) { placement in
                    let columnWidth = width / CGFloat(placement.columnCount)
                    let top = CGFloat(placement.startMinute) / 60 * hourHeight
                    Group {
                        switch placement.item {
                        case .event(let event):
                            let height = max(CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight, 18)
                            EventBlock(event: event, placement: placement, height: height)
                                .frame(height: height)
                        case .task(let task):
                            // No length: as tall as the layout's minimum slot (20 min).
                            TaskBlock(task: task)
                                .frame(height: max(hourHeight / 3, 16))
                        }
                    }
                    .frame(width: max(columnWidth - 2, 4))
                    .offset(x: CGFloat(placement.column) * columnWidth + 1, y: top)
                }
                CurrentTimeLine(day: day, math: math, hourHeight: hourHeight)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CurrentTimeLine: View {
    @Environment(\.calendarTheme) private var theme
    let day: Date
    let math: CalendarMath
    let hourHeight: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            if math.dayInterval(containing: day).containsHalfOpen(context.date) {
                let y = CGFloat(math.wallClockMinutes(of: context.date)) / 60 * hourHeight
                Rectangle()
                    .fill(.red)
                    .frame(height: 1.5)
                    .offset(y: y)
                    .allowsHitTesting(false)
            }
        }
    }
}
