import CalendarDomain
import Foundation

// Google Calendar API v3 event JSON, limited to the fields this app writes or reads.

/// A JSON value passed through untouched (e.g. existing attendees' fields).
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// The request body for events.insert / events.patch. Nil fields are omitted, which
/// for PATCH means "leave unchanged".
struct GoogleEventBody: Encodable, Equatable {
    struct When: Encodable, Equatable {
        var date: String?
        var dateTime: String?
        var timeZone: String?
    }

    struct Reminders: Encodable, Equatable {
        struct Override: Encodable, Equatable {
            var method = "popup"
            var minutes: Int
        }
        var useDefault: Bool
        var overrides: [Override]
    }

    struct ConferenceData: Encodable, Equatable {
        struct CreateRequest: Encodable, Equatable {
            struct SolutionKey: Encodable, Equatable { var type = "hangoutsMeet" }
            var requestId: String
            var conferenceSolutionKey = SolutionKey()
        }
        var createRequest: CreateRequest
    }

    var summary: String?
    var location: String?
    var description: String?
    var start: When?
    var end: When?
    var recurrence: [String]?
    var attendees: [JSONValue]?
    var reminders: Reminders?
    var conferenceData: ConferenceData?
}

/// The fields read back from Google.
struct GoogleEvent: Decodable {
    struct ConferenceData: Decodable {
        struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
        struct CreateRequest: Decodable {
            struct Status: Decodable { let statusCode: String? }
            let status: Status?
        }
        let entryPoints: [EntryPoint]?
        let createRequest: CreateRequest?
    }

    struct When: Decodable { let date: String?; let dateTime: String? }

    let id: String
    let iCalUID: String?
    let summary: String?
    let start: When?
    let htmlLink: String?
    let hangoutLink: String?
    let conferenceData: ConferenceData?
    let attendees: [JSONValue]?
    /// Set on the series itself (RRULE lines).
    let recurrence: [String]?
    /// Set on occurrences changed individually: the series they belong to.
    let recurringEventId: String?

    var meetURL: URL? {
        let video = conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        return (video ?? hangoutLink).flatMap(URL.init(string:))
    }

    var conferencePending: Bool {
        conferenceData?.createRequest?.status?.statusCode == "pending"
    }
}

enum GoogleEventMapping {
    /// The full body for a new event.
    static func insertBody(for draft: EventDraft, calendar: Calendar, conferenceRequestID: String) -> GoogleEventBody {
        let (start, end) = times(for: draft, calendar: calendar)
        return GoogleEventBody(
            summary: draft.title,
            location: draft.location.isEmpty ? nil : draft.location,
            description: draft.notes.isEmpty ? nil : draft.notes,
            start: start,
            end: end,
            recurrence: draft.recurrence.map { [rrule($0, isAllDay: draft.isAllDay, calendar: calendar)] },
            attendees: draft.attendees.isEmpty ? nil : draft.attendees.compactMap(\.email).map { .object(["email": .string($0)]) },
            reminders: reminders(for: draft),
            conferenceData: draft.addConference ? .init(createRequest: .init(requestId: conferenceRequestID)) : nil
        )
    }

    /// Only what changed between `original` and `updated`, for PATCH. Attendees that
    /// stay keep their existing Google fields (like their response status).
    static func patchBody(
        original: EventDraft,
        updated: EventDraft,
        existingAttendees: [JSONValue],
        calendar: Calendar,
        conferenceRequestID: String
    ) -> GoogleEventBody {
        var body = GoogleEventBody()
        if updated.title != original.title { body.summary = updated.title }
        if updated.location != original.location { body.location = updated.location }
        if updated.notes != original.notes { body.description = updated.notes }
        if updated.start != original.start || updated.end != original.end
            || updated.isAllDay != original.isAllDay || updated.timeZone != original.timeZone {
            (body.start, body.end) = times(for: updated, calendar: calendar)
        }
        if updated.alarms != original.alarms { body.reminders = reminders(for: updated) }

        let originalEmails = Set(original.attendees.compactMap { $0.email?.lowercased() })
        let updatedEmails = updated.attendees.compactMap { $0.email?.lowercased() }
        if Set(updatedEmails) != originalEmails {
            let existingByEmail = Dictionary(
                existingAttendees.compactMap { value in value["email"]?.stringValue.map { ($0.lowercased(), value) } },
                uniquingKeysWith: { first, _ in first }
            )
            // Keep the organizer's own entry if Google lists it, so it isn't dropped.
            let organizer = existingAttendees.filter { $0["organizer"] == .bool(true) && !updatedEmails.contains($0["email"]?.stringValue?.lowercased() ?? "") }
            body.attendees = organizer + updatedEmails.map { existingByEmail[$0] ?? .object(["email": .string($0)]) }
        }
        if updated.addConference {
            body.conferenceData = .init(createRequest: .init(requestId: conferenceRequestID))
        }
        return body
    }

