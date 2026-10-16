import AppKit
import CalendarDomain
import SwiftUI

/// One window: calendars and reminder lists in the sidebar, and either the selected
/// calendar period or the Reminders list on the right.
struct MainView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(ReminderStore.self) private var reminders
    @Environment(GoogleAccountsStore.self) private var google
    @Environment(SyncMonitor.self) private var syncMonitor
    @State private var state = WindowState()

    // Restored per window by the system. The date isn't restored: windows open on today.
    @SceneStorage("period") private var storedPeriod = CalendarPeriod.days.rawValue
    @AppStorage("dayCount") private var dayCount = CalendarPeriod.defaultDayCount
    @SceneStorage("showsReminders") private var storedShowsReminders = false
    @AppStorage(GridZoom.key) private var zoom = 1.0
    @Environment(\.calendarTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings

    private struct LoadKey: Hashable {
        var interval: DateInterval
        var calendarRevision: Int
        var reminderRevision: Int
    }

    var body: some View {
        @Bindable var state = state
        splitView
        .navigationTitle(state.showsReminders ? String(localized: "Reminders") : state.title)
        .toolbar { toolbar }
        .task(id: LoadKey(interval: state.visibleInterval, calendarRevision: store.revision, reminderRevision: reminders.revision)) {
            await state.load(from: store, reminders: reminders)
        }
        .sheet(item: $state.editor) { session in
            EventEditorView(
                original: session.original,
                draft: session.draft,
                onClose: { state.editor = nil },
                onDelete: { event in
                    state.editor = nil
                    state.pendingDelete = event
                }
            )
        }
        .sheet(item: $state.taskEditor) { session in
            TaskEditorView(
                original: session.original,
                draft: session.draft,
                onClose: { state.taskEditor = nil },
                onDelete: { task in
                    state.taskEditor = nil
                    state.pendingTaskDelete = task
                }
            )
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } }),
            presenting: state.pendingDelete
        ) { event in
            if event.isRecurring {
                Button("Delete This Event Only", role: .destructive) { delete(event, .thisEvent) }
                Button("Delete All Future Events", role: .destructive) { delete(event, .futureEvents) }
            } else {
                Button("Delete Event", role: .destructive) { delete(event, .thisEvent) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { event in
            if event.isRecurring {
                Text("This is a repeating event.")
            } else {
                Text("This can't be undone.")
            }
        }
        .confirmationDialog(
            "Delete this reminder?",
            isPresented: Binding(get: { state.pendingTaskDelete != nil }, set: { if !$0 { state.pendingTaskDelete = nil } }),
            presenting: state.pendingTaskDelete
        ) { task in
            Button("Delete Reminder", role: .destructive) {
                Task { await state.delete(task, reminders: reminders) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { task in
            Text(task.isRecurring ? "This deletes the reminder and all its repeats." : "This can't be undone.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { state.actionError != nil }, set: { if !$0 { state.actionError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(state.actionError ?? "")
        }
        .sheet(isPresented: $state.isPickingDate) {
            GoToDateView(initial: state.date) { day in
                state.date = day
                if state.showsReminders { state.showsReminders = false }
            }
        }
        .focusedSceneValue(\.windowState, state)
        .onAppear {
            // Windows saved with the old Week view open in Days.
            state.period = CalendarPeriod(rawValue: storedPeriod) ?? .days
            state.dayCount = dayCount
            state.showsReminders = storedShowsReminders
            if let mode = Demo.initialMode { state.mode = mode }
        }
        .onChange(of: state.period) { storedPeriod = state.period.rawValue }
        .onChange(of: dayCount) { state.dayCount = dayCount }
        .task { await Demo.stage(state: state) }
        .onReceive(NotificationCenter.default.publisher(for: .demoOpenSettings)) { _ in openSettings() }
        .onChange(of: state.showsReminders) { storedShowsReminders = state.showsReminders }
    }

    /// The sidebar and the calendar. Screenshot runs lay them out as plain views:
    /// macOS 26's floating glass sidebar can't be rendered into an image.
    @ViewBuilder private var splitView: some View {
        if Demo.isCapturing {
            HStack(spacing: 0) {
                SidebarView().frame(width: 230)
                Divider()
                detail
            }
        } else {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            } detail: {
                detail
            }
        }
    }

    @ViewBuilder private var detail: some View {
        content
            .frame(minWidth: 500, minHeight: 400)
            // A chosen background color, with text colors that stay readable on it.
            .scrollContentBackground(theme.canvas == nil ? .automatic : .hidden)
            .background { if let canvas = theme.canvas { Color(canvas).ignoresSafeArea() } }
            .environment(\.colorScheme, theme.canvasColorScheme ?? colorScheme)
            .overlay(alignment: .bottom) { errorBanner }
            .environment(\.eventActions, eventActions)
            .environment(\.taskActions, taskActions)
            .background {
                // On US keyboards "+" is Shift-=, so also accept ⌘= for Zoom In
                // (the menu item shows ⌘+).
                Button("Zoom In") { zoom = GridZoom.step(zoom, by: 1) }
            .keyboardShortcut("=")
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .disabled(state.hasSheet)
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var state = state
        ToolbarItemGroup(placement: .navigation) {
            Button(action: state.goBack) {
                Label("Previous", systemImage: "chevron.left")
            }
            .help("Previous (⌘←)")
            .disabled(state.showsReminders)

            Button("Today", action: state.goToToday)
                .help("Go to Today (⌘T)")
                .disabled(state.showsReminders)

            Button(action: state.goForward) {
                Label("Next", systemImage: "chevron.right")
            }
            .help("Next (⌘→)")
            .disabled(state.showsReminders)
        }
        .hidingGlassInScreenshots()

        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Picker("View", selection: $state.mode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode == .days ? String(localized: "\(dayCount) Days") : mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                // How many days the Days view shows; only while it's on screen.
                if state.mode == .days {
                    Picker("Number of Days", selection: $dayCount) {
                        ForEach(Array(CalendarPeriod.dayCountRange), id: \.self) { count in
                            Text("\(count) days").tag(count)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Number of days to show")
                }
            }
        }
        .hidingGlassInScreenshots()

        ToolbarItemGroup(placement: .primaryAction) {
            InboxButton { event in
                state.date = state.math.startOfDay(event.start)
                state.mode = .day // also leaves the Reminders list
            }

            Button {
                newReminder()
            } label: {
                Label("New Reminder", systemImage: "checklist.unchecked")
            }
            .help("New Reminder (⌥⌘N)")
            .disabled(reminders.access != .fullAccess)

            Button {
                state.startNewEvent(.on(day: state.dayForNewEvent), store: store)
            } label: {
                Label("New Event", systemImage: "plus")
            }
            .help("New Event (⌘N)")
        }
        .hidingGlassInScreenshots()
    }

    /// From a calendar view the new reminder is due on the shown day; from the
    /// Reminders list it has no due date.
    private func newReminder() {
        let due: TaskDue? = state.showsReminders ? nil : .day(state.dayForNewEvent)
        state.startNewTask(due: due, reminders: reminders)
    }

    // MARK: Actions

    private var eventActions: EventActions {
        EventActions(
            create: { [state, store] request in state.startNewEvent(request, store: store) },
            edit: { [state] event in state.startEditing(event) },
            delete: { [state] event in state.pendingDelete = event }
        )
    }

    private var taskActions: TaskActions {
        TaskActions(
            create: { [state, reminders] due, listID in state.startNewTask(due: due, listID: listID, reminders: reminders) },
            edit: { [state, reminders] task in
                if reminders.canModify(task) { state.startEditing(task) }
            },
            setCompleted: { [state, reminders] completed, task in
                Task { await state.setCompleted(completed, task: task, reminders: reminders) }
            },
            delete: { [state] task in state.pendingTaskDelete = task }
        )
    }

    private var deleteTitle: String {
        let title = state.pendingDelete?.title ?? ""
        return title.isEmpty ? String(localized: "Delete this event?") : String(localized: "Delete “\(title)”?")
    }

    private func delete(_ event: Event, _ scope: EditScope) {
        Task { await state.delete(event, scope: scope, store: store) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if state.showsReminders {
            RemindersView()
        } else {
            switch state.period {
            case .day:
                TimeGridView(days: [state.math.startOfDay(state.date)], events: state.events, tasks: state.tasks, math: state.math) { day in
                    state.show(day, as: .day)
                }
            case .days:
                TimeGridView(days: state.math.days(in: state.visibleInterval), events: state.events, tasks: state.tasks, math: state.math) { day in
                    state.show(day, as: .day)
                }
            case .month:
                MonthView(month: state.date, events: state.events, tasks: state.tasks, math: state.math) { day in
                    state.show(day, as: .day)
                }
            case .agenda:
                AgendaView(interval: state.visibleInterval, events: state.events, tasks: state.tasks, math: state.math)
            }
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let notice = store.notice {
            Label(notice, systemImage: "checkmark.circle")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding()
        } else if let expired = google.accounts.first(where: \.needsReauthentication) {
            HStack {
                Label("The Google sign-in for \(expired.email) expired.", systemImage: "exclamationmark.triangle")
                Button("Reconnect…") { Task { await google.connect(loginHint: expired.email) } }
                    .disabled(google.isConnecting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding()
        } else if let behind = syncMonitor.accountsBehind.first {
            HStack(spacing: 10) {
                Label(
                    "macOS isn't syncing \(behind.email): \(behind.missing) recent Google changes are missing. Sign in to it again in Internet Accounts.",
                    systemImage: "arrow.triangle.2.circlepath.circle"
                )
                Button("Open Internet Accounts") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button {
                    syncMonitor.dismiss(behind.email)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding()
        } else if let message = state.loadError ?? store.lastError ?? reminders.lastError {
            Label(message, systemImage: "exclamationmark.triangle")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding()
        }
    }
}

/// Go to Date… (⇧⌘T)
private struct GoToDateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date
    var onGo: (Date) -> Void

    init(initial: Date, onGo: @escaping (Date) -> Void) {
        _day = State(initialValue: initial)
        self.onGo = onGo
    }

    var body: some View {
        VStack(spacing: 12) {
            DatePicker("Date", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Today") { day = Date() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") {
                    onGo(day)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
