import Foundation

/// A gesture the user recorded: either a hand shape to hold or a movement to make.
public struct CustomGesture: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Set when the gesture is a held shape.
    public var shape: ShapeTemplate?
    /// Set when the gesture is a movement.
    public var movement: MovementTemplate?
    /// The `Trigger.key` of the built-in pose the recorded shape is also read as, when there
    /// is one: a shape recorded over two fingers, say. The engine uses it to keep one showing
    /// of the hand from counting as both.
    public var alsoReadAs: String?

    public init(id: String = UUID().uuidString, name: String, shape: ShapeTemplate, alsoReadAs: Pose? = nil) {
        self.id = id
        self.name = name
        self.shape = shape
        self.alsoReadAs = alsoReadAs.map { Trigger(pose: $0).key }
    }

    public init(id: String = UUID().uuidString, name: String, movement: MovementTemplate) {
        self.id = id
        self.name = name
        self.movement = movement
    }

    public var trigger: Trigger { .custom(id) }
}

/// Two hands each holding a pose at the same time.
public struct Combination: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// What the user's left hand shows. A pose: built in, or a recorded shape.
    public var left: Trigger
    /// What the user's right hand shows.
    public var right: Trigger
    /// Whether the hands may also be the other way round.
    public var eitherWay: Bool

    public init(id: String = UUID().uuidString, left: Trigger, right: Trigger, eitherWay: Bool = true) {
        self.id = id
        self.left = left
        self.right = right
        self.eitherWay = eitherWay
    }

    public var trigger: Trigger { .combination(id) }

    /// Whether these two poses, on these hands, are this combination.
    public func isMade(left shownLeft: Pose, right shownRight: Pose) -> Bool {
        let leftTrigger = Trigger(pose: shownLeft)
        let rightTrigger = Trigger(pose: shownRight)
        if leftTrigger == left, rightTrigger == right { return true }
        return eitherWay && leftTrigger == right && rightTrigger == left
    }

    /// Whether a pose is one of the two.
    public func involves(_ pose: Pose) -> Bool {
        let trigger = Trigger(pose: pose)
        return trigger == left || trigger == right
    }

    /// Whether some pair of hands would make both this combination and `other`.
    public func overlaps(_ other: Combination) -> Bool {
        let same = left == other.left && right == other.right
        let crossed = left == other.right && right == other.left
        return same || ((eitherWay || other.eitherWay) && crossed)
    }
}

/// Everything a user taught WristFlow: recorded gestures, combinations and the calibration to
/// their own hands. It belongs to one person, so it is stored with their account and never
/// shipped.
public struct GestureLibrary: Codable, Equatable, Sendable {
    public var customGestures: [CustomGesture] = []
    public var combinations: [Combination] = []
    public var calibration: PersonalCalibration?

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        customGestures = try values.decodeIfPresent([CustomGesture].self, forKey: .customGestures) ?? []
        combinations = try values.decodeIfPresent([Combination].self, forKey: .combinations) ?? []
        calibration = try values.decodeIfPresent(PersonalCalibration.self, forKey: .calibration)
    }

    // MARK: Looking things up

    public func gesture(_ id: String) -> CustomGesture? {
        customGestures.first { $0.id == id }
    }

    public func combination(_ id: String) -> Combination? {
        combinations.first { $0.id == id }
    }

    /// Recorded shapes, for reading poses.
    public var shapes: [(id: String, template: ShapeTemplate)] {
        customGestures.compactMap { gesture in gesture.shape.map { (gesture.id, $0) } }
    }

    /// Recorded movements.
    public var movements: [(id: String, template: MovementTemplate)] {
        customGestures.compactMap { gesture in gesture.movement.map { (gesture.id, $0) } }
    }

    /// Whether the trigger can still be made: built-in ones always can, the others only
    /// while what they refer to exists.
    public func contains(_ trigger: Trigger) -> Bool {
        switch trigger {
        case .custom(let id): gesture(id) != nil
        case .combination(let id): combination(id) != nil
        default: true
        }
    }

    /// The pose that fires a trigger when held, or nil when the trigger is a swipe, a
    /// movement, a combination or gone.
    public func pose(for trigger: Trigger) -> Pose? {
        if case .custom(let id) = trigger { return gesture(id)?.shape == nil ? nil : .custom(id) }
        return trigger.builtInPose
    }

    /// Everything one hand of a combination can be asked to show.
    public var poseTriggers: [Trigger] {
        Pose.builtIn.map(Trigger.init(pose:)) + customGestures.filter { $0.shape != nil }.map(\.trigger)
    }

    /// The name to show for a trigger.
    public func title(for trigger: Trigger) -> String {
        switch trigger {
        case .custom(let id):
            return gesture(id)?.name ?? trigger.title
        case .combination(let id):
            guard let combination = combination(id) else { return trigger.title }
            return "\(title(for: combination.left)) + \(title(for: combination.right))"
        default:
            return trigger.title
        }
    }

    /// The combination two poses make on these hands, if any.
    public func combination(left: Pose, right: Pose) -> Combination? {
        combinations.first { $0.isMade(left: left, right: right) }
    }

    /// Whether a pose is part of any combination.
    public func isCombined(_ pose: Pose) -> Bool {
        combinations.contains { $0.involves(pose) }
    }

    /// An existing combination the same hands would also make, which is why `candidate`
    /// cannot be added.
    public func clash(for candidate: Combination) -> Combination? {
        combinations.first { $0.id != candidate.id && $0.overlaps(candidate) }
    }

    /// The pose a hand shows: a shape the user recorded when it looks like one, otherwise
    /// one of the built-in poses, read with the user's own thresholds.
    public func read(_ hand: Hand) -> Pose? {
        let recorded = shapes
        if !recorded.isEmpty, let id = ShapeMatcher.match(hand, among: recorded) { return .custom(id) }
        return PoseClassifier.classify(hand, profile: profile)
    }

    // MARK: Changing it

    /// Removes a recorded gesture and the combinations that used it. Returns every trigger
    /// that no longer exists, so their bindings can be dropped.
    @discardableResult
    public mutating func removeGesture(_ id: String) -> [Trigger] {
        let trigger = Trigger.custom(id)
        let orphaned = combinations.filter { $0.left == trigger || $0.right == trigger }
        customGestures.removeAll { $0.id == id }
        combinations.removeAll { combination in orphaned.contains { $0.id == combination.id } }
        return [trigger] + orphaned.map(\.trigger)
    }

    @discardableResult
    public mutating func removeCombination(_ id: String) -> [Trigger] {
        combinations.removeAll { $0.id == id }
        return [.combination(id)]
    }

    // MARK: Calibration

    /// The thresholds hand shapes are read with: the person's own once calibrated.
    public var profile: PoseProfile { calibration?.profile ?? .factory }

    /// `config` with the values the calibration measured on this person put in.
    public func tuned(_ config: GestureConfig) -> GestureConfig {
        var tuned = config
        guard let calibration else { return tuned }
        if let present = calibration.presentRatio, let withdraw = calibration.withdrawRatio, withdraw <= present {
            tuned.presentRatio = present
            tuned.withdrawRatio = withdraw
        }
        if let travel = calibration.swipeTravel { tuned.swipeTravel = travel }
        return tuned
    }
}