    /// The attendee list with the user's own response changed. Everyone else is sent
    /// back untouched (PATCH replaces the whole list). The user's entry is the one
    /// Google marks `self`, or failing that the one with the account's email.
    static func attendees(_ attendees: [JSONValue], respondingAs email: String, with status: Attendee.Status) -> [JSONValue]? {
        let value: String
        switch status {
        case .accepted: value = "accepted"
        case .declined: value = "declined"
        case .tentative: value = "tentative"
        default: return nil
        }
        var index = attendees.firstIndex { $0["self"] == .bool(true) }
        if index == nil {
            index = attendees.firstIndex { $0["email"]?.stringValue?.lowercased() == email.lowercased() }
        }
        guard let index, case .object(var entry) = attendees[index] else { return nil }
        entry["responseStatus"] = .string(value)
        var updated = attendees
        updated[index] = .object(entry)
        return updated
    }

    /// Timed events carry their zone (floating ones get the current zone, since Google
    /// has no floating time); all-day events are plain dates with an exclusive end.
    static func times(for draft: EventDraft, calendar: Calendar) -> (GoogleEventBody.When, GoogleEventBody.When) {
        if draft.isAllDay {
            return (.init(date: dateString(draft.start, calendar: calendar)), .init(date: dateString(draft.end, calendar: calendar)))
        }
        let zone = draft.timeZone ?? calendar.timeZone
        return (
            .init(dateTime: dateTimeString(draft.start, zone: zone), timeZone: zone.identifier),
            .init(dateTime: dateTimeString(draft.end, zone: zone), timeZone: zone.identifier)
        )
    }

    /// Google reminders are "minutes before the start" (up to 5, at most 4 weeks).
    /// For all-day events the start is midnight. Alerts after the start can't be
    /// expressed and are left out.
    static func reminders(for draft: EventDraft) -> GoogleEventBody.Reminders {
        let minutes: [Int] = draft.alarms.compactMap { alarm in
            let secondsBefore: TimeInterval = switch alarm {
            case .relative(let offset): -offset
            case .absolute(let date): draft.start.timeIntervalSince(date)
            }
            guard secondsBefore >= 0 else { return nil }
            let value = Int((secondsBefore / 60).rounded())
            return value <= 40_320 ? value : nil
        }
        return .init(useDefault: false, overrides: Array(Set(minutes)).sorted().prefix(5).map { .init(minutes: $0) })
    }

    /// RFC 5545 RRULE. UNTIL is a date for all-day events and a UTC time otherwise,
    /// matching the start's value type as the RFC requires.
    static func rrule(_ rule: RecurrenceRule, isAllDay: Bool, calendar: Calendar) -> String {
        let frequency = switch rule.frequency {
        case .daily: "DAILY"
        case .weekly: "WEEKLY"
        case .monthly: "MONTHLY"
        case .yearly: "YEARLY"
        }
        var parts = ["FREQ=\(frequency)"]
        if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let days = rule.daysOfWeek.compactMap { day -> String? in
            guard (1...7).contains(day.weekday) else { return nil }
            return (day.weekNumber == 0 ? "" : "\(day.weekNumber)") + codes[day.weekday - 1]
        }
        if !days.isEmpty { parts.append("BYDAY=" + days.joined(separator: ",")) }
        if !rule.daysOfMonth.isEmpty { parts.append("BYMONTHDAY=" + rule.daysOfMonth.map(String.init).joined(separator: ",")) }
        if !rule.monthsOfYear.isEmpty { parts.append("BYMONTH=" + rule.monthsOfYear.map(String.init).joined(separator: ",")) }
        if !rule.setPositions.isEmpty { parts.append("BYSETPOS=" + rule.setPositions.map(String.init).joined(separator: ",")) }
        switch rule.end {
        case .never: break
        case .afterOccurrences(let count): parts.append("COUNT=\(count)")
        case .until(let date):
            if isAllDay {
                parts.append("UNTIL=" + dateString(date, calendar: calendar, separator: ""))
            } else {
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(identifier: "UTC")!
                let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                parts.append(String(format: "UNTIL=%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!))
            }
        }
        return "RRULE:" + parts.joined(separator: ";")
    }

    static func dateString(_ date: Date, calendar: Calendar, separator: String = "-") -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d\(separator)%02d\(separator)%02d", c.year!, c.month!, c.day!)
    }

    /// RFC 3339 in UTC, for query parameters.
    static func timestamp(_ date: Date) -> String {
        dateTimeString(date, zone: TimeZone(identifier: "UTC")!)
    }

    /// Google's RFC 3339 timestamps, with or without fractional seconds.
    static func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// An event start/end: a timestamp, or an all-day date (read as UTC midnight,
    /// close enough for picking a comparison window).
    static func parseWhen(date: String?, dateTime: String?) -> Date? {
        if let dateTime { return parseTimestamp(dateTime) }
        if let date { return parseTimestamp(date + "T00:00:00Z") }
        return nil
    }

    /// RFC 3339 with the zone's offset, e.g. 2026-10-14T09:00:00+02:00.
    static func dateTimeString(_ date: Date, zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
