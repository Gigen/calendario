import AppKit
import CalendarDomain
import SwiftUI

// Calendar appearance: colors, background pattern, event and reminder styles.
// Chosen in Settings > Appearance; every view reads the current theme from the
// environment, so the whole app restyles at once.

enum PaletteStyle: String, CaseIterable, Identifiable {
    case standard, pastel
    var id: Self { self }
    var label: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .pastel: String(localized: "Pastel")
        }
    }
}

enum BackgroundPattern: String, CaseIterable, Identifiable {
    case none, dots, grid, ruled
    var id: Self { self }
    var label: String {
        switch self {
        case .none: String(localized: "None")
        case .dots: String(localized: "Dots")
        case .grid: String(localized: "Grid")
        case .ruled: String(localized: "Ruled Lines")
        }
    }
}

enum EventStyle: String, CaseIterable, Identifiable {
    case solid, gradient, stripes
    var id: Self { self }
    var label: String {
        switch self {
        case .solid: String(localized: "Solid")
        case .gradient: String(localized: "Soft Gradient")
        case .stripes: String(localized: "Diagonal Stripes")
        }
    }
}

enum ReminderStyle: String, CaseIterable, Identifiable {
    case outline, dashed, dotted
    var id: Self { self }
    var label: String {
        switch self {
        case .outline: String(localized: "Outline")
        case .dashed: String(localized: "Dashed")
        case .dotted: String(localized: "Dotted")
        }
    }
}

/// Ready-made combinations.
enum ThemePreset: String, CaseIterable, Identifiable {
    case standard, pastel, pastelPatterns
    var id: Self { self }
    var label: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .pastel: String(localized: "Pastel")
        case .pastelPatterns: String(localized: "Pastel with Patterns")
        }
    }

    var theme: CalendarTheme {
        switch self {
        case .standard: CalendarTheme()
        case .pastel: CalendarTheme(palette: .pastel, background: .dots, events: .solid, reminders: .dashed, canvas: CanvasColor.cream.color)
        case .pastelPatterns: CalendarTheme(palette: .pastel, background: .grid, events: .stripes, reminders: .dotted, canvas: CanvasColor.sky.color)
        }
    }
}

struct CalendarTheme: Equatable {
    var palette: PaletteStyle = .standard
    var background: BackgroundPattern = .none
    var events: EventStyle = .solid
    var reminders: ReminderStyle = .outline
    /// The calendar area's background; `nil` follows light/dark mode.
    var canvas: RGBAColor?

    static let standard = CalendarTheme()

    /// Light or dark text for the chosen background, so it stays readable.
    var canvasColorScheme: ColorScheme? {
        guard let canvas else { return nil }
        let luminance = 0.2126 * canvas.red + 0.7152 * canvas.green + 0.0722 * canvas.blue
        return luminance > 0.5 ? .light : .dark
    }

    /// User-defaults keys, shared by Settings and every view.
    enum Key {
        static let palette = "theme.palette"
        static let background = "theme.background"
        static let events = "theme.events"
        static let reminders = "theme.reminders"
        /// Hex like "#FAF6EF"; empty for the default.
        static let canvas = "theme.canvas"
        static let appAppearance = "theme.appAppearance"
    }

    // MARK: Colors

    /// A calendar's color as used for strong accents (the bar, dots, checkboxes).
    func accent(_ color: RGBAColor) -> Color {
        switch palette {
        case .standard: Color(color)
        case .pastel: Color(color.pastel(saturationScale: 0.7, brightness: 0.86))
        }
    }

    /// The color for filled areas (event boxes, all-day bars).
    func fill(_ color: RGBAColor) -> Color {
        switch palette {
        case .standard: Color(color).opacity(0.22)
        case .pastel: Color(color.pastel()).opacity(0.6)
        }
    }

    // MARK: Event and reminder backgrounds

