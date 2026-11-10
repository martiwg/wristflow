import Foundation

// The three things a platform has to provide. Everything else is shared.

/// Watches the camera and reports where hands and the face are.
public protocol LandmarkSource: AnyObject {
    /// Called for every processed frame, also when no hand is visible (with an empty list).
    /// May be called on any thread.
    var onHands: (@Sendable (HandFrame) -> Void)? { get set }
    /// Called whenever a face was measured. May be called on any thread.
    var onFace: (@Sendable (FaceFrame) -> Void)? { get set }

    func start() throws
    func stop()
}

/// Carries out an action on this system.
public protocol ActionPerforming {
    /// False when the action cannot work here (for instance Wispr Flow is not installed).
    func isAvailable(_ kind: ActionKind) -> Bool
    func perform(_ binding: ActionBinding)
}

/// A screen the user can look at.
public struct DisplayInfo: Codable, Hashable, Identifiable, Sendable {
    /// Stable across restarts and reconnections.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Moves the user's focus to a display.
public protocol DisplayFocusing {
    /// The displays connected right now.
    var displays: [DisplayInfo] { get }
    /// The display the pointer is on.
    var currentDisplay: String? { get }
    /// Moves the pointer to the display and activates the window in front on it.
    /// Returns false when it chose not to (the user is busy with keyboard or mouse) or could not.
    @discardableResult
    func focus(display id: String) -> Bool
}
