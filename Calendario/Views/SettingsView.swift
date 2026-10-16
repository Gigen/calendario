import CalendarDomain
import GoogleCalendarAPI
import SwiftUI

/// Calendario > Settings (⌘,).
struct SettingsView: View {
    @State private var tab = Demo.extra == "settings" ? "appearance" : "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") {
                AppearanceSettings()
            }
            Tab("Accounts", systemImage: "person.crop.circle", value: "accounts") {
                AccountsSettings()
            }
        }
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettings: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some View {
        Form {
            Toggle("Show today's agenda in the menu bar", isOn: $showMenuBarExtra)
            Section {
                LabeledContent("Week starts on") {
                    Text(Calendar.current.weekdaySymbols[Calendar.current.firstWeekday - 1])
                }
                LabeledContent("Time format") {
                    Text(Date().formatted(date: .omitted, time: .shortened))
                }
            } footer: {
                Text("These follow System Settings > General > Language & Region.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Google accounts connected for Meet links and invitees. Calendars themselves come
/// from System Settings > Internet Accounts; this only adds what EventKit can't do.
private struct AccountsSettings: View {
    @Environment(GoogleAccountsStore.self) private var google
    @Environment(CalendarStore.self) private var store

    var body: some View {
        Form {
            Section {
                if !google.isConfigured {
                    Text("Google isn't set up in this build. Add your OAuth client ID as GOOGLE_CLIENT_ID in Config/Local.xcconfig and rebuild (see SETUP.md).")
                        .foregroundStyle(.secondary)
                } else if google.accounts.isEmpty {
                    Text("No Google accounts connected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(google.accounts) { account in
                        AccountRow(account: account, matched: matchedCount(for: account.email))
                    }
                }
            } header: {
                Text("Google Accounts")
            } footer: {
                Text("Connect the Google accounts you also use in System Settings > Internet Accounts to add Google Meet links and invitees to their events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if google.isConfigured {
                HStack {
                    if let error = google.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Connect Google Account…") { Task { await google.connect() } }
                        .disabled(google.isConnecting)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func matchedCount(for email: String) -> Int {
        google.remoteCalendars(for: store).values.filter { $0.accountEmail == email }.count
    }
}

private struct AccountRow: View {
    @Environment(GoogleAccountsStore.self) private var google
    @Environment(SyncMonitor.self) private var syncMonitor
    let account: GoogleAuthService.Account
    let matched: Int

    var body: some View {
        HStack {
            Image(systemName: account.needsReauthentication ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(account.needsReauthentication ? .orange : .green)
            VStack(alignment: .leading) {
                Text(account.email)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .behind(let missing, let oldest) = syncMonitor.health[account.email] {
                    Text("macOS isn't syncing this account: \(missing) changes since \(oldest.formatted(date: .abbreviated, time: .shortened)) are missing. Sign in again in System Settings > Internet Accounts.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !account.needsReauthentication, !account.canSearchDirectory, isWorkspace {
                    Text("Reconnect to get coworker suggestions when adding invitees.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if syncMonitor.health[account.email] == .healthy {
                    Text("macOS is syncing this account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.needsReauthentication || (isWorkspace && !account.canSearchDirectory) {
                Button("Reconnect…") { Task { await google.connect(loginHint: account.email) } }
            }
            Button("Disconnect") { Task { await google.disconnect(email: account.email) } }
        }
    }

    /// Personal Google accounts have no directory to search.
    private var isWorkspace: Bool {
        !account.email.hasSuffix("@gmail.com") && !account.email.hasSuffix("@googlemail.com")
    }

    private var status: String {
        if account.needsReauthentication {
            return String(localized: "Sign-in expired. Reconnect to keep adding Meet links.")
        }
        if matched == 0 {
            return String(localized: "Connected, but no calendar on this Mac matches it. Is the account in Internet Accounts?")
        }
        return matched == 1
            ? String(localized: "Connected · 1 calendar")
            : String(localized: "Connected · \(matched) calendars")
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(CalendarTheme.Key.palette) private var palette = PaletteStyle.standard
    @AppStorage(CalendarTheme.Key.background) private var background = BackgroundPattern.none
    @AppStorage(CalendarTheme.Key.events) private var events = EventStyle.solid
    @AppStorage(CalendarTheme.Key.reminders) private var reminders = ReminderStyle.outline
    @AppStorage(CalendarTheme.Key.canvas) private var canvas = ""
    @AppStorage(CalendarTheme.Key.appAppearance) private var appAppearance = AppAppearance.system

    private var theme: CalendarTheme {
        CalendarTheme(palette: palette, background: background, events: events, reminders: reminders, canvas: RGBAColor(hex: canvas))
    }

    /// The menu's value: Default, one of the presets, or Custom.
    private var canvasChoice: Binding<String> {
        Binding(
            get: {
                guard let color = RGBAColor(hex: canvas) else { return "default" }
                return CanvasColor.allCases.first { $0.color.hexString == color.hexString }?.rawValue ?? "custom"
            },
            set: { choice in
                if choice == "default" {
                    canvas = ""
                } else if let preset = CanvasColor(rawValue: choice) {
                    canvas = preset.color.hexString
                } else if RGBAColor(hex: canvas) == nil {
                    canvas = CanvasColor.paper.color.hexString
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Style") {
                Picker("Style", selection: Binding(
                    get: { ThemePreset.allCases.first { $0.theme == theme } },
                    set: { preset in if let preset { apply(preset.theme) } }
                )) {
                    ForEach(ThemePreset.allCases) { preset in
                        Text(preset.label).tag(Optional(preset))
                    }
                    if !ThemePreset.allCases.contains(where: { $0.theme == theme }) {
                        Text("Custom").tag(ThemePreset?.none)
                    }
                }
                .pickerStyle(.segmented)
                ThemePreview(theme: theme)
            }
            Section("Window") {
                Picker("App Appearance", selection: $appAppearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Calendar Background", selection: canvasChoice) {
                    Text("Default (follows appearance)").tag("default")
                    Divider()
                    ForEach(CanvasColor.allCases) { preset in
                        Label { Text(preset.label) } icon: { CalendarPalette.swatch(preset.color) }.tag(preset.rawValue)
                    }
                    Divider()
                    Text("Custom").tag("custom")
                }
                if canvasChoice.wrappedValue == "custom" {
                    ColorPicker("Custom Background", selection: Binding(
                        get: { Color(RGBAColor(hex: canvas) ?? CanvasColor.paper.color) },
                        set: { canvas = CalendarPalette.rgba($0)?.hexString ?? canvas }
                    ), supportsOpacity: false)
                }
            }
            Section("Customize") {
                Picker("Colors", selection: $palette) {
                    ForEach(PaletteStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Background", selection: $background) {
                    ForEach(BackgroundPattern.allCases) { Text($0.label).tag($0) }
                }
                Picker("Events", selection: $events) {
                    ForEach(EventStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Reminders", selection: $reminders) {
                    ForEach(ReminderStyle.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func apply(_ theme: CalendarTheme) {
        palette = theme.palette
        background = theme.background
        events = theme.events
        reminders = theme.reminders
        canvas = theme.canvas?.hexString ?? ""
    }
}

/// A miniature day: two events and a reminder on the chosen background.
private struct ThemePreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let theme: CalendarTheme

    private let blue = CalendarPalette.hex(0x007AFF)
    private let green = CalendarPalette.hex(0x34C759)
    private let orange = CalendarPalette.hex(0xFF9500)

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 6) {
                block("Design review", "10:00 – 11:00", blue, height: 46)
                reminder("Send notes", orange)
            }
            VStack(spacing: 6) {
                block("Lunch", "12:30 – 13:30", green, height: 46)
                block("1:1", "14:00 – 14:30", blue, height: 26)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background { theme.pageBackground }
        .background(theme.canvas.map { Color($0) } ?? Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, theme.canvasColorScheme ?? colorScheme)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func block(_ title: String, _ time: String, _ color: RGBAColor, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(theme.accent(color)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                if height > 30 { Text(time).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .frame(height: height)
        .background { theme.eventBackground(color) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func reminder(_ title: String, _ color: RGBAColor) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "circle").foregroundStyle(theme.accent(color))
            Text("16:00").foregroundStyle(.secondary)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .frame(height: 18)
        .background { theme.reminderBackground(color) }
    }
}
