import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio
import Synchronization
import WristFlowCore

/// Carries out bindings on macOS: deep links for Wispr Flow, synthetic key presses for the rest.
@MainActor
struct MacActionPerformer: @MainActor ActionPerforming {
    static let wisprBundleID = "com.electron.wispr-flow"
    private static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    /// The command line tool that comes with the Shortcuts app.
    private static let shortcutsTool = "/usr/bin/shortcuts"

    /// Opens an app, a file or a link. Anything with a scheme is a link; the rest is a path.
    private static func open(_ target: String?) {
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { return }
        if let url = URL(string: target), let scheme = url.scheme, !scheme.isEmpty, !target.hasPrefix("/") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (target as NSString).expandingTildeInPath))
        }
    }

    /// Starts one of the user's Shortcuts and does not wait for it.
    private static func runShortcut(named name: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shortcutsTool)
        process.arguments = ["run", name]
        do {
            try process.run()
        } catch {
            NSLog("WristFlow: could not run the Shortcut %@: %@", name, error.localizedDescription)
        }
    }

    /// The names of the user's Shortcuts, for choosing one. Empty when there are none or the
    /// tool is missing.
    nonisolated static func shortcutNames() async -> [String] {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }.value
    }

    /// Whether the last thing WristFlow told Wispr Flow was to start. Static because the
    /// performer is a value that gets copied, while Wispr Flow has a single dictation state.
    private static var wisprStarted = false

    static var wisprInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: wisprBundleID) != nil
    }

    func isAvailable(_ kind: ActionKind) -> Bool {
        switch kind {
        case .wisprToggle, .wisprCancel:
            Self.wisprInstalled
        case .missionControl:
            FileManager.default.fileExists(atPath: Self.missionControlURL.path)
        case .runShortcut:
            FileManager.default.isExecutableFile(atPath: Self.shortcutsTool)
        case .none, .spaceLeft, .spaceRight, .previousTab, .nextTab, .pressReturn, .shortcut, .open, .custom:
            true
        }
    }

    func perform(_ binding: ActionBinding) {
        switch binding.kind {
        case .none:
            break
        case .wisprToggle:
            Self.toggleWispr()
        case .wisprCancel:
            Self.cancelWispr()
        case .spaceLeft:
            Self.post(keyCode: CGKeyCode(kVK_LeftArrow), flags: .maskControl)
        case .spaceRight:
            Self.post(keyCode: CGKeyCode(kVK_RightArrow), flags: .maskControl)
        case .missionControl:
            Self.showMissionControl()
        case .previousTab:
            Self.post(keyCode: CGKeyCode(kVK_Tab), flags: [.maskControl, .maskShift])
        case .nextTab:
            Self.post(keyCode: CGKeyCode(kVK_Tab), flags: .maskControl)
        case .pressReturn:
            Self.post(keyCode: CGKeyCode(kVK_Return), flags: [])
        case .shortcut:
            if let combo = binding.combo {
                Self.post(keyCode: CGKeyCode(combo.keyCode), flags: CGEventFlags(rawValue: combo.modifiers))
            }
        case .open:
            Self.open(binding.target)
        case .runShortcut:
            Self.runShortcut(named: binding.target)
        case .custom:
            // The model breaks the user's own actions into their steps before they get here.
            break
        }
    }

    /// Wispr Flow has deep links for hands-free dictation. Using them leaves its own Fn
    /// shortcuts alone. It ignores "start" while it is dictating and "stop" while it is idle,
    /// so WristFlow has to remember which one comes next.
    private static func toggleWispr() {
        // If no microphone is open anywhere, dictation cannot be running, whatever we remember
        // (it was stopped from the keyboard, for instance).
        if wisprStarted, !AudioState.anyInputRunning() { wisprStarted = false }
        let link = wisprStarted ? "wispr-flow://stop-hands-free" : "wispr-flow://start-hands-free"
        wisprStarted.toggle()
        guard let url = URL(string: link) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { NSLog("WristFlow: could not reach Wispr Flow: %@", error.localizedDescription) }
        }
    }

    /// Wispr Flow has no deep link for throwing a dictation away, but it has a "dismiss"
    /// shortcut (Escape unless the user changed it), so that key is pressed for the user.
    private static func cancelWispr() {
        // Only while something is recording: at any other time the key would land in
        // whatever app is in front and close a dialog or leave full screen there.
        guard AudioState.anyInputRunning() else { return }
        wisprStarted = false
        let key = wisprDismissKey() ?? (CGKeyCode(kVK_Escape), [])
        post(keyCode: key.keyCode, flags: key.flags)
    }

    /// The key Wispr Flow's settings give to "dismiss", written there as key codes joined by "+".
    private static func wisprDismissKey() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let file = support.appendingPathComponent("Wispr Flow/config.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = root["prefs"] as? [String: Any],
              let user = prefs["user"] as? [String: Any],
              let shortcuts = user["shortcuts"] as? [String: String],
              let keys = shortcuts.first(where: { $0.value == "dismiss" })?.key else { return nil }

        let modifiers: [Int: CGEventFlags] = [
            kVK_Command: .maskCommand, kVK_RightCommand: .maskCommand,
            kVK_Shift: .maskShift, kVK_RightShift: .maskShift,
            kVK_Option: .maskAlternate, kVK_RightOption: .maskAlternate,
            kVK_Control: .maskControl, kVK_RightControl: .maskControl,
            kVK_Function: .maskSecondaryFn,
        ]
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        for part in keys.split(separator: "+") {
            guard let code = Int(part) else { return nil }
            if let flag = modifiers[code] {
                flags.insert(flag)
            } else {
                keyCode = CGKeyCode(code)
            }
        }
        return keyCode.map { ($0, flags) }
    }

    /// Launching the system's own launcher app works whatever shortcut the user gave Mission
    /// Control, including none at all.
    private static func showMissionControl() {
        NSWorkspace.shared.openApplication(at: missionControlURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("WristFlow: could not open Mission Control: %@", error.localizedDescription) }
        }
    }

    static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        var flags = flags
        // Real arrow keys carry these two flags, and Mission Control only accepts
        // Control-arrow as "move a Space" when they are present.
        if (kVK_LeftArrow...kVK_UpArrow).contains(Int(keyCode)) {
            flags.formUnion([.maskSecondaryFn, .maskNumericPad])
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        InputActivity.noteOwnPost()
    }
}

