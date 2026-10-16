import Foundation

/// The editable form of an event, used for both creating and editing.
///
/// Same conventions as `Event`: `end` is exclusive, and for all-day events `start`
/// and `end` are local midnights. The mutating helpers keep those invariants so the
/// editor UI can stay simple.
public struct EventDraft: Hashable, Sendable {
    public var title: String
    public var location: String
    public var notes: String
    public var url: String
    public private(set) var start: Date
    public private(set) var end: Date
    public private(set) var isAllDay: Bool
    /// `nil` means floating time.
    public private(set) var timeZone: TimeZone?
    public var calendarID: String
    public var alarms: [Alarm]
    public var recurrence: RecurrenceRule?
    /// Invitees. EventKit can't change them; for connected Google calendars the
    /// change is saved through Google (see `SaveRoute`).
    public var attendees: [Attendee]
    /// Create a Google Meet link when saving.
    public var addConference = false
    /// The event's existing meeting link, if any.
    public private(set) var conferenceURL: URL?

    public init(event: Event) {
        title = event.title
        location = event.location ?? ""
        notes = event.notes ?? ""
        url = event.url?.absoluteString ?? ""
        start = event.start
        end = event.end
        isAllDay = event.isAllDay
        timeZone = event.timeZone
        calendarID = event.calendarID
        alarms = event.alarms
        recurrence = event.recurrence
        attendees = event.attendees
        conferenceURL = event.conferenceURL
    }

    public init(
        title: String = "",
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        timeZone: TimeZone? = .current,
        calendarID: String,
        alarms: [Alarm] = [],
        recurrence: RecurrenceRule? = nil
    ) {
        self.title = title
        self.location = ""
        self.notes = ""
        self.url = ""
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.calendarID = calendarID
        self.alarms = alarms
        self.recurrence = recurrence
        self.attendees = []
    }

    /// A new event on `day`. Today it starts at the next half hour, other days at 9:00.
    public static func newEvent(
        on day: Date,
        now: Date = Date(),
        calendarID: String,
        duration: TimeInterval = 3600,
        math: CalendarMath
    ) -> EventDraft {
        let start = suggestedStart(on: day, now: now, math: math)
        return EventDraft(start: start, end: start.addingTimeInterval(duration), timeZone: math.calendar.timeZone, calendarID: calendarID)
    }

    /// A new event starting at a specific time, e.g. where the user double-clicked.
    public static func newEvent(at start: Date, calendarID: String, duration: TimeInterval = 3600, math: CalendarMath) -> EventDraft {
        EventDraft(start: start, end: start.addingTimeInterval(duration), timeZone: math.calendar.timeZone, calendarID: calendarID)
    }

    public static func suggestedStart(on day: Date, now: Date, math: CalendarMath) -> Date {
        if math.dayInterval(containing: day).containsHalfOpen(now) {
            let rounded = math.roundedUp(now, toMinutes: 30)
            // Don't spill into tomorrow late in the evening.
            let latest = math.date(on: day, minute: 23 * 60 + 30)
            return min(rounded, latest)
        }
        return math.date(on: day, minute: 9 * 60)
    }

    // MARK: Editing helpers

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Moves the start and keeps the duration (or the number of days, for all-day events).
    public mutating func setStart(_ newStart: Date, math: CalendarMath) {
        if isAllDay {
            let days = max(1, math.calendar.dateComponents([.day], from: start, to: end).day ?? 1)
            start = math.startOfDay(newStart)
            end = math.addingDays(days, to: start)
        } else {
            let length = max(0, duration)
            start = newStart
            end = newStart.addingTimeInterval(length)
        }
    }

    /// Sets the end. An end before the start moves the start back to keep the duration
    /// non-negative, like Apple Calendar.
    public mutating func setEnd(_ newEnd: Date, math: CalendarMath) {
        if isAllDay {
            setAllDayLastDay(newEnd, math: math)
            return
        }
        end = newEnd
        if end < start { start = end }
    }

    /// For all-day events the editor shows the last day, not the exclusive end.
    public func allDayLastDay(math: CalendarMath) -> Date {
        max(start, math.addingDays(-1, to: end))
    }

