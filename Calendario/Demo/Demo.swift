import AppKit
import CalendarDomain
import SwiftUI

/// Demo mode and README screenshots. Launch arguments (they override user defaults
/// for this run only, nothing is written):
///
///     -demo YES                  fictional data instead of your calendars
///     -demoView days|month|...   view to open
///     -demoScreenshot NAME       save the window to <tmp>/screenshots/NAME.png, then quit
///     -demoExtra editor|inbox|settings   open that before capturing
///
/// Theme keys (e.g. `-theme.palette pastel`) and `-dayCount 5` work the same way.
/// `scripts/screenshots.sh` runs the whole set.
enum Demo {
    static let isEnabled = UserDefaults.standard.bool(forKey: "demo")
    static var initialMode: ViewMode? { UserDefaults.standard.string(forKey: "demoView").flatMap(ViewMode.init(rawValue:)) }
    /// Set by `scripts/screenshots.sh`: prepare the window, signal ready, wait to be captured.
    static var isStaging: Bool { isEnabled && UserDefaults.standard.bool(forKey: "demoStage") }
    static var extra: String? { UserDefaults.standard.string(forKey: "demoExtra") }
    /// Screenshot runs use opaque backgrounds where translucent ones would show
    /// whatever is behind the window.
    static var isCapturing: Bool { isStaging }

    /// The file `scripts/screenshots.sh` waits for (inside the app's sandbox container).
    static var readyMarker: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("demo-ready")
    }

    /// Sizes the window, opens what the screenshot needs (editor, inbox or settings),
    /// writes the ready marker with the window to capture, then quits after a while.
    /// The script captures that one window with `screencapture -l`.
    @MainActor
    static func stage(state: WindowState) async {
        guard isStaging else { return }
        try? FileManager.default.removeItem(at: readyMarker)
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(AppWindow.main) == true }) else {
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 1240, height: 780))
        // On the sharpest screen, so the image is at Retina resolution.
        if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.midY - frame.height / 2))
        }
        // Multi-day views start on Monday, so the sample work week fills them.
        if state.period == .days, !state.showsReminders {
            let today = state.math.startOfDay(Date())
            let weekday = state.math.calendar.component(.weekday, from: today)
            state.date = state.math.addingDays(-((weekday + 5) % 7), to: today)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1.5))

        var target = window
        switch extra {
        case "editor":
            if let event = state.events.first(where: { $0.title == "Design review" }) {
                state.startEditing(event)
            }
        case "inbox":
            NotificationCenter.default.post(name: .demoOpenInbox, object: nil)
        case "settings":
            NotificationCenter.default.post(name: .demoOpenSettings, object: nil)
        default:
            break
        }
        try? await Task.sleep(for: .seconds(2))
        if extra == "settings", let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.canBecomeKey && !$0.className.contains("Popover") }) {
            target = settings
        }
        // Popovers are separate windows; the script captures them on top of the main one.
        let popovers = NSApp.windows.filter { $0 !== target && $0.isVisible && $0.frame.intersects(target.frame) && $0.className.contains("Popover") }
        let overlays = (target.attachedSheet.map { [$0] } ?? []) + popovers
        let ids = ([target] + overlays).map { String($0.windowNumber) }.joined(separator: " ")
        try? ids.write(to: readyMarker, atomically: true, encoding: .utf8)
        // Also render the windows ourselves (no Screen Recording permission needed).
        if let png = render(target, overlays: overlays) {
            try? png.write(to: readyMarker.deletingLastPathComponent().appendingPathComponent("demo-shot.png"))
        }

        try? await Task.sleep(for: .seconds(15))
        NSApp.terminate(nil)
    }
}

extension Demo {
    /// Renders the window's layer tree (and any overlays at their positions) onto the
    /// window background color, at the screen's scale.
    @MainActor
    static func render(_ window: NSWindow, overlays: [NSWindow]) -> Data? {
        let scale = window.backingScaleFactor
        let size = window.frame.size
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        for (index, current) in ([window] + overlays).enumerated() {
            guard let layer = (current.contentView?.superview ?? current.contentView)?.layer else { continue }
            context.saveGState()
            let offset = index == 0 ? .zero : CGPoint(x: current.frame.minX - window.frame.minX, y: current.frame.minY - window.frame.minY)
            context.translateBy(x: offset.x, y: offset.y)
            layer.render(in: context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

extension ToolbarContent {
    /// Liquid Glass toolbar backgrounds can't be rendered into an image, so
    /// screenshot runs hide them (macOS 26 and later).
    @ToolbarContentBuilder
    func hidingGlassInScreenshots() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(Demo.isCapturing ? .hidden : .automatic)
        } else {
            self
        }
    }
}

extension Notification.Name {
    static let demoOpenInbox = Notification.Name("CalendarioDemoOpenInbox")
    static let demoOpenSettings = Notification.Name("CalendarioDemoOpenSettings")
}
