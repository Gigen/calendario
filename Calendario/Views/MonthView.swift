import CalendarDomain
import SwiftUI

/// A month grid of whole weeks. Multi-day events appear in each day they cover.
struct MonthView: View {
    @Environment(\.calendarTheme) private var theme
    let month: Date
    let events: [Event]
    let tasks: [TaskItem]
    let math: CalendarMath
    var onOpenDay: (Date) -> Void

    var body: some View {
        let grid = math.monthGrid(containing: month)
        let layout = DayLayout(math: math)
        let monthInterval = math.monthInterval(containing: month)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(math.orderedWeekdaySymbols(), id: \.self) { symbol in
                    Text(symbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }
            }
            .padding(.vertical, 4)
            Divider()
            GeometryReader { geometry in
                let rowHeight = geometry.size.height / CGFloat(max(grid.count, 1))
                VStack(spacing: 0) {
                    ForEach(grid, id: \.first) { week in
                        HStack(spacing: 0) {
                            ForEach(week) { day in
                                MonthDayCell(
                                    day: day,
                                    items: DayItem.merged(
                                        events: layout.events(events, on: day),
                                        tasks: TaskLayout.tasks(tasks, dueOn: day, math: math)
                                    ),
                                    isInMonth: monthInterval.containsHalfOpen(day),
                                    isToday: math.calendar.isDateInToday(day),
                                    height: rowHeight,
                                    onOpenDay: onOpenDay
                                )
                                .frame(width: geometry.size.width / 7, height: rowHeight)
                                .overlay(alignment: .trailing) { Divider() }
                            }
                        }
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
            .background { theme.pageBackground }
        }
    }
}

private struct MonthDayCell: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(\.eventActions) private var actions
    let day: Date
    let items: [DayItem]
    let isInMonth: Bool
    let isToday: Bool
    let height: CGFloat
    var onOpenDay: (Date) -> Void

    private let rowHeight: CGFloat = 19
    private let headerHeight: CGFloat = 24

    var body: some View {
        let capacity = max(0, Int((height - headerHeight) / rowHeight))
        // Leave room for the "more" line when the items don't all fit.
        let shown = items.count > capacity ? max(0, capacity - 1) : items.count

        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Spacer()
                Text(day.formatted(.dateTime.day()))
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(isToday ? Color.white : (isInMonth ? Color.primary : Color.secondary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background { if isToday { Capsule().fill(Color.accentColor) } }
            }
            .frame(height: headerHeight - 4)
            ForEach(items.prefix(shown)) { item in
                DayItemChip(item: item)
                    .frame(height: rowHeight - 1)
            }
            if shown < items.count {
                Button("\(items.count - shown) more") { onOpenDay(day) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(2)
        .background(isInMonth ? Color.clear : Color.secondary.opacity(0.06))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.create(.on(day: day)) }
    }
}