    public mutating func setAllDayLastDay(_ lastDay: Date, math: CalendarMath) {
        let day = math.startOfDay(lastDay)
        if day < start { start = day }
        end = math.addingDays(1, to: day)
    }

    /// Switching to all-day covers the touched days; switching back gives a one-hour
    /// event at 9:00 on the first day.
    public mutating func setAllDay(_ allDay: Bool, math: CalendarMath) {
        guard allDay != isAllDay else { return }
        isAllDay = allDay
        if allDay {
            let firstDay = math.startOfDay(start)
            let lastInstant = end > start ? end.addingTimeInterval(-1) : start
            start = firstDay
            end = math.addingDays(1, to: math.startOfDay(lastInstant))
        } else {
            start = math.date(on: start, minute: 9 * 60)
            end = start.addingTimeInterval(3600)
            if timeZone == nil { timeZone = math.calendar.timeZone }
        }
    }

    /// Changes the time zone and keeps the wall-clock times (9:00 stays 9:00, now in
    /// the new zone), which is what people expect when they pick a zone.
    public mutating func setTimeZone(_ newZone: TimeZone?, math: CalendarMath) {
        guard !isAllDay else {
            timeZone = newZone
            return
        }
        var old = math.calendar
        old.timeZone = timeZone ?? math.calendar.timeZone
        var new = math.calendar
        new.timeZone = newZone ?? math.calendar.timeZone
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let length = duration
        if let moved = new.date(from: old.dateComponents(fields, from: start)) {
            start = moved
            end = moved.addingTimeInterval(length)
        }
        timeZone = newZone
    }

    // MARK: Validation

    public enum Issue: Hashable, Sendable {
        case endBeforeStart
        case repeatEndsBeforeStart
        case invalidOccurrenceCount
        case invalidURL
    }

    public func issues() -> [Issue] {
        var issues: [Issue] = []
        if isAllDay ? end <= start : end < start {
            issues.append(.endBeforeStart)
        }
        if let rule = recurrence {
            switch rule.end {
            case .until(let date) where date < start: issues.append(.repeatEndsBeforeStart)
            case .afterOccurrences(let count) where count < 1: issues.append(.invalidOccurrenceCount)
            default: break
            }
        }
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty, URL(string: trimmedURL)?.scheme == nil {
            issues.append(.invalidURL)
        }
        return issues
    }

    /// Adds an invitee by email; ignores duplicates and invalid addresses.
    @discardableResult
    public mutating func addAttendee(email: String, name: String? = nil) -> Bool {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Normalization.looksLikeEmail(address),
              !attendees.contains(where: { $0.email?.lowercased() == address }) else { return false }
        attendees.append(Attendee(name: name, email: address, status: .pending, role: .required))
        return true
    }

    public mutating func removeAttendee(email: String) {
        attendees.removeAll { $0.email?.lowercased() == email.lowercased() }
    }

    public var parsedURL: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }
}

/// Which occurrences of a repeating event an edit or delete applies to.
public enum EditScope: Sendable, Hashable {
    case thisEvent
    /// This occurrence and every later one. On the first occurrence, that's the whole series.
    case futureEvents

    /// The scopes the user may choose from when saving. Empty or single means don't ask.
    /// Moving a repeating event to another calendar or changing its repeat rule only
    /// makes sense for the series going forward.
    public static func saveChoices(original: Event?, draft: EventDraft) -> [EditScope] {
        guard let original, original.isRecurring else { return [.thisEvent] }
        if draft.calendarID != original.calendarID || draft.recurrence != original.recurrence {
            return [.futureEvents]
        }
        return [.thisEvent, .futureEvents]
    }

    public static func deleteChoices(for event: Event) -> [EditScope] {
        event.isRecurring ? [.thisEvent, .futureEvents] : [.thisEvent]
    }
}

/// Errors any provider may throw when writing.
public enum ProviderError: Error, Equatable, Sendable {
    case eventNotFound
    case calendarNotFound
    case calendarIsReadOnly
}