/// Tells what the user's hands are doing on the keyboard, mouse and trackpad, so that gestures
/// and gaze never act on top of typing, clicking or pointing. Safe from any thread.
enum InputActivity {
    static let guardWindow = 0.35

    private static let pressTypes: [CGEventType] = [
        .keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown,
    ]
    /// Releases say the hand is still on the device, which matters to gaze but not to presses.
    private static let releaseTypes: [CGEventType] = [.keyUp, .rightMouseUp, .otherMouseUp]
    private static let pointerTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]

    /// How far apart the system's event clock and our own note of an event can be while still
    /// meaning the same event.
    private static let ownEventTolerance = 0.05

    private struct OwnEvents {
        var post = -Double.infinity
        var pointerMove = -Double.infinity
    }

    private static let ownEvents = Mutex(OwnEvents())

    /// Call right after posting key events, so they are not taken for the user typing.
    static func noteOwnPost() {
        let now = ProcessInfo.processInfo.systemUptime
        ownEvents.withLock { $0.post = now }
    }

    /// Call right after warping the cursor, so the jump is not taken for the user moving it.
    static func noteOwnPointerMove() {
        let now = ProcessInfo.processInfo.systemUptime
        ownEvents.withLock { $0.pointerMove = now }
    }

    /// True when the user pressed a key or a mouse button within `seconds`.
    static func recentUserInput(within seconds: TimeInterval = guardWindow) -> Bool {
        let own = ownEvents.withLock { $0 }
        return secondsSinceUserEvent(of: pressTypes, ownEventAt: own.post) < seconds
    }

    /// True when the user touched the keyboard, or moved, scrolled, dragged or clicked the
    /// pointer, within `seconds`.
    static func recentKeyboardOrPointerUse(within seconds: TimeInterval) -> Bool {
        let own = ownEvents.withLock { $0 }
        let sinceKeysOrButtons = secondsSinceUserEvent(of: pressTypes + releaseTypes, ownEventAt: own.post)
        let sincePointer = secondsSinceUserEvent(of: pointerTypes, ownEventAt: own.pointerMove)
        return min(sinceKeysOrButtons, sincePointer) < seconds
    }

    /// Seconds since the newest event of these types that WristFlow did not cause itself.
    /// The system only keeps the latest event per type, so a type whose latest event is ours
    /// says nothing about the user and is left out.
    private static func secondsSinceUserEvent(of types: [CGEventType], ownEventAt: TimeInterval) -> TimeInterval {
        let sinceOwnEvent = ProcessInfo.processInfo.systemUptime - ownEventAt
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .filter { abs(sinceOwnEvent - $0) > ownEventTolerance }
            .min() ?? .infinity
    }
}

enum AudioState {
    /// True when any device that can record is running, in any app.
    static func anyInputRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return true }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return true }

        for device in devices {
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var running = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &running, 0, nil, &valueSize, &value) == noErr, value != 0 {
                return true
            }
        }
        return false
    }
}

/// The Accessibility permission: needed to post key presses and to raise other apps' windows.
enum Accessibility {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to System Settings. The system only shows
    /// it while the permission is missing.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
