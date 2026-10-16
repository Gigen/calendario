import CalendarDomain
import Foundation

/// Colors the user picked in Calendario for calendars and reminder lists. They only
/// affect this app; the account's own color (as in Apple Calendar) stays the default.
/// Read fresh on every use, so the calendar and reminder stores never overwrite each
/// other's changes.
enum ColorOverrides {
    private static let key = "calendarColorOverrides"

    static func all() -> [String: RGBAColor] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let colors = try? JSONDecoder().decode([String: RGBAColor].self, from: data) else { return [:] }
        return colors
    }

    static func set(_ color: RGBAColor?, for id: String) {
        var colors = all()
        colors[id] = color
        if let data = try? JSONEncoder().encode(colors) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// `calendars` with overrides applied; `systemColors` supplies the defaults.
    static func apply(to calendars: [CalendarInfo], systemColors: [String: RGBAColor]) -> [CalendarInfo] {
        let overrides = all()
        return calendars.map { calendar in
            var calendar = calendar
            calendar.color = overrides[calendar.id] ?? systemColors[calendar.id] ?? calendar.color
            return calendar
        }
    }
}
