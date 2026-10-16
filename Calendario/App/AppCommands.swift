import CalendarDomain
import SwiftUI

extension FocusedValues {
    /// The frontmost calendar window, for menu commands.
    @Entry var windowState: WindowState?
}

/// Menu bar commands. They act on the frontmost window and are disabled when there
/// is none (e.g. only Settings is open).
struct AppCommands: Commands {
    let store: CalendarStore
    let reminders: ReminderStore
    let syncMonitor: SyncMonitor
    @FocusedValue(\.windowState) private var state
    @Environment(\.openWindow) private var openWindow
    @AppStorage(GridZoom.key) private var zoom = 1.0

    private var canNavigate: Bool { state.map { !$0.hasSheet } ?? false }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Event") {
                guard let state else { return }
                state.startNewEvent(.on(day: state.dayForNewEvent), store: store)
            }
            .keyboardShortcut("n")
            .disabled(!canNavigate)

            Button("New Reminder") {
                guard let state else { return }
                let due: TaskDue? = state.showsReminders ? nil : .day(state.dayForNewEvent)
                state.startNewTask(due: due, reminders: reminders)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!canNavigate || reminders.access != .fullAccess)

            Divider()

            Button("New Window") { openWindow(id: AppWindow.main) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.label) { state?.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(!canNavigate)
            }

            Divider()

            Button("Previous") { state?.goBack() }
                .keyboardShortcut(.leftArrow)
                .disabled(!canNavigate || state?.showsReminders == true)
            Button("Go to Today") { state?.goToToday() }
                .keyboardShortcut("t")
                .disabled(!canNavigate)
            Button("Next") { state?.goForward() }
                .keyboardShortcut(.rightArrow)
                .disabled(!canNavigate || state?.showsReminders == true)
            Button("Go to Date…") { state?.isPickingDate = true }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!canNavigate)

            Divider()

            Button("Zoom In") { zoom = GridZoom.step(zoom, by: 1) }
                .keyboardShortcut("+")
                .disabled(zoom >= GridZoom.levels.last!)
            Button("Zoom Out") { zoom = GridZoom.step(zoom, by: -1) }
                .keyboardShortcut("-")
                .disabled(zoom <= GridZoom.levels.first!)
            Button("Actual Size") { zoom = 1 }
                .keyboardShortcut("0")
                .disabled(zoom == 1)

            Divider()

            Button("Refresh") {
                Task {
                    await store.requestSync()
                    await store.reloadCalendars()
                    await reminders.reload()
                    await syncMonitor.check()
                    // macOS gives no feedback on sync, and can't fix a broken sign-in.
                    store.showNotice(String(localized: "Asked macOS to sync. If an account stays out of date, sign in to it again in System Settings > Internet Accounts."))
                }
            }
            .keyboardShortcut("r")

            Divider()
        }
    }
}

enum AppWindow {
    static let main = "main"
}

/// What a window shows: one of the calendar periods, or the Reminders list.
enum ViewMode: String, Hashable, CaseIterable {
    case day, days, month, agenda, reminders

    var label: String {
        switch self {
        case .day: CalendarPeriod.day.label
        case .days: CalendarPeriod.days.label
        case .month: CalendarPeriod.month.label
        case .agenda: CalendarPeriod.agenda.label
        case .reminders: String(localized: "Reminders")
        }
    }

    var period: CalendarPeriod? {
        switch self {
        case .day: .day
        case .days: .days
        case .month: .month
        case .agenda: .agenda
        case .reminders: nil
        }
    }

    init(_ period: CalendarPeriod) {
        self = switch period {
        case .day: .day
        case .days: .days
        case .month: .month
        case .agenda: .agenda
        }
    }
}

/// Vertical zoom of the day/week time grid, shared by all windows.
enum GridZoom {
    static let key = "gridZoom"
    static let baseHourHeight: CGFloat = 48
    static let levels: [Double] = [0.5, 0.67, 0.8, 1, 1.25, 1.5, 2, 2.5, 3]

    static func clamped(_ zoom: Double) -> Double {
        min(max(zoom, levels.first!), levels.last!)
    }

    /// The next level up (`by: 1`) or down (`by: -1`) from the current one.
    static func step(_ zoom: Double, by direction: Int) -> Double {
        let current = levels.enumerated().min { abs($0.element - zoom) < abs($1.element - zoom) }?.offset ?? 3
        return levels[min(max(current + direction, 0), levels.count - 1)]
    }
}
