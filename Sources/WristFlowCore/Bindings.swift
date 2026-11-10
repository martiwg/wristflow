import Foundation

/// A hand shape that means something when held still.
public enum Pose: Hashable, Sendable {
    /// Open hand with the palm towards the camera.
    case openPalm
    /// Open hand with its back towards the camera.
    case backOfHand
    case fist
    /// Thumb and index tips touching, the other three fingers extended.
    case ok
    /// Index finger up, the others closed.
    case one
    /// Index and middle fingers up.
    case two
    /// Index, middle and ring fingers up.
    case three
    /// Four fingers up, thumb folded in. Five is the open palm.
    case four
    /// Fist with the thumb pointing up.
    case thumbsUp
    /// A shape the user recorded, by the id of its `CustomGesture`.
    case custom(String)

    /// The poses WristFlow knows without being taught.
    public static let builtIn: [Pose] = [.openPalm, .backOfHand, .fist, .ok, .one, .two, .three, .four, .thumbsUp]
}

/// What the user can do to make WristFlow act.
public enum Trigger: Hashable, Identifiable, Sendable {
    case palm
    case palmBack
    case fist
    case ok
    case oneFinger
    case twoFingers
    case threeFingers
    case fourFingers
    case thumbsUp
    case swipeLeft
    case swipeRight
    case swipeUp
    /// A gesture the user recorded, by the id of its `CustomGesture`.
    case custom(String)
    /// Two hands each holding a pose at the same time, by the id of the `Combination`.
    case combination(String)

    /// The gestures WristFlow knows without being taught, in the order they are listed.
    public static let builtIn: [Trigger] = [
        .palm, .palmBack, .fist, .ok, .oneFinger, .twoFingers, .threeFingers, .fourFingers, .thumbsUp,
        .swipeLeft, .swipeRight, .swipeUp,
    ]

    private static let customPrefix = "custom:"
    private static let combinationPrefix = "combo:"

    /// The name the trigger goes by in files: bindings are keyed by it.
    public var key: String {
        switch self {
        case .palm: "palm"
        case .palmBack: "palmBack"
        case .fist: "fist"
        case .ok: "ok"
        case .oneFinger: "oneFinger"
        case .twoFingers: "twoFingers"
        case .threeFingers: "threeFingers"
        case .fourFingers: "fourFingers"
        case .thumbsUp: "thumbsUp"
        case .swipeLeft: "swipeLeft"
        case .swipeRight: "swipeRight"
        case .swipeUp: "swipeUp"
        case .custom(let id): Self.customPrefix + id
        case .combination(let id): Self.combinationPrefix + id
        }
    }

    public init?(key: String) {
        if let builtIn = Self.builtIn.first(where: { $0.key == key }) {
            self = builtIn
        } else if key.hasPrefix(Self.customPrefix), key.count > Self.customPrefix.count {
            self = .custom(String(key.dropFirst(Self.customPrefix.count)))
        } else if key.hasPrefix(Self.combinationPrefix), key.count > Self.combinationPrefix.count {
            self = .combination(String(key.dropFirst(Self.combinationPrefix.count)))
        } else {
            return nil
        }
    }

    public var id: String { key }

    public init(pose: Pose) {
        switch pose {
        case .openPalm: self = .palm
        case .backOfHand: self = .palmBack
        case .fist: self = .fist
        case .ok: self = .ok
        case .one: self = .oneFinger
        case .two: self = .twoFingers
        case .three: self = .threeFingers
        case .four: self = .fourFingers
        case .thumbsUp: self = .thumbsUp
        case .custom(let id): self = .custom(id)
        }
    }

    /// The pose that fires this trigger when held, for the built-in ones that are poses.
    /// A recorded gesture may be a shape or a movement; `GestureLibrary.pose(for:)` knows.
    public var builtInPose: Pose? {
        Pose.builtIn.first { Trigger(pose: $0) == self }
    }

    /// What to call it. Recorded gestures and combinations are named by the user, which
    /// `GestureLibrary.title(for:)` looks up; this is what they are called without one.
    public var title: String {
        switch self {
        case .palm: "Open palm"
        case .palmBack: "Back of hand"
        case .fist: "Fist"
        case .ok: "OK sign"
        case .oneFinger: "One finger"
        case .twoFingers: "Two fingers"
        case .threeFingers: "Three fingers"
        case .fourFingers: "Four fingers"
        case .thumbsUp: "Thumbs up"
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .swipeUp: "Swipe up"
        case .custom: "My gesture"
        case .combination: "Combination"
        }
    }

