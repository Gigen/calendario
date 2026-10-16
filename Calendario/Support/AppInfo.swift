import Foundation

enum AppInfo {
    /// The bundle ID, used for logging and Keychain item names.
    static let bundleID = Bundle.main.bundleIdentifier ?? "Calendario"
    static let subsystem = bundleID
}
