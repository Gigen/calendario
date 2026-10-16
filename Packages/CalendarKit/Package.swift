// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalendarKit",
    platforms: [.macOS(.v15)],
    products: [
        // Portable: Foundation only. A Windows client could reuse this as-is.
        .library(name: "CalendarDomain", targets: ["CalendarDomain"]),
        // macOS only: EventKit-backed implementation of the provider protocols.
        .library(name: "EventKitProvider", targets: ["EventKitProvider"]),
        // Google OAuth and Calendar API (Meet links, invitees). Foundation only, apart
        // from the Keychain token store, which is macOS-specific.
        .library(name: "GoogleCalendarAPI", targets: ["GoogleCalendarAPI"]),
    ],
    targets: [
        .target(name: "CalendarDomain"),
        .target(name: "EventKitProvider", dependencies: ["CalendarDomain"]),
        .target(name: "GoogleCalendarAPI", dependencies: ["CalendarDomain"]),
        .testTarget(name: "CalendarDomainTests", dependencies: ["CalendarDomain"]),
        .testTarget(name: "GoogleCalendarAPITests", dependencies: ["GoogleCalendarAPI", "CalendarDomain"]),
    ]
)