    /// The background of an event box or all-day bar in this theme.
    @ViewBuilder func eventBackground(_ color: RGBAColor, cornerRadius: CGFloat = 4) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        switch events {
        case .solid:
            shape.fill(fill(color))
        case .gradient:
            shape.fill(LinearGradient(colors: [fill(color), fill(color).opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .stripes:
            shape.fill(fill(color))
                .overlay(DiagonalStripes(spacing: 7, lineWidth: 2).foregroundStyle(accent(color).opacity(0.22)).clipShape(shape))
        }
    }

    /// The frame and fill of a timed reminder in this theme.
    @ViewBuilder func reminderBackground(_ color: RGBAColor, cornerRadius: CGFloat = 4) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let tint = palette == .pastel ? Color(color.pastel()).opacity(0.3) : Color(color).opacity(0.08)
        switch reminders {
        case .outline:
            shape.fill(tint).overlay(shape.strokeBorder(accent(color).opacity(0.6), lineWidth: 1))
        case .dashed:
            shape.fill(tint).overlay(shape.strokeBorder(accent(color).opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
        case .dotted:
            shape.fill(tint)
                .overlay(DotPattern(spacing: 5, radius: 0.9).foregroundStyle(accent(color).opacity(0.35)).clipShape(shape))
                .overlay(shape.strokeBorder(accent(color).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [1, 2])))
        }
    }

    // MARK: Page background

    /// The pattern behind the day/week grid and the month view.
    @ViewBuilder var pageBackground: some View {
        switch background {
        case .none: Color.clear
        case .dots: DotPattern(spacing: 14, radius: 1).foregroundStyle(Color.secondary.opacity(0.18))
        case .grid: GridPattern(spacing: 16).foregroundStyle(Color.secondary.opacity(0.1))
        case .ruled: RuledPattern(spacing: 12).foregroundStyle(Color.secondary.opacity(0.1))
        }
    }
}

extension EnvironmentValues {
    @Entry var calendarTheme = CalendarTheme.standard
}

/// Reads the theme from Settings and hands it to everything inside.
struct ThemeFromSettings: ViewModifier {
    @AppStorage(CalendarTheme.Key.palette) private var palette = PaletteStyle.standard
    @AppStorage(CalendarTheme.Key.background) private var background = BackgroundPattern.none
    @AppStorage(CalendarTheme.Key.events) private var events = EventStyle.solid
    @AppStorage(CalendarTheme.Key.reminders) private var reminders = ReminderStyle.outline
    @AppStorage(CalendarTheme.Key.canvas) private var canvas = ""
    @AppStorage(CalendarTheme.Key.appAppearance) private var appAppearance = AppAppearance.system

    func body(content: Content) -> some View {
        content
            .environment(\.calendarTheme, CalendarTheme(
                palette: palette, background: background, events: events, reminders: reminders,
                canvas: RGBAColor(hex: canvas)
            ))
            .onAppear { appAppearance.apply() }
            .onChange(of: appAppearance) { appAppearance.apply() }
    }
}

extension View {
    func calendarThemeFromSettings() -> some View { modifier(ThemeFromSettings()) }
}

// MARK: - Patterns

struct DiagonalStripes: Shape {
    var spacing: CGFloat
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path.strokedPath(StrokeStyle(lineWidth: lineWidth))
    }
}

struct DotPattern: Shape {
    var spacing: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var y = spacing / 2
        while y < rect.height {
            var x = spacing / 2
            while x < rect.width {
                path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
        return path
    }
}

struct GridPattern: Shape {
    var spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x: CGFloat = 0
        while x <= rect.width {
            path.addRect(CGRect(x: x, y: 0, width: 0.5, height: rect.height))
            x += spacing
        }
        var y: CGFloat = 0
        while y <= rect.height {
            path.addRect(CGRect(x: 0, y: y, width: rect.width, height: 0.5))
            y += spacing
        }
        return path
    }
}

struct RuledPattern: Shape {
    var spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var y = spacing
        while y <= rect.height {
            path.addRect(CGRect(x: 0, y: y, width: rect.width, height: 0.5))
            y += spacing
        }
        return path
    }
}

// MARK: - Background color and app appearance

/// Light, Dark, or follow macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Background color choices for the calendar area.
enum CanvasColor: String, CaseIterable, Identifiable {
    case paper, cream, mint, sky, lavender, blush, charcoal
    var id: Self { self }

    var label: String {
        switch self {
        case .paper: String(localized: "Paper")
        case .cream: String(localized: "Cream")
        case .mint: String(localized: "Mint")
        case .sky: String(localized: "Sky")
        case .lavender: String(localized: "Lavender")
        case .blush: String(localized: "Blush")
        case .charcoal: String(localized: "Charcoal")
        }
    }

    var color: RGBAColor {
        switch self {
        case .paper: CalendarPalette.hex(0xFDFCFA)
        case .cream: CalendarPalette.hex(0xFAF5EB)
        case .mint: CalendarPalette.hex(0xEEF7F1)
        case .sky: CalendarPalette.hex(0xEEF4FB)
        case .lavender: CalendarPalette.hex(0xF3F0FA)
        case .blush: CalendarPalette.hex(0xFBEFF1)
        case .charcoal: CalendarPalette.hex(0x2A2B30)
        }
    }
}

extension RGBAColor {
    /// From "#RRGGBB"; nil for anything else (including empty).
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self = CalendarPalette.hex(value)
    }

    var hexString: String {
        func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
