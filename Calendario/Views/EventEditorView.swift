import AppKit
import CalendarDomain
import GoogleCalendarAPI
import SwiftUI

/// Create or edit an event. Shown as a sheet on the window.
struct EventEditorView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(GoogleAccountsStore.self) private var google
    let original: Event?
    @State var draft: EventDraft
    var onClose: () -> Void
    var onDelete: (Event) -> Void

    @State private var scopeChoices: [EditScope] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let math = CalendarMath()

    private var isNew: Bool { original == nil }
    private var issues: [EventDraft.Issue] { draft.issues() }
    private var saver: EventSaver { EventSaver(store: store, google: google) }
    /// Why the current changes can't be saved, if they need Google and can't use it.
    private var routeProblem: String? {
        if case .unsupported(let reason) = saver.route(original: original, draft: draft) {
            return EventSaver.text(for: reason)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text("New Event"))
                        .font(.title3)
                    TextField("Location", text: $draft.location, prompt: Text("Add location"))
                }
                timeSection
                Section {
                    RecurrenceEditor(draft: $draft, math: math)
                }
                Section("Alerts") {
                    AlarmListEditor(alarms: $draft.alarms, isAllDay: draft.isAllDay)
                }
                Section {
                    CalendarPicker(selection: $draft.calendarID)
                }
                googleSection
                Section {
                    TextField("URL", text: $draft.url, prompt: Text("Add URL"))
                    TextField("Notes", text: $draft.notes, prompt: Text("Add notes"), axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 520, height: 680)
        .confirmationDialog(
            "This is a repeating event.",
            isPresented: Binding(get: { !scopeChoices.isEmpty }, set: { if !$0 { scopeChoices = [] } })
        ) {
            if scopeChoices.contains(.thisEvent) {
                Button("Save for This Event Only") { save(scope: .thisEvent) }
            }
            Button("Save for Future Events") { save(scope: .futureEvents) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if scopeChoices == [.futureEvents] {
                Text("Changing the calendar or the repeat rule applies to this and all future events.")
            } else {
                Text("Do you want to change only this event, or this and all future events?")
            }
        }
        .alert("Couldn't Save Event", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sections

    @ViewBuilder private var timeSection: some View {
        let zone = draft.timeZone ?? math.calendar.timeZone
        Section {
            Toggle("All-day", isOn: Binding(get: { draft.isAllDay }, set: { draft.setAllDay($0, math: math) }))
            if draft.isAllDay {
                DatePicker("Starts", selection: Binding(get: { draft.start }, set: { draft.setStart($0, math: math) }), displayedComponents: .date)
                DatePicker("Ends", selection: Binding(get: { draft.allDayLastDay(math: math) }, set: { draft.setAllDayLastDay($0, math: math) }), displayedComponents: .date)
            } else {
                // Pickers show wall-clock time in the event's own zone.
                Group {
                    DatePicker("Starts", selection: Binding(get: { draft.start }, set: { draft.setStart($0, math: math) }))
                    DatePicker("Ends", selection: Binding(get: { draft.end }, set: { draft.setEnd($0, math: math) }))
                }
                .environment(\.timeZone, zone)
                TimeZoneField(timeZone: Binding(get: { draft.timeZone }, set: { draft.setTimeZone($0, math: math) }))
                if draft.timeZone != nil, zone.identifier != TimeZone.current.identifier {
                    Text("Your time: \(EventText.timeRange(start: draft.start, end: draft.end))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Meet and invitees. Editable for calendars of a connected Google account;
    /// otherwise invitees are read-only (EventKit can't change them).
    @ViewBuilder private var googleSection: some View {
        let source = store.calendar(id: draft.calendarID).flatMap { calendar in store.sources.first { $0.id == calendar.sourceID } }
        let remote = google.remoteCalendars(for: store)[draft.calendarID]
        let looksLikeGoogle = remote != nil || (source.map(CalendarMatcher.mightBeGoogle) ?? false)
        let canChange = remote != nil && original?.isRecurring != true

        if (looksLikeGoogle && google.isConfigured) || !draft.attendees.isEmpty || draft.conferenceURL != nil {
            Section {
                if let link = draft.conferenceURL {
                    LabeledContent("Google Meet") {
                        HStack {
                            Link("Join", destination: link)
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                            }
                        }
                    }
                } else if canChange {
                    Toggle("Add Google Meet", isOn: $draft.addConference)
                }

                if canChange, let remote {
                    InviteeEditor(draft: $draft, account: google.account(email: remote.accountEmail))
                } else {
                    ForEach(Array(draft.attendees.enumerated()), id: \.offset) { _, attendee in
                        LabeledContent(attendee.displayName) {
                            Text(EventText.attendeeStatus(attendee.status)).foregroundStyle(.secondary)
                        }
                    }
                }

                if remote == nil, looksLikeGoogle, google.isConfigured {
                    connectRow(for: source)
                }
            } header: {
                Text(looksLikeGoogle ? "Google Meet & Invitees" : "Invitees")
            } footer: {
                Group {
                    if let routeProblem {
                        Text(routeProblem).foregroundStyle(.red)
                    } else if !looksLikeGoogle {
                        Text("macOS doesn't let apps change the invitees of calendar events.")
                    } else if remote != nil, original?.isRecurring == true {
                        Text("Google Meet and invitees of repeating events can be changed in Google Calendar.")
                    } else if canChange, !draft.attendees.isEmpty {
                        Text("Google emails the invitations when you save.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Offers to connect (or reconnect) the Google account this calendar belongs to.
    @ViewBuilder private func connectRow(for source: CalendarSource?) -> some View {
        let account = google.account(email: source?.accountEmail)
        if account?.needsReauthentication == true {
            LabeledContent("The Google sign-in expired.") {
                Button("Reconnect…") { Task { await google.connect(loginHint: account?.email) } }
            }
        } else if account != nil {
            Text("This calendar couldn't be matched to your Google account, for example because two calendars share its name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            LabeledContent("Connect this Google account to add Meet links and invitees.") {
                Button("Connect Google Account…") { Task { await google.connect(loginHint: source?.accountEmail) } }
                    .disabled(google.isConnecting)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let original, store.canModify(original) {
                Button("Delete Event…", role: .destructive) { onDelete(original) }
            }
            Spacer()
            if let issue = issues.first {
                Text(Self.text(for: issue))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Cancel", role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Add Event" : "Save") { requestSave() }
                .keyboardShortcut(.defaultAction)
                .disabled(!issues.isEmpty || routeProblem != nil || isSaving)
        }
        .padding(12)
    }

    // MARK: Saving

    private func requestSave() {
        let choices = EditScope.saveChoices(original: original, draft: draft)
        if original?.isRecurring == true {
            scopeChoices = choices
        } else {
            save(scope: choices.first ?? .thisEvent)
        }
    }

    private func save(scope: EditScope) {
        var toSave = draft
        if toSave.title.trimmingCharacters(in: .whitespaces).isEmpty {
            toSave.title = String(localized: "New Event")
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await saver.save(toSave, original: original, scope: scope)
                onClose()
            } catch {
                errorMessage = ErrorText.message(for: error)
            }
        }
    }

    private static func text(for issue: EventDraft.Issue) -> String {
        switch issue {
        case .endBeforeStart: String(localized: "The event ends before it starts.")
        case .repeatEndsBeforeStart: String(localized: "The repeat ends before the event starts.")
        case .invalidOccurrenceCount: String(localized: "Repeat at least once.")
        case .invalidURL: String(localized: "The URL isn't valid. Include https://.")
        }
    }
}

// MARK: - Calendar picker

/// Writable calendars grouped by account.
struct CalendarPicker: View {
    @Environment(CalendarStore.self) private var store
    @Binding var selection: String

    var body: some View {
        Picker("Calendar", selection: $selection) {
            ForEach(store.sources) { source in
                let calendars = store.calendars(in: source).filter(\.allowsContentModifications)
                if !calendars.isEmpty {
                    Section(source.title) {
                        ForEach(calendars) { calendar in
                            Label {
                                Text(calendar.title)
                            } icon: {
                                CalendarPalette.swatch(calendar.color) // menus ignore tint; use a real image
                            }
                            .tag(calendar.id)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Time zone

/// Shows the event's time zone; click to search all zones.
struct TimeZoneField: View {
    @Binding var timeZone: TimeZone?
    @State private var picking = false

    var body: some View {
        LabeledContent("Time Zone") {
            Button(Self.name(timeZone)) { picking = true }
                .popover(isPresented: $picking, arrowEdge: .trailing) {
                    TimeZoneList(selection: $timeZone) { picking = false }
                }
        }
    }

    static func name(_ zone: TimeZone?) -> String {
        guard let zone else { return String(localized: "Floating") }
        let city = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
        let offset = zone.abbreviation() ?? ""
        return "\(city) (\(offset))"
    }
}

private struct TimeZoneList: View {
    @Binding var selection: TimeZone?
    var onDone: () -> Void
    @State private var query = ""

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query.replacingOccurrences(of: " ", with: "_")) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                if query.isEmpty {
                    Button("Floating (same clock time everywhere)") { pick(nil) }
                    Button("Current: \(TimeZoneField.name(.current))") { pick(.current) }
                }
                ForEach(matches, id: \.self) { identifier in
                    Button(identifier.replacingOccurrences(of: "_", with: " ")) { pick(TimeZone(identifier: identifier)) }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300, height: 360)
    }

    private func pick(_ zone: TimeZone?) {
        selection = zone
        onDone()
    }
}

// MARK: - Alerts

struct AlarmListEditor: View {
    @Binding var alarms: [Alarm]
    let isAllDay: Bool

    var body: some View {
        ForEach(alarms.indices, id: \.self) { index in
            HStack {
                Picker("Alert \(index + 1)", selection: $alarms[index]) {
                    ForEach(options(including: alarms[index]), id: \.self) { alarm in
                        Text(EventText.alarm(alarm, isAllDay: isAllDay)).tag(alarm)
                    }
                }
                Button {
                    alarms.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove Alert")
            }
        }
        Button("Add Alert") {
            let presets = AlarmPresets.presets(allDay: isAllDay).map(Alarm.relative)
            let next = presets.first { !alarms.contains($0) } ?? presets[0]
            alarms.append(next)
        }
    }

    /// The presets, plus the current value if it isn't one (e.g. set in another app).
    private func options(including current: Alarm) -> [Alarm] {
        let presets = AlarmPresets.presets(allDay: isAllDay).map(Alarm.relative)
        return presets.contains(current) ? presets : [current] + presets
    }
}

// MARK: - Invitees

/// Invitee list with removal, and a field to add people by email. For Workspace
/// accounts, typing suggests coworkers from the directory.
private struct InviteeEditor: View {
    @Environment(GoogleAccountsStore.self) private var google
    @Binding var draft: EventDraft
    let account: GoogleAuthService.Account?

    @State private var newEmail = ""
    @State private var invalid = false
    @State private var suggestions: [DirectoryPerson] = []

    /// Personal Google accounts have no directory.
    private var isWorkspace: Bool {
        guard let domain = account?.email.split(separator: "@").last?.lowercased() else { return false }
        return !["gmail.com", "googlemail.com"].contains(domain)
    }

    var body: some View {
        ForEach(Array(draft.attendees.enumerated()), id: \.offset) { _, attendee in
            HStack {
                VStack(alignment: .leading) {
                    Text(attendee.displayName)
                    if attendee.name != nil, let email = attendee.email {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(EventText.attendeeStatus(attendee.status)).foregroundStyle(.secondary)
                if let email = attendee.email {
                    Button {
                        draft.removeAttendee(email: email)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove Invitee")
                }
            }
        }
        HStack {
            TextField("Add invitee", text: $newEmail, prompt: Text(isWorkspace ? "Name or email" : "name@example.com"))
                .onSubmit(addTyped)
                .onChange(of: newEmail) { invalid = false }
            Button("Add", action: addTyped)
                .disabled(newEmail.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .task(id: newEmail) { await search(newEmail) }

        ForEach(suggestions) { person in
            Button {
                add(person)
            } label: {
                HStack {
                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(person.name ?? person.email)
                        if person.name != nil {
                            Text(person.email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        if invalid {
            Text("That doesn't look like an email address, or it's already invited.")
                .font(.caption)
                .foregroundStyle(.red)
        } else if isWorkspace, let account, !account.canSearchDirectory {
            Text("To get coworker suggestions, reconnect \(account.email) in Settings > Accounts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Return adds what was typed if it's an email, otherwise the top suggestion.
    private func addTyped() {
        let typed = newEmail.trimmingCharacters(in: .whitespaces)
        if !Normalization.looksLikeEmail(typed), let first = suggestions.first {
            add(first)
        } else if draft.addAttendee(email: typed) {
            newEmail = ""
        } else {
            invalid = true
        }
    }

    private func add(_ person: DirectoryPerson) {
        if draft.addAttendee(email: person.email, name: person.name) {
            newEmail = ""
            suggestions = []
        } else {
            invalid = true
        }
    }

    /// Debounced directory search; `.task(id:)` cancels the previous one per keystroke.
    private func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, let account, account.canSearchDirectory else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let invited = Set(draft.attendees.compactMap { $0.email?.lowercased() })
        let found = (try? await google.searchDirectory(account: account.email, query: query)) ?? []
        guard !Task.isCancelled else { return }
        suggestions = found.filter { !invited.contains($0.email) && $0.email != account.email }
    }
}
