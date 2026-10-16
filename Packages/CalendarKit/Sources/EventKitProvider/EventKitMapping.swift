#if canImport(EventKit)
import CalendarDomain
import CoreGraphics
import EventKit
import Foundation

/// Converts EventKit objects into domain types. The only place that knows both.
enum EventKitMapping {
    static func source(from source: EKSource) -> CalendarSource {
        let kind: SourceKind = switch source.sourceType {
        case .local: .local
        case .exchange: .exchange
        case .calDAV: Normalization.calDAVSourceKind(title: source.title)
        case .mobileMe: .iCloud
        case .subscribed: .subscribed
        case .birthdays: .birthdays
        @unknown default: .other
        }
        let email = Normalization.looksLikeEmail(source.title) ? source.title.lowercased() : nil
        return CalendarSource(id: source.sourceIdentifier, title: source.title, kind: kind, accountEmail: email)
    }

    static func calendar(from calendar: EKCalendar, entityType: CalendarEntityType) -> CalendarInfo {
        CalendarInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            color: color(from: calendar.cgColor),
            sourceID: calendar.source?.sourceIdentifier ?? "",
            entityType: entityType,
            allowsContentModifications: calendar.allowsContentModifications,
            isSubscribed: calendar.isSubscribed
        )
    }

    static func color(from cgColor: CGColor?) -> RGBAColor {
        guard
            let cgColor,
            let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
            let c = converted.components, c.count >= 3
        else { return .gray }
        return RGBAColor(red: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
    }

    static func event(from event: EKEvent, calendar: Calendar) -> Event {
        let start: Date = event.startDate
        let rawEnd: Date = event.endDate ?? start
        let end = event.isAllDay
            ? Normalization.allDayExclusiveEnd(start: start, end: rawEnd, calendar: calendar)
            : max(rawEnd, start)
        let seriesID: String? = event.eventIdentifier
        let occurrence: Date? = event.occurrenceDate
        let occurrenceKey = (occurrence ?? start).timeIntervalSinceReferenceDate

        return Event(
            id: "\(seriesID ?? event.calendarItemIdentifier)@\(occurrenceKey)",
            seriesID: seriesID,
            externalID: event.calendarItemExternalIdentifier,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            title: event.title ?? "",
            location: event.location.nonEmpty,
            notes: event.notes.nonEmpty,
            url: event.url,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            timeZone: event.timeZone,
            occurrenceDate: occurrence,
            recurrence: event.recurrenceRules?.first.map(recurrence(from:)),
            isDetached: event.isDetached,
            alarms: (event.alarms ?? []).map(alarm(from:)),
            attendees: (event.attendees ?? []).map(attendee(from:)),
            organizer: event.organizer.map(attendee(from:)),
            status: status(from: event.status),
            // Google puts the Meet link into the synced event's notes.
            conferenceURL: ConferenceLink.find(in: [event.url?.absoluteString, event.location, event.notes])
        )
    }

    static func recurrence(from rule: EKRecurrenceRule) -> RecurrenceRule {
        let frequency: RecurrenceRule.Frequency = switch rule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        @unknown default: .daily
        }
        let end: RecurrenceRule.End
        if let recurrenceEnd = rule.recurrenceEnd {
            if let date = recurrenceEnd.endDate {
                end = .until(date)
            } else {
                end = .afterOccurrences(recurrenceEnd.occurrenceCount)
            }
        } else {
            end = .never
        }
        return RecurrenceRule(
            frequency: frequency,
            interval: rule.interval,
            end: end,
            daysOfWeek: (rule.daysOfTheWeek ?? []).map {
                .init(weekday: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber)
            },
            daysOfMonth: (rule.daysOfTheMonth ?? []).map(\.intValue),
            monthsOfYear: (rule.monthsOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue)
        )
    }

    static func alarm(from alarm: EKAlarm) -> Alarm {
        if let date = alarm.absoluteDate { return .absolute(date) }
        return .relative(alarm.relativeOffset)
    }

    static func attendee(from participant: EKParticipant) -> Attendee {
        let status: Attendee.Status = switch participant.participantStatus {
        case .pending: .pending
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .delegated: .delegated
        case .completed: .completed
        case .inProcess: .inProcess
        default: .unknown
        }
        let role: Attendee.Role = switch participant.participantRole {
        case .required: .required
        case .optional: .optional
        case .chair: .chair
        case .nonParticipant: .nonParticipant
        default: .unknown
        }
        return Attendee(
            name: participant.name,
            email: Normalization.email(fromMailto: participant.url.absoluteString),
            status: status,
            role: role,
            isCurrentUser: participant.isCurrentUser
        )
    }

    static func status(from status: EKEventStatus) -> Event.Status {
        switch status {
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .canceled
        default: .none
        }
    }
}

// MARK: - Domain -> EventKit

extension EventKitMapping {
    static func span(_ scope: EditScope) -> EKSpan {
        switch scope {
        case .thisEvent: .thisEvent
        case .futureEvents: .futureEvents
        }
    }

    /// Copies the draft's fields onto `event`. The repeat rule is only written when it
    /// changed, so saving one occurrence doesn't rewrite the series' rule.
    static func apply(_ draft: EventDraft, to event: EKEvent, calendar: EKCalendar, recurrenceChanged: Bool) {
        event.calendar = calendar
        event.title = draft.title
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.url = draft.parsedURL
        event.isAllDay = draft.isAllDay
        event.timeZone = draft.isAllDay ? nil : draft.timeZone
        event.startDate = draft.start
        event.endDate = draft.isAllDay ? Normalization.eventKitAllDayEnd(exclusiveEnd: draft.end) : draft.end
        event.alarms = draft.alarms.map(alarm(from:))
        if recurrenceChanged {
            event.recurrenceRules = draft.recurrence.map { [recurrenceRule(from: $0)] }
        }
    }

    static func alarm(from alarm: Alarm) -> EKAlarm {
        switch alarm {
        case .relative(let offset): EKAlarm(relativeOffset: offset)
        case .absolute(let date): EKAlarm(absoluteDate: date)
        }
    }

    static func recurrenceRule(from rule: RecurrenceRule) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch rule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        let end: EKRecurrenceEnd? = switch rule.end {
        case .never: nil
        case .afterOccurrences(let count): EKRecurrenceEnd(occurrenceCount: count)
        case .until(let date): EKRecurrenceEnd(end: date)
        }
        let days = rule.daysOfWeek.compactMap { day -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: day.weekday) else { return nil }
            return day.weekNumber == 0
                ? EKRecurrenceDayOfWeek(weekday)
                : EKRecurrenceDayOfWeek(weekday, weekNumber: day.weekNumber)
        }
        func numbers(_ values: [Int]) -> [NSNumber]? {
            values.isEmpty ? nil : values.map { NSNumber(value: $0) }
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: rule.interval,
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: numbers(rule.daysOfMonth),
            monthsOfTheYear: numbers(rule.monthsOfYear),
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: numbers(rule.setPositions),
            end: end
        )
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
#endif
