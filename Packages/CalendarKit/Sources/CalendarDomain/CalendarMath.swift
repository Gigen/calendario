import Foundation

extension DateInterval {
    /// `start <= date < end`. `contains` includes the end, which puts the next
    /// day's midnight into today.
    public func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

/// The span of time a view shows.
public enum CalendarPeriod: String, Sendable, Hashable, CaseIterable, Codable {
    /// `days` shows a chosen number of days (2...14) starting at the selected day.
    case day, days, month, agenda

    /// How many days the agenda shows at once.
    public static let agendaLength = 30

    public static let dayCountRange = 2...14
    public static let defaultDayCount = 4
}

/// Date arithmetic for the views. Always goes through the injected `Calendar`, so week
/// start, time zone and DST come from the system settings rather than being hardcoded.
/// Never adds 86 400 seconds to step a day.
public struct CalendarMath: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    public func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    public func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }

    /// The whole local day containing `date`. 23 or 25 hours long on DST changes.
    public func dayInterval(containing date: Date) -> DateInterval {
        let start = startOfDay(date)
        return DateInterval(start: start, end: addingDays(1, to: start))
    }

    /// The week containing `date`, starting on the locale's (or user's) first weekday.
    public func weekInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    public func monthInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .month, for: date)!
    }

    /// Start-of-day dates for each day in `interval`, which should start at midnight.
    public func days(in interval: DateInterval) -> [Date] {
        var days: [Date] = []
        var day = startOfDay(interval.start)
        while day < interval.end {
            days.append(day)
            day = addingDays(1, to: day)
        }
        return days
    }

    /// Full weeks covering the month containing `date`, as rows of 7 days.
    public func monthGrid(containing date: Date) -> [[Date]] {
        let month = monthInterval(containing: date)
        let firstWeek = weekInterval(containing: month.start)
        let lastWeek = weekInterval(containing: month.end.addingTimeInterval(-1))
        let all = days(in: DateInterval(start: firstWeek.start, end: lastWeek.end))
        return stride(from: 0, to: all.count, by: 7).map { Array(all[$0..<min($0 + 7, all.count)]) }
    }

    /// The interval a view of `period` shows for `date`. For month, this includes the
    /// leading and trailing days of the grid.
    public func visibleInterval(for period: CalendarPeriod, containing date: Date, dayCount: Int = CalendarPeriod.defaultDayCount) -> DateInterval {
        switch period {
        case .day:
            return dayInterval(containing: date)
        case .days:
            let start = startOfDay(date)
            return DateInterval(start: start, end: addingDays(Self.clampedDayCount(dayCount), to: start))
        case .month:
            let grid = monthGrid(containing: date)
            return DateInterval(start: grid.first!.first!, end: addingDays(1, to: grid.last!.last!))
        case .agenda:
            let start = startOfDay(date)
            return DateInterval(start: start, end: addingDays(CalendarPeriod.agendaLength, to: start))
        }
    }

    /// Moves `date` by `count` periods (negative goes back).
    public func step(_ date: Date, by count: Int, period: CalendarPeriod, dayCount: Int = CalendarPeriod.defaultDayCount) -> Date {
        switch period {
        case .day: addingDays(count, to: date)
        case .days: addingDays(count * Self.clampedDayCount(dayCount), to: date)
        case .month: calendar.date(byAdding: .month, value: count, to: date)!
        case .agenda: addingDays(count * CalendarPeriod.agendaLength, to: date)
        }
    }

    public static func clampedDayCount(_ count: Int) -> Int {
        min(max(count, CalendarPeriod.dayCountRange.lowerBound), CalendarPeriod.dayCountRange.upperBound)
    }

    /// Short weekday names in display order, starting at the first weekday.
    public func orderedWeekdaySymbols() -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The time `minute` minutes after midnight (by wall clock) on the day of `day`.
    /// On a DST day a skipped time resolves to the next valid one.
    public func date(on day: Date, minute: Int) -> Date {
        let clamped = min(max(minute, 0), 24 * 60 - 1)
        return calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: startOfDay(day))
            ?? startOfDay(day).addingTimeInterval(TimeInterval(clamped * 60))
    }

    /// Rounds up to the next multiple of `step` minutes on the wall clock (12:01 -> 12:30).
    /// Times already on a step boundary stay put.
    public func roundedUp(_ date: Date, toMinutes step: Int) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let minute = parts.minute ?? 0
        if minute % step == 0, (parts.second ?? 0) == 0, (parts.nanosecond ?? 0) == 0 { return date }
        // Rebuild from components; `date(bySetting:)` would search forward instead.
        parts.minute = minute - minute % step
        parts.second = 0
        parts.nanosecond = 0
        guard let base = calendar.date(from: parts) else { return date }
        return calendar.date(byAdding: .minute, value: step, to: base) ?? date
    }

    /// Snaps minutes-since-midnight to the nearest lower multiple of `step`.
    public func snappedMinute(_ minute: Int, toMinutes step: Int) -> Int {
        min(max(0, minute - minute % step), 24 * 60 - step)
    }

    /// Minutes since local midnight, by wall clock. Positions events in the day grid.
    /// On DST days this keeps 9:00 at the 9:00 row.
    public func wallClockMinutes(of date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
