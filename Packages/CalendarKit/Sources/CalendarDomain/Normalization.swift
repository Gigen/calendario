import Foundation

/// Small pure helpers providers use to turn raw provider data into domain conventions.
public enum Normalization {
    /// The exclusive end of an all-day event.
    ///
    /// EventKit reports the end of an all-day event as the last instant of its final day
    /// (e.g. 23:59:59), while Google and iCalendar use the following midnight. The domain
    /// always uses the following midnight. Accepts either form.
    public static func allDayExclusiveEnd(start: Date, end: Date, calendar: Calendar) -> Date {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        if end == endDay, endDay > startDay {
            return end
        }
        return calendar.date(byAdding: .day, value: 1, to: endDay)!
    }

    /// The end date to give EventKit for an all-day event: the last instant of the final
    /// day, the inverse of `allDayExclusiveEnd`.
    public static func eventKitAllDayEnd(exclusiveEnd: Date) -> Date {
        exclusiveEnd.addingTimeInterval(-1)
    }

    /// Extracts the address from a `mailto:` URL string.
    public static func email(fromMailto string: String) -> String? {
        var value = string.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("mailto:") {
            value = String(value.dropFirst("mailto:".count))
        }
        value = value.removingPercentEncoding ?? value
        if let query = value.firstIndex(of: "?") {
            value = String(value[..<query])
        }
        return looksLikeEmail(value) ? value.lowercased() : nil
    }

    public static func looksLikeEmail(_ string: String) -> Bool {
        let parts = string.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return false }
        return !string.contains(where: \.isWhitespace)
    }

    /// Classifies a CalDAV account by its title. EventKit reports Google, iCloud (on
    /// macOS) and generic CalDAV accounts all as CalDAV, and offers no public way to see
    /// the server, so the account title is the best available signal. Once a Google
    /// account is connected over OAuth, matching by email refines this.
    public static func calDAVSourceKind(title: String) -> SourceKind {
        let lowered = title.lowercased()
        if lowered == "icloud" || lowered.hasSuffix("@icloud.com") || lowered.hasSuffix("@me.com") || lowered.hasSuffix("@mac.com") {
            return .iCloud
        }
        if lowered.contains("google") || lowered.hasSuffix("@gmail.com") || lowered.hasSuffix("@googlemail.com") {
            return .google
        }
        return .calDAV
    }
}
