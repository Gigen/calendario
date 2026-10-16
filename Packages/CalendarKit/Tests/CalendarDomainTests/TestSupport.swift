import CalendarDomain
import Foundation

/// A Gregorian calendar with a fixed zone and week start, so tests don't depend on
/// the machine's settings. Berlin has DST: 2026-03-29 (23 h) and 2026-10-25 (25 h).
func makeCalendar(timeZone: String = "Europe/Berlin", firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    calendar.firstWeekday = firstWeekday
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

extension Calendar {
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}

func makeEvent(
    _ id: String,
    _ start: Date,
    _ end: Date,
    allDay: Bool = false,
    title: String? = nil,
    calendarID: String = "cal"
) -> Event {
    Event(id: id, seriesID: id, calendarID: calendarID, title: title ?? id, start: start, end: end, isAllDay: allDay)
}
