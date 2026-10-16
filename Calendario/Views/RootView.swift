import AppKit
import CalendarDomain
import SwiftUI

/// Shows the calendar once access is granted, otherwise explains what's missing.
struct RootView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(ReminderStore.self) private var reminders

    var body: some View {
        Group {
            switch store.access {
            case nil:
                CheckingAccessView()
            case .fullAccess:
                MainView()
            case .notDetermined:
                AccessRequestView()
            case let status?:
                AccessProblemView(status: status)
            }
        }
        // The user may have changed the permission in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let access = store.access, access != .fullAccess {
                Task { await store.reloadCalendars() }
            }
            if let access = reminders.access, access != .fullAccess {
                Task { await reminders.reload() }
            }
        }
    }
}

/// Shown until the calendar service reports the permission status.
private struct CheckingAccessView: View {
    @State private var isSlow = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Connecting to your calendars…")
            if isSlow {
                Text("The macOS calendar service isn't responding. If this doesn't go away, restart your Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(8))
            isSlow = true
        }
    }
}

private struct AccessRequestView: View {
    @Environment(CalendarStore.self) private var store
    /// Set when the macOS dialog hasn't been answered after a few seconds.
    @State private var dialogMayBeMissing = false

    var body: some View {
        ContentUnavailableView {
            Label("Calendar Access", systemImage: "calendar")
        } description: {
            if store.isRequestingAccess {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to answer the macOS permission dialog…")
                    if dialogMayBeMissing {
                        Text("Don't see it? Check other displays and Spaces. If there's no dialog, quit Calendario, then open it again.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Calendario needs access to your calendars to show events from all your accounts.")
            }
        } actions: {
            if !store.isRequestingAccess {
                Button("Allow Access…") {
                    Task { await store.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
            } else if dialogMayBeMissing {
                Button("Open Privacy Settings", action: openCalendarPrivacySettings)
            }
        }
        .task(id: store.isRequestingAccess) {
            dialogMayBeMissing = false
            guard store.isRequestingAccess else { return }
            try? await Task.sleep(for: .seconds(6))
            dialogMayBeMissing = store.isRequestingAccess
        }
    }
}

private func openCalendarPrivacySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
        NSWorkspace.shared.open(url)
    }
}

private struct AccessProblemView: View {
    @Environment(CalendarStore.self) private var store
    let status: AccessStatus

    private var message: String {
        switch status {
        case .restricted:
            String(localized: "Calendar access is restricted on this Mac, for example by a configuration profile or Screen Time.")
        case .writeOnly:
            String(localized: "Calendario only has permission to add events. To show your events, allow Full Access in System Settings > Privacy & Security > Calendars.")
        default:
            String(localized: "Calendario doesn't have access to your calendars. Turn it on in System Settings > Privacy & Security > Calendars.")
        }
    }

    var body: some View {
        ContentUnavailableView {
            Label("No Calendar Access", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if status != .restricted {
                Button("Open Privacy Settings", action: openCalendarPrivacySettings)
                    .buttonStyle(.borderedProminent)
            }
            Button("Check Again") {
                Task { await store.reloadCalendars() }
            }
        }
    }
}
