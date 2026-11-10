import Foundation

/// A hand shape that means something when held still.
public enum Pose: String, Codable, CaseIterable, Sendable {
    case openPalm
    case fist
    /// Thumb and index tips touching, the other three fingers extended.
    case ok
}

/// What the user can do to make WristFlow act.
public enum Trigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case palm
    case fist
    case ok
    case swipeLeft
    case swipeRight
    case swipeUp

    public var id: String { rawValue }

    public init(pose: Pose) {
        switch pose {
        case .openPalm: self = .palm
        case .fist: self = .fist
        case .ok: self = .ok
        }
    }

    public var title: String {
        switch self {
        case .palm: "Open palm"
        case .fist: "Fist"
        case .ok: "OK sign"
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .swipeUp: "Swipe up"
        }
    }

    public var hint: String {
        switch self {
        case .palm: "Show your open hand to the camera and hold it still."
        case .fist: "Show a closed fist and hold it still."
        case .ok: "Touch thumb and index finger, other fingers up, and hold."
        case .swipeLeft: "With your hand open, flick it to your left from the wrist."
        case .swipeRight: "With your hand open, flick it to your right from the wrist."
        case .swipeUp: "With your hand open, flick it upwards from the wrist."
        }
    }
}

/// What WristFlow can do in response. The names are the same on every platform; how each one
/// is carried out is up to the platform's `ActionPerforming`.
public enum ActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case wisprToggle
    case spaceLeft
    case spaceRight
    case missionControl
    case previousTab
    case nextTab
    case shortcut

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Do nothing"
        case .wisprToggle: "Wispr Flow: start / stop dictation"
        case .spaceLeft: "Move one desktop left"
        case .spaceRight: "Move one desktop right"
        case .missionControl: "Show all windows"
        case .previousTab: "Previous tab"
        case .nextTab: "Next tab"
        case .shortcut: "Custom shortcut"
        }
    }
}

/// A recorded key combination. The numbers are the platform's own key code and modifier bits,
/// so a combination recorded on one system is not valid on another.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    /// How to show it, e.g. "⌃⌥T".
    public var label: String

    public init(keyCode: UInt16, modifiers: UInt64, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

public struct ActionBinding: Codable, Hashable, Sendable {
    public var kind: ActionKind
    public var combo: KeyCombo?

    public init(kind: ActionKind, combo: KeyCombo? = nil) {
        self.kind = kind
        self.combo = combo
    }

    public static let none = ActionBinding(kind: .none)

    public var summary: String {
        if kind == .shortcut { return combo?.label ?? "No shortcut set" }
        return kind.title
    }
}

/// Everything the user can configure. Saved as one JSON file; keys missing from an older file
/// take their defaults.
public struct AppConfig: Codable, Equatable, Sendable {
    public var enabled = true
    /// `Trigger.rawValue` to what it does.
    public var bindings: [String: ActionBinding] = AppConfig.defaultBindings
    /// Seconds a pose has to be held still before it counts.
    public var holdTime = 0.4
    public var gazeFocusEnabled = true
    /// Seconds of looking at another display before focus moves there.
    public var gazeDwell = 0.5
    /// Platform identifier of the chosen camera; nil picks the built-in one.
    public var cameraID: String?
    public var showsHUD = true
    public var playsSound = false

    public init() {}

    public static let defaultBindings: [String: ActionBinding] = [
        Trigger.palm.rawValue: ActionBinding(kind: .wisprToggle),
        Trigger.fist.rawValue: ActionBinding(kind: .previousTab),
        Trigger.ok.rawValue: ActionBinding(kind: .nextTab),
        Trigger.swipeLeft.rawValue: ActionBinding(kind: .spaceLeft),
        Trigger.swipeRight.rawValue: ActionBinding(kind: .spaceRight),
        Trigger.swipeUp.rawValue: ActionBinding(kind: .missionControl),
    ]

    public func binding(for trigger: Trigger) -> ActionBinding {
        bindings[trigger.rawValue] ?? .none
    }

    public mutating func setBinding(_ binding: ActionBinding, for trigger: Trigger) {
        bindings[trigger.rawValue] = binding
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        bindings = try values.decodeIfPresent([String: ActionBinding].self, forKey: .bindings) ?? defaults.bindings
        holdTime = try values.decodeIfPresent(Double.self, forKey: .holdTime) ?? defaults.holdTime
        gazeFocusEnabled = try values.decodeIfPresent(Bool.self, forKey: .gazeFocusEnabled) ?? defaults.gazeFocusEnabled
        gazeDwell = try values.decodeIfPresent(Double.self, forKey: .gazeDwell) ?? defaults.gazeDwell
        cameraID = try values.decodeIfPresent(String.self, forKey: .cameraID)
        showsHUD = try values.decodeIfPresent(Bool.self, forKey: .showsHUD) ?? defaults.showsHUD
        playsSound = try values.decodeIfPresent(Bool.self, forKey: .playsSound) ?? defaults.playsSound
    }
}
