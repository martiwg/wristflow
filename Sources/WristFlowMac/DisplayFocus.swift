import AppKit
import ApplicationServices
import WristFlowCore

/// Moves the pointer to a display and brings forward the window in front on it.
@MainActor
final class MacDisplayFocus: @MainActor DisplayFocusing {
    /// How long keyboard and pointer have to be idle before focus may move. Long enough that a
    /// pause between two keystrokes or two nudges of the mouse does not count as idle.
    private static let quietTime = 0.7
    /// Smaller windows on the normal layer are helper surfaces, not something to work in.
    private static let minimumWindowSide: CGFloat = 80
    /// The window server and the Accessibility API round a window's frame differently.
    private static let frameTolerance: CGFloat = 2
    /// Accessibility calls are synchronous messages to the other app; an app that hangs must
    /// not hang WristFlow's main thread with it (the default is several seconds).
    private static let messagingTimeout: Float = 0.25

    /// Where the pointer was on each display when it last left, as fractions of the display's
    /// width and height so the spot survives a change of resolution or arrangement.
    private var pointerSpots: [String: CGPoint] = [:]

    var displays: [DisplayInfo] {
        connectedDisplays().map { DisplayInfo(id: $0.id, name: $0.name) }
    }

    var currentDisplay: String? {
        guard let pointer = pointerLocation() else { return nil }
        return connectedDisplays().first { $0.bounds.contains(pointer) }?.id
    }

    @discardableResult
    func focus(display id: String) -> Bool {
        let all = connectedDisplays()
        guard let target = all.first(where: { $0.id == id }), let pointer = pointerLocation() else { return false }
        let origin = all.first { $0.bounds.contains(pointer) }
        guard origin?.id != id else { return false }
        // A hand on the keyboard, mouse or trackpad outranks the eyes: people glance at the
        // other display all the time while they keep working on this one.
        guard !InputActivity.recentKeyboardOrPointerUse(within: Self.quietTime),
              NSEvent.pressedMouseButtons == 0 else { return false }

        if let origin { pointerSpots[origin.id] = origin.fraction(at: pointer) }
        CGWarpMouseCursorPosition(target.point(at: pointerSpots[id] ?? CGPoint(x: 0.5, y: 0.5)))
        // A warp makes the system ignore the mouse for a quarter of a second; re-associating
        // mouse and cursor lifts that at once.
        CGAssociateMouseAndMouseCursorPosition(1)
        InputActivity.noteOwnPointerMove()

        if let window = frontWindow(on: target) { bringForward(window) }
        return true
    }

    // MARK: Displays

    private struct Display {
        let id: String
        let name: String
        /// In Quartz global coordinates: origin at the top left of the main display, y down.
        let bounds: CGRect

        func fraction(at point: CGPoint) -> CGPoint {
            guard bounds.width > 0, bounds.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
            return CGPoint(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
        }

        func point(at fraction: CGPoint) -> CGPoint {
            // Kept a point inside the edges so the result is on this display and no other.
            let x = bounds.minX + fraction.x * bounds.width
            let y = bounds.minY + fraction.y * bounds.height
            return CGPoint(
                x: min(max(x, bounds.minX), bounds.maxX - 1),
                y: min(max(y, bounds.minY), bounds.maxY - 1)
            )
        }
    }

    /// Bounds come from Quartz rather than from `NSScreen.frame`: the pointer, the warp and the
    /// window list all use Quartz coordinates, while AppKit's have their origin at the bottom
    /// left, so staying in one system avoids flipping every value.
    private func connectedDisplays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
                  let id = CFUUIDCreateString(nil, uuid) as String?
            else { return nil }
            return Display(id: id, name: screen.localizedName, bounds: CGDisplayBounds(number))
        }
    }

    private func pointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    // MARK: Windows

    private struct FrontWindow {
        let app: NSRunningApplication
        let bounds: CGRect
    }

    private func frontWindow(on display: Display) -> FrontWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // The list runs front to back, so the first window that qualifies is the one in front.
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let frame = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: frame),
                  bounds.width >= Self.minimumWindowSide, bounds.height >= Self.minimumWindowSide,
                  display.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)),
                  let app = NSRunningApplication(processIdentifier: pid),
                  // Background-only processes cannot become active, so their windows are
                  // overlays rather than something to focus.
                  app.activationPolicy != .prohibited
            else { continue }
            return FrontWindow(app: app, bounds: bounds)
        }
        return nil
    }

    private func bringForward(_ window: FrontWindow) {
        let isFrontmostApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.app.processIdentifier
        guard Accessibility.isGranted else {
            if !isFrontmostApp { window.app.activate() }
            return
        }

        let appElement = AXUIElementCreateApplication(window.app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        let element = accessibilityWindow(of: appElement, matching: window.bounds)
        if let element {
            if isFrontmostApp, attribute(element, kAXMainAttribute) as? Bool == true { return }
            // Main first, activation second: activating brings the app's main window forward,
            // which would otherwise be whichever one it had, possibly on another display.
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        guard !isFrontmostApp else { return }
        window.app.activate()
        // The system may turn down an activation asked for by an app that is not active itself,
        // as WristFlow never is. Asking through Accessibility is not subject to that.
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// The window list and the Accessibility API share no public identifier, so the window is
    /// recognised by its frame, which both report in Quartz global coordinates.
    private func accessibilityWindow(of app: AXUIElement, matching bounds: CGRect) -> AXUIElement? {
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let position = geometry(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
                  let size = geometry(window, kAXSizeAttribute, .cgSize, CGSize.zero)
            else { return false }
            return abs(position.x - bounds.minX) <= Self.frameTolerance
                && abs(position.y - bounds.minY) <= Self.frameTolerance
                && abs(size.width - bounds.width) <= Self.frameTolerance
                && abs(size.height - bounds.height) <= Self.frameTolerance
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func geometry<Value: BitwiseCopyable>(_ element: AXUIElement, _ name: String, _ type: AXValueType, _ empty: Value) -> Value? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = empty
        return AXValueGetValue(raw as! AXValue, type, &value) ? value : nil
    }
}
