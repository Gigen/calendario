import CalendarDomain
import SwiftUI

/// Toolbar button with the number of unanswered invitations; opens the inbox.
struct InboxButton: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    @State private var invitations: [Event] = []
    @State private var showing = false
    var onShow: (Event) -> Void

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Label("Invitations", systemImage: invitations.isEmpty ? "tray" : "tray.full")
                .overlay(alignment: .topTrailing) {
                    if !invitations.isEmpty {
                        Text("\(invitations.count)")
                            .font(.caption2.bold())
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.red))
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .help(invitations.isEmpty ? "No unanswered invitations" : "\(invitations.count) unanswered invitations")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            InboxView(invitations: invitations) { event in
                showing = false
                onShow(event)
            }
            .modifier(OpaquePopoverInScreenshots())
        }
        .task(id: store.revision) {
            invitations = await store.pendingInvitations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoOpenInbox)) { _ in showing = true }
    }
}

/// Unanswered invitations, soonest first, with Accept / Maybe / Decline.
struct InboxView: View {
    @Environment(\.calendarTheme) private var theme
    let invitations: [Event]
    var onShow: (Event) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Invitations")
                .font(.headline)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 8)
            Divider()
            if invitations.isEmpty {
                ContentUnavailableView("No Unanswered Invitations", systemImage: "tray", description: Text("Invitations you haven't answered show up here."))
                    .frame(height: 220)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(invitations) { event in
                            InboxRow(event: event, onShow: onShow)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 520)
            }
        }
        .frame(width: 440)
    }
}

private struct InboxRow: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    let event: Event
    var onShow: (Event) -> Void
    private let math = CalendarMath()

    var body: some View {
        let calendar = store.calendar(id: event.calendarID)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(theme.accent(calendar?.color ?? .gray))
                    .frame(width: 8, height: 8)
                Text(event.title).font(.body.weight(.semibold)).lineLimit(2)
                Spacer()
                Button("Show in Calendar") { onShow(event) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Text(EventText.fullRange(event, math: math))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let organizer = event.organizer {
                    Text("From \(organizer.displayName)")
                }
                if let calendar {
                    Text("·")
                    Text(calendar.title)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if event.isRecurring {
                Label(EventText.seriesSummary(event), systemImage: "repeat") // rule filled in by Invitations.pending
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InvitationResponse(event: event, current: .pending, showsLabel: false)
        }
        .padding(12)
    }
}

/// The glass popover background can't be rendered into a screenshot; screenshot runs
/// use the window color. Normal runs keep the system background.
private struct OpaquePopoverInScreenshots: ViewModifier {
    func body(content: Content) -> some View {
        if Demo.isCapturing {
            content.presentationBackground(Color(nsColor: .windowBackgroundColor))
        } else {
            content
        }
    }
}
