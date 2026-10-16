import AppKit
import CalendarDomain
import SwiftUI

/// A one-line event entry (month cells, all-day strip). Click for details.
struct EventChip: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    let event: Event
    var showsTime = true
    @State private var showingDetail = false

    var body: some View {
        let color = theme.accent(store.calendar(id: event.calendarID)?.color ?? .gray)
        Button { showingDetail = true } label: {
            HStack(spacing: 4) {
                if event.isAllDay {
                    Text(event.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Circle().fill(color).frame(width: 7, height: 7)
                    if showsTime {
                        Text(EventText.startTime(event))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(event.title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .font(.callout)
            .strikethrough(event.status == .canceled)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                if event.isAllDay {
                    theme.eventBackground(store.calendar(id: event.calendarID)?.color ?? .gray)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
            EventDetailView(event: event)
        }
    }
}

/// A timed event box in the day/week grid.
struct EventBlock: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    let event: Event
    let placement: DayLayout.Placement
    /// Points available; extra lines only appear when they fit (depends on zoom).
    let height: CGFloat
    @State private var showingDetail = false

    var body: some View {
        let color = theme.accent(store.calendar(id: event.calendarID)?.color ?? .gray)
        Button { showingDetail = true } label: {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.callout.weight(.semibold))
                        .strikethrough(event.status == .canceled)
                    if height >= 34 {
                        Text(EventText.timeRange(event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let location = event.location, height >= 50 {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { theme.eventBackground(store.calendar(id: event.calendarID)?.color ?? .gray) }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetail, arrowEdge: .trailing) {
            EventDetailView(event: event)
        }
    }
}

/// Event details, with Edit and Delete for writable calendars.
struct EventDetailView: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    @Environment(\.eventActions) private var actions
    @Environment(\.dismiss) private var dismiss
    let event: Event
    private let math = CalendarMath()

    var body: some View {
        let calendar = store.calendar(id: event.calendarID)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title.isEmpty ? String(localized: "New Event") : event.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Spacer()
                    if store.canModify(event) {
                        Button("Edit") {
                            dismiss()
                            actions.edit(event)
                        }
                        Button(role: .destructive) {
                            dismiss()
                            actions.delete(event)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete Event")
                    }
                }

                if let link = event.conferenceURL {
                    HStack {
                        Link(destination: link) {
                            Label(link.host?.contains("meet.google.com") == true ? "Join Google Meet" : "Join Meeting", systemImage: "video.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }
                    }
                }

                if let invitation = event.invitationForCurrentUser {
                    InvitationResponse(event: event, current: invitation.status)
                }

                if let location = event.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .textSelection(.enabled)
                }

                Label {
                    VStack(alignment: .leading) {
                        Text(EventText.fullRange(event, math: math))
                        if let zone = event.timeZone, !event.isAllDay, zone.identifier != TimeZone.current.identifier {
                            Text(zone.localizedName(for: .generic, locale: .current) ?? zone.identifier)
                                .foregroundStyle(.secondary)
                        }
                        if let rule = event.recurrence {
                            Text(EventText.recurrence(rule)).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "clock")
                }

                if let calendar {
                    Label {
                        Text(calendar.title)
                    } icon: {
                        Circle().fill(theme.accent(calendar.color)).frame(width: 10, height: 10)
                    }
                }

                if !event.alarms.isEmpty {
                    Label {
                        VStack(alignment: .leading) {
                            ForEach(Array(event.alarms.enumerated()), id: \.offset) { _, alarm in
                                Text(EventText.alarm(alarm))
                            }
                        }
                    } icon: {
                        Image(systemName: "bell")
                    }
                }

                if !event.attendees.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            // Organizer in bold; the response is shown by color:
                            // green accepted, orange maybe, red declined, gray no answer.
                            ForEach(Array(event.participants.enumerated()), id: \.offset) { _, participant in
                                let status = EventText.attendeeStatus(participant.attendee.status)
                                Text(participant.attendee.displayName)
                                    .fontWeight(participant.isOrganizer ? .bold : .regular)
                                    .foregroundStyle(EventText.attendeeColor(participant.attendee.status))
                                    .help(participant.isOrganizer ? String(localized: "Organizer") + (status.isEmpty ? "" : ", \(status)") : status)
                                    .accessibilityValue(Text(participant.isOrganizer ? String(localized: "Organizer, \(status)") : status))
                            }
                        }
                    } icon: {
                        Image(systemName: "person.2")
                    }
                }

                if let url = event.url {
                    Label {
                        Link(url.absoluteString, destination: url).lineLimit(1)
                    } icon: {
                        Image(systemName: "link")
                    }
                }

                if let notes = event.notes {
                    Divider()
                    Text(notes)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(width: 320)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Accept / Maybe / Decline for invitations. EventKit can't send responses, so this
/// works for calendars of a connected Google account and goes through Google. For a
/// repeating invitation, picking an answer then asks: this event only, or all events.
struct InvitationResponse: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    @Environment(GoogleAccountsStore.self) private var google
    let event: Event
    let current: Attendee.Status
    var showsLabel = true

    /// The answer just sent; the synced event catches up a little later.
    @State private var sent: Attendee.Status?
    /// A repeating invitation's answer waiting for "this event or all events".
    @State private var choosingScopeFor: Attendee.Status?
    /// The series' rule, looked up if this occurrence doesn't carry it.
    @State private var seriesRule: RecurrenceRule?
    @State private var sending = false
    @State private var error: String?
    private let math = CalendarMath()

    var body: some View {
        let remote = google.remoteCalendars(for: store)[event.calendarID]
        let status = sent ?? current
        VStack(alignment: .leading, spacing: 6) {
            if remote != nil {
                HStack(spacing: 6) {
                    if showsLabel {
                        Text("Going?").foregroundStyle(.secondary)
                    }
                    choice("Accept", .accepted, status, tint: .green)
                    choice("Maybe", .tentative, status, tint: .orange)
                    choice("Decline", .declined, status, tint: .red)
                    if sending { ProgressView().controlSize(.small) }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } else if store.sources.first(where: { $0.id == store.calendar(id: event.calendarID)?.sourceID }).map(CalendarMatcher.mightBeGoogle) == true {
                Text(google.isConfigured
                     ? "To respond from here, connect this calendar's Google account in Settings > Accounts."
                     : "Respond to this invitation in Google Calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("macOS doesn't let apps answer this kind of invitation. Respond in the account's own app (e.g. Outlook).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(
            scopeTitle,
            isPresented: Binding(get: { choosingScopeFor != nil }, set: { if !$0 { choosingScopeFor = nil } }),
            presenting: choosingScopeFor
        ) { answer in
            Button("Only This Event") { respond(answer, wholeSeries: false) }
            Button("All Events") { respond(answer, wholeSeries: true) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“\(event.title)” repeats: \(EventText.seriesSummary(eventWithRule)). Answer only \(event.start.formatted(.dateTime.weekday(.wide).day().month(.wide))), or every event in the series?")
        }
        .task(id: event.id) {
            if event.isRecurring { seriesRule = await store.seriesRecurrence(for: event) }
        }
    }

    private var eventWithRule: Event {
        var copy = event
        if copy.recurrence == nil { copy.recurrence = seriesRule }
        return copy
    }

    private var scopeTitle: String {
        switch choosingScopeFor {
        case .accepted: String(localized: "Accept Repeating Event")
        case .declined: String(localized: "Decline Repeating Event")
        default: String(localized: "Answer Maybe to Repeating Event")
        }
    }

    @ViewBuilder
    private func choice(_ title: LocalizedStringKey, _ choice: Attendee.Status, _ status: Attendee.Status, tint: Color) -> some View {
        let selected = status == choice
        Button {
            if event.isRecurring {
                choosingScopeFor = choice
            } else {
                respond(choice, wholeSeries: false)
            }
        } label: {
            Text(title).fontWeight(selected ? .semibold : .regular)
        }
        .buttonStyle(.bordered)
        .tint(selected ? tint : nil)
        .disabled(sending || (status == choice && !event.isRecurring))
    }

    private func respond(_ choice: Attendee.Status, wholeSeries: Bool) {
        guard let remote = google.remoteCalendars(for: store)[event.calendarID] else { return }
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                try await google.respond(to: event, with: choice, in: remote, wholeSeries: wholeSeries)
                sent = choice
                choosingScopeFor = nil
                store.noteResponse(choice, to: event, wholeSeries: wholeSeries)
            } catch {
                self.error = ErrorText.message(for: error)
            }
        }
    }
}
