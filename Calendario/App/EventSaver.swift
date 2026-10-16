import CalendarDomain
import Foundation
import GoogleCalendarAPI

/// Saves an event along the right path: the system calendar for ordinary edits,
/// Google's API when a Meet link or invitee change needs it. Never both, so an
/// event can't end up written twice.
@MainActor
struct EventSaver {
    let store: CalendarStore
    let google: GoogleAccountsStore

    enum SaveError: LocalizedError {
        case unsupported(SaveRoute.Reason)

        var errorDescription: String? {
            switch self {
            case .unsupported(let reason): EventSaver.text(for: reason)
            }
        }
    }

    func route(original: Event?, draft: EventDraft) -> SaveRoute {
        SaveRoute.decide(original: original, draft: draft, remote: google.remoteCalendars(for: store)[draft.calendarID])
    }

    func save(_ draft: EventDraft, original: Event?, scope: EditScope) async throws {
        switch route(original: original, draft: draft) {
        case .system:
            try await store.save(draft, original: original, scope: scope)

        case .remoteInsert(let ref):
            let result = try await google.insert(draft, in: ref)
            store.rememberCalendarForNewEvents(draft.calendarID)
            if let uid = result.iCalUID {
                // Shown now; replaced by the synced copy with the same UID.
                store.addPending(Event(
                    id: "pending:\(result.id)",
                    externalID: uid,
                    calendarID: draft.calendarID,
                    title: draft.title,
                    location: draft.location.isEmpty ? nil : draft.location,
                    notes: draft.notes.isEmpty ? nil : draft.notes,
                    start: draft.start,
                    end: draft.end,
                    isAllDay: draft.isAllDay,
                    timeZone: draft.timeZone,
                    recurrence: draft.recurrence,
                    alarms: draft.alarms,
                    attendees: draft.attendees,
                    conferenceURL: result.meetURL
                ))
            }
            store.showNotice(result.meetURL != nil
                ? String(localized: "Event created with a Google Meet link.")
                : String(localized: "Event created and invitations sent."))

        case .remoteUpdate(let ref):
            guard let original else { return }
            _ = try await google.update(original, with: draft, in: ref)
            await store.requestSync()
            store.showNotice(String(localized: "Saved to Google. The change can take a minute to appear."))

        case .unsupported(let reason):
            throw SaveError.unsupported(reason)
        }
    }

    nonisolated static func text(for reason: SaveRoute.Reason) -> String {
        switch reason {
        case .accountNotConnected:
            String(localized: "Connect this calendar's Google account to add Google Meet or change invitees.")
        case .repeatingEvent:
            String(localized: "Google Meet and invitees can't be changed on repeating events here. Use Google Calendar for that.")
        case .calendarChange:
            String(localized: "Move the event to the other calendar first, then change Google Meet or invitees.")
        }
    }
}
