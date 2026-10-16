import CalendarDomain
import EventKitProvider
import SwiftUI

@main
struct CalendarioApp: App {
    @State private var store: CalendarStore
    @State private var reminders: ReminderStore
    @State private var google: GoogleAccountsStore
    @State private var syncMonitor: SyncMonitor
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        if Demo.isEnabled {
            // Fictional data only: no EventKit, Keychain or Google.
            let demo = DemoProvider()
            let store = CalendarStore(provider: demo)
            let google = GoogleAccountsStore(demoCalendars: DemoProvider.googleCalendars)
            _store = State(initialValue: store)
            _reminders = State(initialValue: ReminderStore(provider: demo))
            _google = State(initialValue: google)
            _syncMonitor = State(initialValue: SyncMonitor(store: store, google: google))
            return
        }
        // One EventKit store serves both events and reminders.
        let eventKit = EventKitCalendarProvider()
        let store = CalendarStore(provider: eventKit)
        let google = GoogleAccountsStore()
        _store = State(initialValue: store)
        _reminders = State(initialValue: ReminderStore(provider: eventKit))
        _google = State(initialValue: google)
        _syncMonitor = State(initialValue: SyncMonitor(store: store, google: google))
    }

    var body: some Scene {
        // Windows restore their view mode (day/week/...) after relaunch.
        WindowGroup(id: AppWindow.main) {
            RootView()
                .calendarThemeFromSettings()
                .environment(store)
                .environment(reminders)
                .environment(google)
                .environment(syncMonitor)
                .onAppear {
                    store.start()
                    reminders.start()
                    google.start()
                    syncMonitor.start()
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            AppCommands(store: store, reminders: reminders, syncMonitor: syncMonitor)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarAgendaView()
                .calendarThemeFromSettings()
                .environment(store)
                .environment(reminders)
        } label: {
            Label("Calendario", systemImage: "calendar")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(google)
                .environment(syncMonitor)
        }
    }
}
