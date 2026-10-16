import CalendarDomain
import Foundation
import Testing

struct CalendarMathTests {
    let cal = makeCalendar()
    var math: CalendarMath { CalendarMath(calendar: cal) }

    @Test func weekStartsOnConfiguredWeekday() {
        // Wednesday 2026-10-14.
        let week = math.weekInterval(containing: cal.date(2026, 10, 14, 15))
        #expect(week.start == cal.date(2026, 10, 12)) // Monday
        #expect(week.end == cal.date(2026, 10, 19))

        let sundayMath = CalendarMath(calendar: makeCalendar(firstWeekday: 1))
        let sundayWeek = sundayMath.weekInterval(containing: cal.date(2026, 10, 14, 15))
        #expect(sundayWeek.start == cal.date(2026, 10, 11))
    }

    @Test func orderedWeekdaySymbolsFollowFirstWeekday() {
        #expect(math.orderedWeekdaySymbols().first == "Mon")
        #expect(CalendarMath(calendar: makeCalendar(firstWeekday: 1)).orderedWeekdaySymbols().first == "Sun")
    }

    @Test func daysAcrossDSTEndAreCalendarDays() {
        // The week of the 2026-10-25 fall-back (25-hour Sunday).
        let week = math.weekInterval(containing: cal.date(2026, 10, 22))
        let days = math.days(in: week)
        #expect(days.count == 7)
        #expect(days.allSatisfy { cal.component(.hour, from: $0) == 0 })
        #expect(days.last == cal.date(2026, 10, 25))
        #expect(math.dayInterval(containing: cal.date(2026, 10, 25, 12)).duration == 25 * 3600)
        #expect(math.dayInterval(containing: cal.date(2026, 3, 29, 12)).duration == 23 * 3600)
    }

    @Test func monthGridCoversWholeWeeks() {
        let grid = math.monthGrid(containing: cal.date(2026, 10, 6))
        #expect(grid.allSatisfy { $0.count == 7 })
        #expect(grid.first?.first == cal.date(2026, 9, 28)) // Monday before Oct 1 (a Thursday)
        #expect(grid.last?.last == cal.date(2026, 11, 1)) // Sunday after Oct 31 (a Saturday)
        #expect(grid.count == 5)
    }

    @Test func monthVisibleIntervalIncludesGridPadding() {
        let interval = math.visibleInterval(for: .month, containing: cal.date(2026, 10, 6))
        #expect(interval.start == cal.date(2026, 9, 28))
        #expect(interval.end == cal.date(2026, 11, 2))
    }

    @Test func steppingByMonthClampsDay() {
        let jan31 = cal.date(2027, 1, 31, 10)
        #expect(math.step(jan31, by: 1, period: .month) == cal.date(2027, 2, 28, 10))
    }

    @Test func steppingByDayKeepsWallClockAcrossDST() {
        let saturday = cal.date(2026, 10, 24, 9)
        #expect(math.step(saturday, by: 1, period: .day) == cal.date(2026, 10, 25, 9))
        #expect(math.step(saturday, by: 1, period: .days, dayCount: 7) == cal.date(2026, 10, 31, 9))
    }

    @Test func agendaShowsThirtyDays() {
        let interval = math.visibleInterval(for: .agenda, containing: cal.date(2026, 10, 6, 13))
        #expect(interval.start == cal.date(2026, 10, 6))
        #expect(math.days(in: interval).count == CalendarPeriod.agendaLength)
    }

    @Test func dayCountViewStartsAtSelectedDay() {
        let interval = math.visibleInterval(for: .days, containing: cal.date(2026, 10, 23, 15), dayCount: 4)
        #expect(interval.start == cal.date(2026, 10, 23))
        #expect(interval.end == cal.date(2026, 10, 27)) // through the DST change
        #expect(math.days(in: interval).count == 4)
        #expect(math.step(cal.date(2026, 10, 23, 15), by: -1, period: .days, dayCount: 4) == cal.date(2026, 10, 19, 15))
    }

    @Test func dayCountIsClamped() {
        #expect(math.days(in: math.visibleInterval(for: .days, containing: cal.date(2026, 10, 1), dayCount: 1)).count == 2)
        #expect(math.days(in: math.visibleInterval(for: .days, containing: cal.date(2026, 10, 1), dayCount: 40)).count == 14)
    }
}
