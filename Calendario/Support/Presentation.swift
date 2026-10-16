import CalendarDomain
import SwiftUI

extension Color {
    init(_ rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension CalendarPeriod {
    var label: String {
        switch self {
        case .day: String(localized: "Day")
        case .days: String(localized: "Days")
        case .month: String(localized: "Month")
        case .agenda: String(localized: "Agenda")
        }
    }
}

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSinceReferenceDate }
}

/// Human-readable strings for events. All formatting goes through the user's locale,
/// so 12/24-hour time and date order follow System Settings.
enum EventText {
    static func startTime(_ event: Event) -> String {
        event.start.formatted(date: .omitted, time: .shortened)
    }

    static func timeRange(_ event: Event) -> String {
        if event.isAllDay { return String(localized: "All day") }
        return timeRange(start: event.start, end: event.end)
    }

    static func timeRange(start: Date, end: Date) -> String {
        (start..<max(start, end)).formatted(.interval.hour().minute())
    }

    /// Full date and time span, for the detail popover.
    static func fullRange(_ event: Event, math: CalendarMath) -> String {
        if event.isAllDay {
            let lastDay = math.addingDays(-1, to: event.end)
            if lastDay <= event.start {
                return event.start.formatted(date: .complete, time: .omitted)
            }
            return (event.start..<lastDay).formatted(.interval.weekday().day().month().year())
        }
        return (event.start..<event.end).formatted(.interval.weekday().day().month().year().hour().minute())
    }

    /// A readable description of the series an occurrence belongs to, e.g.
    /// "Every week on Wednesday at 14:00", "Every 2 weeks on Mon, Thu", "Every month on day 11".
    static func seriesSummary(_ event: Event) -> String {
        guard let rule = event.recurrence else {
            // No rule known: at least say when it happens.
            let weekday = event.start.formatted(.dateTime.weekday(.wide))
            return event.isAllDay
                ? String(localized: "Repeating event, on \(weekday)s")
                : String(localized: "Repeating event, \(weekday)s at \(event.start.formatted(date: .omitted, time: .shortened))")
        }
        let calendar = Calendar.current
        let n = rule.interval
        let weekdayNames = calendar.weekdaySymbols
        let shortNames = calendar.shortWeekdaySymbols

        var text: String
        switch rule.frequency {
        case .daily:
            text = n == 1 ? String(localized: "Every day") : String(localized: "Every \(n) days")
        case .weekly:
            let days = rule.daysOfWeek.map(\.weekday)
            let on = days.count > 1
                ? days.map { shortNames[$0 - 1] }.joined(separator: ", ")
                : weekdayNames[(days.first ?? calendar.component(.weekday, from: event.start)) - 1]
            text = n == 1 ? String(localized: "Every week on \(on)") : String(localized: "Every \(n) weeks on \(on)")
        case .monthly:
            if let day = rule.daysOfWeek.first, day.weekNumber != 0 {
                let ordinalFormatter = NumberFormatter()
                ordinalFormatter.numberStyle = .ordinal
                let ordinal = day.weekNumber == -1
                    ? String(localized: "last")
                    : ordinalFormatter.string(from: NSNumber(value: day.weekNumber)) ?? "\(day.weekNumber)"
                text = String(localized: "Every month on the \(ordinal) \(weekdayNames[day.weekday - 1])")
            } else {
                let dayOfMonth = rule.daysOfMonth.first ?? calendar.component(.day, from: event.start)
                text = n == 1 ? String(localized: "Every month on day \(dayOfMonth)") : String(localized: "Every \(n) months on day \(dayOfMonth)")
            }
        case .yearly:
            text = String(localized: "Every year on \(event.start.formatted(.dateTime.day().month(.wide)))")
        }
        if !event.isAllDay {
            text += " " + String(localized: "at \(event.start.formatted(date: .omitted, time: .shortened))")
        }
        switch rule.end {
        case .never: break
        case .afterOccurrences(let count): text += ", " + String(localized: "\(count) times")
        case .until(let date): text += ", " + String(localized: "until \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        return text
    }

    static func recurrence(_ rule: RecurrenceRule) -> String {
        let unit: String = switch rule.frequency {
        case .daily: rule.interval == 1 ? String(localized: "Repeats daily") : String(localized: "Repeats every \(rule.interval) days")
        case .weekly: rule.interval == 1 ? String(localized: "Repeats weekly") : String(localized: "Repeats every \(rule.interval) weeks")
        case .monthly: rule.interval == 1 ? String(localized: "Repeats monthly") : String(localized: "Repeats every \(rule.interval) months")
        case .yearly: rule.interval == 1 ? String(localized: "Repeats yearly") : String(localized: "Repeats every \(rule.interval) years")
        }
        switch rule.end {
        case .never: return unit
        case .afterOccurrences(let count): return unit + ", " + String(localized: "\(count) times")
        case .until(let date): return unit + ", " + String(localized: "until \(date.formatted(date: .abbreviated, time: .omitted))")
        }
    }

    /// All-day alerts count from midnight, so "-15 h" reads as "1 day before (9:00)".
    static func alarm(_ alarm: Alarm, isAllDay: Bool) -> String {
        guard isAllDay, case .relative(let offset) = alarm else { return self.alarm(alarm) }
        let day: TimeInterval = 86_400
        let daysBefore = Int(-(offset / day).rounded(.down))
        let secondsIntoDay = offset + TimeInterval(daysBefore) * day
        var reference = Calendar.current.startOfDay(for: Date())
        reference.addTimeInterval(secondsIntoDay)
        let time = reference.formatted(date: .omitted, time: .shortened)
        return switch daysBefore {
        case 0: String(localized: "On day of event (\(time))")
        case 1: String(localized: "1 day before (\(time))")
        case 7: String(localized: "1 week before (\(time))")
        default: String(localized: "\(daysBefore) days before (\(time))")
        }
    }

    static func attendeeColor(_ status: Attendee.Status) -> Color {
        switch status {
        case .accepted: .green
        case .declined: .red
        case .tentative: .orange
        default: .secondary
        }
    }

    static func attendeeStatus(_ status: Attendee.Status) -> String {
        switch status {
        case .accepted: String(localized: "accepted")
        case .declined: String(localized: "declined")
        case .tentative: String(localized: "maybe")
        case .pending: String(localized: "invited")
        case .delegated: String(localized: "delegated")
        default: ""
        }
    }

    static func alarm(_ alarm: Alarm) -> String {
        switch alarm {
        case .absolute(let date):
            return date.formatted(date: .abbreviated, time: .shortened)
        case .relative(let offset):
            if offset == 0 { return String(localized: "At time of event") }
            let duration = Duration.seconds(abs(offset))
            let text = duration.formatted(.units(allowed: [.weeks, .days, .hours, .minutes], width: .wide))
            return offset < 0 ? String(localized: "\(text) before") : String(localized: "\(text) after")
        }
    }
}
