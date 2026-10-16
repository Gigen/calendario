import AppKit
import CalendarDomain
import SwiftUI

/// Calendars grouped by account, then reminder lists, each with a show/hide checkbox.
struct SidebarView: View {
    @Environment(\.calendarTheme) private var theme
    @Environment(CalendarStore.self) private var store
    @Environment(ReminderStore.self) private var reminders

    var body: some View {
        List {
            ForEach(store.sources) { source in
                Section {
                    ForEach(store.calendars(in: source)) { calendar in
                        VisibilityRow(
                            calendar: calendar,
                            isVisible: store.isVisible(calendar),
                            hasCustomColor: store.hasCustomColor(calendar),
                            toggle: { store.setVisible(!store.isVisible(calendar), for: calendar) },
                            setColor: { store.setColor($0, for: calendar) }
                        )
                    }
                } header: {
                    Text(source.title)
                        .contextMenu {
                            Button("Show All") { store.setVisible(true, forAllIn: source) }
                            Button("Hide All") { store.setVisible(false, forAllIn: source) }
                        }
                }
            }
            remindersSection
        }
        .modifier(SidebarListStyle())
        .overlay {
            if store.calendars.isEmpty {
                ContentUnavailableView(
                    "No Calendars",
                    systemImage: "calendar",
                    description: Text("Add accounts in System Settings > Internet Accounts.")
                )
            }
        }
    }
}

extension SidebarView {
    @ViewBuilder fileprivate var remindersSection: some View {
        Section("Reminders") {
            switch reminders.access {
            case .fullAccess:
                let showSource = Set(reminders.lists.map(\.sourceID)).count > 1
                ForEach(reminders.lists) { list in
                    VisibilityRow(
                        calendar: list,
                        subtitle: showSource ? reminders.sources.first { $0.id == list.sourceID }?.title : nil,
                        isVisible: reminders.isVisible(list),
                        hasCustomColor: reminders.hasCustomColor(list),
                        toggle: { reminders.setVisible(!reminders.isVisible(list), for: list) },
                        setColor: { reminders.setColor($0, for: list) }
                    )
                }
            case .notDetermined:
                Button("Allow Access…") { Task { await reminders.requestAccess() } }
                    .disabled(reminders.isRequestingAccess)
            case nil:
                EmptyView()
            default:
                Text("No access. See System Settings > Privacy & Security > Reminders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A calendar or reminder list with a show/hide checkbox in its own color.
/// Right-click to change the color.
private struct VisibilityRow: View {
    @Environment(\.calendarTheme) private var theme
    let calendar: CalendarInfo
    var subtitle: String?
    let isVisible: Bool
    let hasCustomColor: Bool
    let toggle: () -> Void
    /// `nil` restores the account's color.
    let setColor: (RGBAColor?) -> Void

    @State private var pickingCustomColor = false

    var body: some View {
        let visible = isVisible
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: visible ? "checkmark.square.fill" : "square")
                    .foregroundStyle(theme.accent(calendar.color))
                    .imageScale(.large)
                Text(calendar.title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !calendar.allowsContentModifications {
                    Image(systemName: "lock")
                        .foregroundStyle(.tertiary)
                        .help("Read-only")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(visible ? Text("Shown") : Text("Hidden"))
        .contextMenu {
            Menu("Color") {
                ForEach(CalendarPalette.presets, id: \.name) { preset in
                    Button {
                        setColor(preset.color)
                    } label: {
                        Label { Text(preset.name) } icon: { CalendarPalette.swatch(preset.color) }
                    }
                }
                Divider()
                Button("Custom…") { pickingCustomColor = true }
                if hasCustomColor {
                    Button("Use Account Color") { setColor(nil) }
                }
            }
        }
        .popover(isPresented: $pickingCustomColor, arrowEdge: .trailing) {
            CustomColorPicker(initial: calendar.color, setColor: setColor)
        }
    }
}

private struct CustomColorPicker: View {
    @Environment(\.calendarTheme) private var theme
    @State private var color: Color
    let setColor: (RGBAColor?) -> Void

    init(initial: RGBAColor, setColor: @escaping (RGBAColor?) -> Void) {
        _color = State(initialValue: Color(initial))
        self.setColor = setColor
    }

    var body: some View {
        ColorPicker("Calendar Color", selection: $color, supportsOpacity: false)
            .padding()
            .onChange(of: color) { setColor(CalendarPalette.rgba(color)) }
    }
}

/// Preset calendar colors, close to Apple Calendar's.
enum CalendarPalette {
    static let presets: [(name: String, color: RGBAColor)] = [
        (String(localized: "Red"), hex(0xFF3B30)),
        (String(localized: "Orange"), hex(0xFF9500)),
        (String(localized: "Yellow"), hex(0xFFCC00)),
        (String(localized: "Green"), hex(0x34C759)),
        (String(localized: "Mint"), hex(0x00C7BE)),
        (String(localized: "Teal"), hex(0x30B0C7)),
        (String(localized: "Blue"), hex(0x007AFF)),
        (String(localized: "Indigo"), hex(0x5856D6)),
        (String(localized: "Purple"), hex(0xAF52DE)),
        (String(localized: "Pink"), hex(0xFF2D55)),
        (String(localized: "Brown"), hex(0xA2845E)),
        (String(localized: "Graphite"), hex(0x8E8E93)),
    ]

    nonisolated static func hex(_ value: UInt32) -> RGBAColor {
        RGBAColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func rgba(_ color: Color) -> RGBAColor? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return RGBAColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: 1)
    }

    /// A colored dot for menus. Menus draw SF Symbols as templates and ignore the
    /// tint, so the dot is a real (non-template) image.
    static func swatch(_ color: RGBAColor) -> Image {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

/// The sidebar style, except in screenshot runs: its glass material can't be
/// rendered into an image, so those use a plain list on the window color.
private struct SidebarListStyle: ViewModifier {
    func body(content: Content) -> some View {
        if Demo.isCapturing {
            content
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            content.listStyle(.sidebar)
        }
    }
}