    public var hint: String {
        switch self {
        case .palm: "Show the palm of your open hand to the camera and hold it still."
        case .palmBack: "Show the back of your open hand to the camera and hold it still."
        case .fist: "Show a closed fist and hold it still."
        case .ok: "Touch thumb and index finger, other fingers up, and hold."
        case .oneFinger: "Hold up your index finger."
        case .twoFingers: "Hold up your index and middle fingers."
        case .threeFingers: "Hold up your index, middle and ring fingers."
        case .fourFingers: "Hold up four fingers with your thumb folded in. Five fingers is the open palm."
        case .thumbsUp: "Make a fist with your thumb pointing up and hold it still."
        case .swipeLeft: "With your hand open, flick it to your left from the wrist."
        case .swipeRight: "With your hand open, flick it to your right from the wrist."
        case .swipeUp: "With your hand open, flick it upwards from the wrist."
        case .custom: "Make the gesture the way you recorded it."
        case .combination: "Hold one pose with each hand at the same time."
        }
    }
}

extension Trigger: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        guard let trigger = Trigger(key: key) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown trigger \(key)")
        }
        self = trigger
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

/// What WristFlow can do in response. The names are the same on every platform; how each one
/// is carried out is up to the platform's `ActionPerforming`.
public enum ActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case wisprToggle
    case wisprCancel
    case spaceLeft
    case spaceRight
    case missionControl
    case previousTab
    case nextTab
    case pressReturn
    case shortcut
    /// Opens an app, a file or a link; which one is the binding's `target`.
    case open
    /// Runs one of the user's automations by name (Shortcuts on macOS), given in `target`.
    case runShortcut

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Do nothing"
        case .wisprToggle: "Wispr Flow: start / stop dictation"
        case .wisprCancel: "Wispr Flow: discard dictation"
        case .spaceLeft: "Move one desktop left"
        case .spaceRight: "Move one desktop right"
        case .missionControl: "Show all windows"
        case .previousTab: "Previous tab"
        case .nextTab: "Next tab"
        case .pressReturn: "Press Return (Enter)"
        case .shortcut: "Custom shortcut"
        case .open: "Open an app, file or link"
        case .runShortcut: "Run a Shortcut"
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
    /// The keys to press, for `.shortcut`.
    public var combo: KeyCombo?
    /// What to open (a path or a link) for `.open`, or the automation's name for `.runShortcut`.
    public var target: String?

    public init(kind: ActionKind, combo: KeyCombo? = nil, target: String? = nil) {
        self.kind = kind
        self.combo = combo
        self.target = target
    }

    public static let none = ActionBinding(kind: .none)

    /// The same binding with another kind, keeping what was set up for the others so that
    /// switching back and forth in a list does not lose it.
    public func with(kind: ActionKind) -> ActionBinding {
        ActionBinding(kind: kind, combo: combo, target: kind == self.kind ? target : nil)
    }

    public var summary: String {
        switch kind {
        case .shortcut:
            return combo?.label ?? "No shortcut set"
        case .open:
            guard let target, !target.isEmpty else { return "Nothing to open set" }
            // A path or link is long; its last part is what tells them apart.
            let name = target.split(separator: "/").last.map(String.init) ?? target
            return "Open \(name.replacingOccurrences(of: ".app", with: ""))"
        case .runShortcut:
            guard let target, !target.isEmpty else { return "No Shortcut chosen" }
            return "Shortcut: \(target)"
        default:
            return kind.title
        }
    }
}

/// Everything the user can configure. Saved as one JSON file; keys missing from an older file
/// take their defaults.
public struct AppConfig: Codable, Equatable, Sendable {
    public var enabled = true
    /// `Trigger.key` to what it does.
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
        Trigger.palm.key: ActionBinding(kind: .wisprToggle),
        Trigger.palmBack.key: ActionBinding(kind: .wisprCancel),
        Trigger.fist.key: ActionBinding(kind: .previousTab),
        Trigger.ok.key: ActionBinding(kind: .nextTab),
        Trigger.thumbsUp.key: ActionBinding(kind: .pressReturn),
        Trigger.swipeLeft.key: ActionBinding(kind: .spaceLeft),
        Trigger.swipeRight.key: ActionBinding(kind: .spaceRight),
        Trigger.swipeUp.key: ActionBinding(kind: .missionControl),
    ]

    public func binding(for trigger: Trigger) -> ActionBinding {
        // A trigger added after the file was written gets its default until the user changes it.
        bindings[trigger.key] ?? Self.defaultBindings[trigger.key] ?? .none
    }

    public mutating func setBinding(_ binding: ActionBinding, for trigger: Trigger) {
        bindings[trigger.key] = binding
    }

    /// Forgets what a trigger did, for one that no longer exists.
    public mutating func removeBinding(for trigger: Trigger) {
        bindings[trigger.key] = nil
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
