import CalendarDomain
import GoogleCalendarAPI
import SwiftUI

/// Where a new event should go, as picked in a view.
enum NewEventRequest {
    /// Somewhere on this day (next half hour today, otherwise 9:00).
    case on(day: Date)
    /// At an exact time, e.g. a double-click in the day grid.
    case at(start: Date)
    case allDay(day: Date)
}

/// Event commands any view can trigger. The window installs the real handlers.
nonisolated struct EventActions: Sendable {
    var create: @MainActor @Sendable (NewEventRequest) -> Void = { _ in }
    var edit: @MainActor @Sendable (Event) -> Void = { _ in }
    var delete: @MainActor @Sendable (Event) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var eventActions = EventActions()
}

/// Reminder commands any view can trigger.
nonisolated struct TaskActions: Sendable {
    /// A new reminder with an optional due date, in a specific list or the default one.
    var create: @MainActor @Sendable (_ due: TaskDue?, _ listID: String?) -> Void = { _, _ in }
    var edit: @MainActor @Sendable (TaskItem) -> Void = { _ in }
    var setCompleted: @MainActor @Sendable (Bool, TaskItem) -> Void = { _, _ in }
    var delete: @MainActor @Sendable (TaskItem) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var taskActions = TaskActions()
}

struct TaskEditorSession: Identifiable {
    let id = UUID()
    let original: TaskItem?
    var draft: TaskDraft
}

/// An open editor: a new event (`original == nil`) or a change to an existing one.
struct EditorSession: Identifiable {
    let id = UUID()
    let original: Event?
    var draft: EventDraft
}

enum ErrorText {
    static func message(for error: any Error) -> String {
        if let google = error as? GoogleAPIError {
            return message(for: google)
        }
        return switch error as? ProviderError {
        case .eventNotFound:
            String(localized: "The event no longer exists. It may have been changed or deleted elsewhere.")
        case .calendarNotFound:
            String(localized: "The selected calendar no longer exists.")
        case .calendarIsReadOnly:
            String(localized: "This calendar is read-only.")
        case nil:
            error.localizedDescription
        }
    }
}

extension ErrorText {
    static func message(for error: GoogleAPIError) -> String {
        switch error {
        case .notConfigured:
            String(localized: "Google isn't set up in this build. Add GOOGLE_CLIENT_ID to Config/Local.xcconfig (see SETUP.md).")
        case .userCancelled:
            String(localized: "Sign-in was cancelled.")
        case .stateMismatch:
            String(localized: "The sign-in response didn't match the request. Please try again.")
        case .authorizationFailed(let reason):
            String(localized: "Google sign-in failed: \(reason)")
        case .missingScopes:
            String(localized: "Calendario needs permission to manage your Google calendar events. Connect again and leave the calendar boxes checked.")
        case .needsReauthentication(let email):
            String(localized: "The Google sign-in for \(email) expired. Reconnect it in Settings > Accounts.")
        case .accountNotConnected(let email):
            String(localized: "The Google account \(email) isn't connected.")
        case .http(let status, let message):
            String(localized: "Google returned an error (\(status)): \(message)")
        case .invalidResponse:
            String(localized: "Google sent an unexpected response.")
        case .eventNotFound:
            String(localized: "The event wasn't found on Google. It may not have synced yet; try again in a minute.")
        }
    }
}
