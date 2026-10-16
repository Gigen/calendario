import Foundation

// Provider-independent types. Nothing here may import EventKit, SwiftUI or AppKit,
// so the same model can back a future Windows client.

/// The kind of account a calendar belongs to.
public enum SourceKind: String, Sendable, Codable, CaseIterable {
    case iCloud, google, exchange, calDAV, local, subscribed, birthdays, other

    /// Sidebar ordering: real accounts first, read-only feeds last.
    public var sortRank: Int {
        switch self {
        case .iCloud: 0
        case .google: 1
        case .exchange: 2
        case .calDAV: 3
        case .local: 4
        case .other: 5
        case .subscribed: 6
        case .birthdays: 7
        }
    }
}

/// An account (EventKit calls it a source) that owns calendars.
public struct CalendarSource: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var kind: SourceKind
    /// The account's email address, when it can be determined.
    public var accountEmail: String?

    public init(id: String, title: String, kind: SourceKind, accountEmail: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.accountEmail = accountEmail
    }
}

/// An sRGB color with components in 0...1.
public struct RGBAColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let gray = RGBAColor(red: 0.55, green: 0.55, blue: 0.58)
}

public enum CalendarEntityType: Sendable, Hashable {
    case events
    case tasks
}

/// A calendar (for events) or a list (for tasks/reminders).
/// Named `CalendarInfo` so it doesn't shadow `Foundation.Calendar`.
public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var color: RGBAColor
    public var sourceID: String
    public var entityType: CalendarEntityType
    public var allowsContentModifications: Bool
    public var isSubscribed: Bool

    public init(
        id: String,
        title: String,
        color: RGBAColor,
        sourceID: String,
        entityType: CalendarEntityType = .events,
        allowsContentModifications: Bool = true,
        isSubscribed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.sourceID = sourceID
        self.entityType = entityType
        self.allowsContentModifications = allowsContentModifications
        self.isSubscribed = isSubscribed
    }
}

/// Whether the app may read the user's calendar data.
public enum AccessStatus: Sendable, Hashable {
    case notDetermined
    case denied
    case restricted
    /// The user granted add-only access. Not enough to show events.
    case writeOnly
    case fullAccess
}

public enum Alarm: Hashable, Sendable {
    /// Seconds relative to the start. Negative means before.
    case relative(TimeInterval)
    case absolute(Date)
}

public struct Attendee: Hashable, Sendable {
    public enum Status: Sendable, Hashable {
        case unknown, pending, accepted, declined, tentative, delegated, completed, inProcess
    }

    public enum Role: Sendable, Hashable {
        case unknown, required, optional, chair, nonParticipant
    }

    public var name: String?
    public var email: String?
    public var status: Status
    public var role: Role
    public var isCurrentUser: Bool

    public init(name: String?, email: String?, status: Status = .unknown, role: Role = .required, isCurrentUser: Bool = false) {
        self.name = name
        self.email = email
        self.status = status
        self.role = role
        self.isCurrentUser = isCurrentUser
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return email ?? "Unknown"
    }
}

/// One occurrence of an event. Recurring events produce one `Event` per occurrence.
///
/// Conventions:
/// - `end` is exclusive. For all-day events `start` and `end` are midnights in the
///   current calendar, so a single all-day event on Oct 5 is Oct 5 00:00 ..< Oct 6 00:00.
/// - `timeZone == nil` means floating time (always shown at the same wall-clock time).
public struct Event: Identifiable, Hashable, Sendable {
    /// Unique per occurrence (series identifier + occurrence date).
    public var id: String
    /// Identifies the event (or the whole series) in its provider. `nil` until saved.
    public var seriesID: String?
    /// The iCalendar UID, shared across providers and devices. Used for de-duplication.
    public var externalID: String?
    public var calendarID: String

    public var title: String
    public var location: String?
    public var notes: String?
    public var url: URL?

    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZone: TimeZone?

    /// The original start of this occurrence in its series.
    public var occurrenceDate: Date?
    public var recurrence: RecurrenceRule?
    /// This occurrence was changed independently of its series.
    public var isDetached: Bool

    public var alarms: [Alarm]
    public var attendees: [Attendee]
    public var organizer: Attendee?
    public var status: Status
    /// A video meeting link (Google Meet, Zoom, ...) found in the event.
    public var conferenceURL: URL?

    public enum Status: Sendable, Hashable {
        case none, confirmed, tentative, canceled
    }

    public init(
        id: String,
        seriesID: String? = nil,
        externalID: String? = nil,
        calendarID: String,
        title: String,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        timeZone: TimeZone? = nil,
        occurrenceDate: Date? = nil,
        recurrence: RecurrenceRule? = nil,
        isDetached: Bool = false,
        alarms: [Alarm] = [],
        attendees: [Attendee] = [],
        organizer: Attendee? = nil,
        status: Status = .none,
        conferenceURL: URL? = nil
    ) {
        self.id = id
        self.seriesID = seriesID
        self.externalID = externalID
        self.calendarID = calendarID
        self.title = title
        self.location = location
        self.notes = notes
        self.url = url
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.occurrenceDate = occurrenceDate
        self.recurrence = recurrence
        self.isDetached = isDetached
        self.alarms = alarms
        self.attendees = attendees
        self.organizer = organizer
        self.status = status
        self.conferenceURL = conferenceURL
    }

    public var isRecurring: Bool { recurrence != nil || isDetached }

    /// Identifies the whole series. Occurrences the organizer changed individually
    /// get their own EventKit identifier, but all share the iCalendar UID.
    public var seriesKey: String? { externalID ?? seriesID }

    /// The user's own entry, if they're invited (and not the organizer).
    public var invitationForCurrentUser: Attendee? {
        participants.first { $0.attendee.isCurrentUser && !$0.isOrganizer }?.attendee
    }

    /// Everyone on the event, organizer first. The organizer is matched by email (or
    /// the "chair" role), and added if the invitee list doesn't include them.
    public var participants: [(attendee: Attendee, isOrganizer: Bool)] {
        let organizerEmail = organizer?.email?.lowercased()
        func isOrganizer(_ attendee: Attendee) -> Bool {
            if let organizerEmail, let email = attendee.email?.lowercased() { return email == organizerEmail }
            return attendee.role == .chair
        }
        var list = attendees.map { (attendee: $0, isOrganizer: isOrganizer($0)) }
        if let organizer, !list.contains(where: \.isOrganizer), !attendees.isEmpty {
            list.append((attendee: organizer, isOrganizer: true))
        }
        return list.filter(\.isOrganizer) + list.filter { !$0.isOrganizer }
    }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}
