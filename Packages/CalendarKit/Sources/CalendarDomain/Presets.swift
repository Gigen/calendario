import Foundation

/// The repeat choices offered in the editor's menu. Anything else is `.custom`.
public enum RecurrencePreset: String, Hashable, Sendable, CaseIterable {
    case none, daily, weekdays, weekly, biweekly, monthly, yearly, custom

    /// Monday to Friday.
    public static let weekdaySet: [RecurrenceRule.DayOfWeek] = (2...6).map { .init(weekday: $0) }

    /// The preset matching `rule` for an event starting at `start`. Rules saved by
    /// Calendar.app often spell out the start's weekday or day of month; those still
    /// count as the simple preset.
    public static func detect(_ rule: RecurrenceRule?, start: Date, calendar: Calendar) -> RecurrencePreset {
        guard let rule else { return .none }
        guard rule.monthsOfYear.isEmpty || rule.frequency == .yearly, rule.setPositions.isEmpty else { return .custom }
        let weekday = calendar.component(.weekday, from: start)
        let dayOfMonth = calendar.component(.day, from: start)
        let onStartWeekdayOnly = rule.daysOfWeek.isEmpty || rule.daysOfWeek == [.init(weekday: weekday)]

        switch rule.frequency {
        case .daily:
            return rule.interval == 1 && rule.daysOfWeek.isEmpty && rule.daysOfMonth.isEmpty ? .daily : .custom
        case .weekly:
            guard rule.daysOfMonth.isEmpty else { return .custom }
            if rule.interval == 1, Set(rule.daysOfWeek) == Set(weekdaySet) { return .weekdays }
            guard onStartWeekdayOnly else { return .custom }
            switch rule.interval {
            case 1: return .weekly
            case 2: return .biweekly
            default: return .custom
            }
        case .monthly:
            let simple = rule.daysOfWeek.isEmpty && (rule.daysOfMonth.isEmpty || rule.daysOfMonth == [dayOfMonth])
            return rule.interval == 1 && simple ? .monthly : .custom
        case .yearly:
            let month = calendar.component(.month, from: start)
            let simple = rule.daysOfWeek.isEmpty && rule.daysOfMonth.isEmpty
                && (rule.monthsOfYear.isEmpty || rule.monthsOfYear == [month])
            return rule.interval == 1 && simple ? .yearly : .custom
        }
    }

    /// The rule for this preset. `nil` for `.none`; `.custom` has no rule of its own.
    public func rule(end: RecurrenceRule.End = .never) -> RecurrenceRule? {
        switch self {
        case .none, .custom: nil
        case .daily: RecurrenceRule(frequency: .daily, end: end)
        case .weekdays: RecurrenceRule(frequency: .weekly, end: end, daysOfWeek: Self.weekdaySet)
        case .weekly: RecurrenceRule(frequency: .weekly, end: end)
        case .biweekly: RecurrenceRule(frequency: .weekly, interval: 2, end: end)
        case .monthly: RecurrenceRule(frequency: .monthly, end: end)
        case .yearly: RecurrenceRule(frequency: .yearly, end: end)
        }
    }
}

extension RecurrenceRule.End {
    /// A repeat end chosen as a calendar day includes that whole day, so a 10:00
    /// occurrence on the last day still happens.
    public static func until(day: Date, math: CalendarMath) -> RecurrenceRule.End {
        .until(math.addingDays(1, to: math.startOfDay(day)).addingTimeInterval(-1))
    }
}

/// Alert choices offered in the editor, as offsets from the start.
public enum AlarmPresets {
    public static let timed: [TimeInterval] = [
        0, -5 * 60, -10 * 60, -15 * 60, -30 * 60, -3600, -2 * 3600, -86_400, -2 * 86_400, -7 * 86_400,
    ]

    /// For all-day events the offset counts from midnight, so these fire at 9:00
    /// on the day, one day before, two days before and one week before.
    public static let allDay: [TimeInterval] = [
        9 * 3600, -15 * 3600, -(24 + 15) * 3600, -(6 * 24 + 15) * 3600,
    ]

    public static func presets(allDay: Bool) -> [TimeInterval] {
        allDay ? self.allDay : timed
    }
}
