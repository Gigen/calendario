import Foundation

/// A repeat rule, modelled on RFC 5545 RRULE (the subset EventKit and Google both support).
public struct RecurrenceRule: Hashable, Sendable {
    public enum Frequency: String, Sendable, Hashable, CaseIterable {
        case daily, weekly, monthly, yearly
    }

    public enum End: Hashable, Sendable {
        case never
        case afterOccurrences(Int)
        case until(Date)
    }

    public struct DayOfWeek: Hashable, Sendable {
        /// 1 = Sunday ... 7 = Saturday (Foundation's `Calendar` convention).
        public var weekday: Int
        /// 0 = every such weekday; 1 = first, 2 = second, ..., -1 = last.
        public var weekNumber: Int

        public init(weekday: Int, weekNumber: Int = 0) {
            self.weekday = weekday
            self.weekNumber = weekNumber
        }
    }

    public var frequency: Frequency
    public var interval: Int
    public var end: End
    public var daysOfWeek: [DayOfWeek]
    /// 1...31, or negative to count from the end of the month.
    public var daysOfMonth: [Int]
    /// 1...12
    public var monthsOfYear: [Int]
    public var setPositions: [Int]

    public init(
        frequency: Frequency,
        interval: Int = 1,
        end: End = .never,
        daysOfWeek: [DayOfWeek] = [],
        daysOfMonth: [Int] = [],
        monthsOfYear: [Int] = [],
        setPositions: [Int] = []
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.end = end
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.setPositions = setPositions
    }
}
