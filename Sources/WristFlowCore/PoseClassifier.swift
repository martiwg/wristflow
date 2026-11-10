import Foundation

/// What a single finger is doing, as far as flat landmarks can tell.
public enum FingerState: Sendable {
    case extended
    case curled
    /// Half bent, or its joints were not seen well enough to say.
    case unclear
}

/// The numbers a hand shape is judged by. The factory values were set on recordings of one
/// person's hands (see Fixtures); a personal calibration replaces them with values that sit
/// between that person's own curled and extended fingers.
public struct PoseProfile: Codable, Equatable, Sendable {
    /// Reach, in palm sizes, from which a finger counts as extended, indexed by
    /// `Finger.rawValue`. The thumb's entry is not used. Recorded extended fingers reach 0.64
    /// and more.
    public var extendedReach: [Double]
    /// Reach, in palm sizes, up to which a finger counts as curled, indexed by
    /// `Finger.rawValue`. A finger folded towards the camera keeps a little reach in the flat
    /// image: recorded ones go up to 0.22.
    public var curledReach: [Double]
    /// Knuckle-to-tip distance over the drawn length of the finger (0...1) an extended finger
    /// needs; 0.9 allows a bend of about 50 degrees at one joint.
    public var minStraightness: Double
    /// How far out to the side of the index knuckle the thumb tip must be, in palm sizes
    /// measured along the knuckle line, for the thumb to count as extended. Recorded open
    /// palms and thumbs up are at 0.48 and more.
    public var thumbOutOffset: Double
    /// How far out to the side the thumb tip may be and still count as folded in. Recorded
    /// four-finger hands have it 0.09 to 0.25 inside the knuckle line; a fist about 0.2 outside,
    /// which is neither.
    public var thumbInOffset: Double
    /// Base-to-tip distance over the drawn length of the thumb (0...1) an extended thumb needs.
    public var minThumbStraightness: Double
    /// How far from straight up, in degrees, the thumb may point in a thumbs up.
    public var thumbsUpTilt: Double
    /// Distance between thumb tip and index tip, in palm sizes, under which they touch. Still
    /// the value chosen on a synthetic skeleton.
    public var pinchDistance: Double
    /// Smallest turn of the knuckle line against the palm axis (0 edge-on, about 1 flat to the camera) at which a side is called.
    public var minFacingTurn: Double

    public static let factory = PoseProfile(
        extendedReach: Array(repeating: 0.5, count: Finger.allCases.count),
        curledReach: Array(repeating: 0.3, count: Finger.allCases.count),
        minStraightness: 0.9,
        thumbOutOffset: 0.3,
        thumbInOffset: 0.05,
        minThumbStraightness: 0.85,
        thumbsUpTilt: 50,
        pinchDistance: 0.3,
        minFacingTurn: 0.3
    )

    public init(
        extendedReach: [Double], curledReach: [Double], minStraightness: Double, thumbOutOffset: Double,
        thumbInOffset: Double, minThumbStraightness: Double, thumbsUpTilt: Double, pinchDistance: Double,
        minFacingTurn: Double
    ) {
        precondition(extendedReach.count == Finger.allCases.count && curledReach.count == Finger.allCases.count)
        self.extendedReach = extendedReach
        self.curledReach = curledReach
        self.minStraightness = minStraightness
        self.thumbOutOffset = thumbOutOffset
        self.thumbInOffset = thumbInOffset
        self.minThumbStraightness = minThumbStraightness
        self.thumbsUpTilt = thumbsUpTilt
        self.pinchDistance = pinchDistance
        self.minFacingTurn = minFacingTurn
    }
}

/// What can be measured on one hand before any threshold is applied. A value is nil when the
/// joints it needs were not seen well enough.
public struct HandMeasurements: Equatable, Sendable {
    /// How much farther from the wrist each fingertip is than its own knuckle, in palm sizes,
    /// indexed by `Finger.rawValue`. Always nil for the thumb, which is judged by `thumbOutwards`.
    public var reach: [Double?]
    /// Base-to-tip distance over the drawn length (0...1), indexed by `Finger.rawValue`.
    public var straightness: [Double?]
    /// How far out to the side of the index knuckle the thumb tip is, along the knuckle line,
    /// in palm sizes; negative when it is in over the palm.
    public var thumbOutwards: Double?
    /// Distance between thumb tip and index tip, in palm sizes.
    public var pinch: Double?
    /// Turn of the knuckle line against the palm axis: about ±0.7 to ±0.9 for a hand flat to
    /// the camera, near 0 edge-on. Its sign says which side shows, depending on the hand.
    public var turn: Double?
    /// How far from straight up the thumb points in the image, in degrees.
    public var thumbTilt: Double?
}

/// Reads a static hand shape from one set of landmarks.
///
/// Only distances between joints of the same hand are used, each divided by the palm size, so
/// the result does not change with the distance to the camera, with rotation in the image
/// plane, or between a left and a right hand.
///
/// Why distances rather than joint angles alone: the landmarks are flat, and a finger that
/// curls towards the camera does not visibly bend, it gets shorter and then points back at
/// the wrist. So each finger is measured by its *reach*: how much farther from the wrist the
/// tip is than its own knuckle. Reach is large for a straight finger, about zero for a
/// half-closed one and negative in a fist. The joint angles are still used, folded into one
/// *straightness* number (knuckle-to-tip distance over the length of the finger as drawn),
/// because a hand seen edge-on can hook a finger without losing reach.
public enum PoseClassifier {
    /// Joints the detector reports below this confidence (0...1) are not believed.
    static let minJointConfidence: Float = 0.3

    /// One row per pose. The first row a hand satisfies wins, so a shape that is a special
    /// case of another has to come first.
    private struct Rule {
        let pose: Pose
        /// The state each listed finger must be in; fingers not listed are free.
        let fingers: [Finger: FingerState]
        /// Whether thumb and index tips must touch (true), must not (false) or are free (nil).
        var pinched: Bool?
        /// The thumb must also point up.
        var thumbUp = false
    }

    private static let rules: [Rule] = [
        Rule(pose: .ok, fingers: [.middle: .extended, .ring: .extended, .little: .extended], pinched: true),
        Rule(
            pose: .openPalm,
            fingers: [.thumb: .extended, .index: .extended, .middle: .extended, .ring: .extended, .little: .extended],
            pinched: false
        ),
        // Five fingers is the open palm above; with the thumb folded in it is four.
        Rule(
            pose: .four,
            fingers: [.thumb: .curled, .index: .extended, .middle: .extended, .ring: .extended, .little: .extended]
        ),
        // The thumb is free in the counts below: people hold the closed fingers down with it,
        // tuck it in or leave it out, and mean the same number.
        Rule(pose: .three, fingers: [.index: .extended, .middle: .extended, .ring: .extended, .little: .curled]),
        Rule(pose: .two, fingers: [.index: .extended, .middle: .extended, .ring: .curled, .little: .curled]),
        Rule(pose: .one, fingers: [.index: .extended, .middle: .curled, .ring: .curled, .little: .curled]),
        Rule(
            pose: .thumbsUp,
            fingers: [.thumb: .extended, .index: .curled, .middle: .curled, .ring: .curled, .little: .curled],
            thumbUp: true
        ),
        Rule(pose: .fist, fingers: [.index: .curled, .middle: .curled, .ring: .curled, .little: .curled]),
    ]

    /// What each finger must be doing in a built-in pose, for teaching it and for calibrating
    /// on it; fingers not listed are free. The back of the hand asks for the same as the palm.
    public static func fingers(in pose: Pose) -> [Finger: FingerState] {
        let shown = pose == .backOfHand ? Pose.openPalm : pose
        return rules.first { $0.pose == shown }?.fingers ?? [:]
    }

    public static func fingerStates(_ hand: Hand, profile: PoseProfile = .factory) -> [Finger: FingerState] {
        fingerStates(measure(hand), profile: profile)
    }

    public static func fingerStates(_ measured: HandMeasurements, profile: PoseProfile = .factory) -> [Finger: FingerState] {
        var states: [Finger: FingerState] = [:]
        for finger in Finger.allCases {
            states[finger] = state(of: finger, measured, profile: profile)
        }
        return states
    }

    /// The built-in pose the hand shows, or nil when it shows none of them.
    public static func classify(_ hand: Hand, profile: PoseProfile = .factory) -> Pose? {
        classify(measure(hand), handedness: hand.handedness, profile: profile)
    }

    /// The built-in pose a measured hand shows; `handedness` is what tells palm from back.
    public static func classify(_ measured: HandMeasurements, handedness: Handedness?, profile: PoseProfile = .factory) -> Pose? {
        let states = fingerStates(measured, profile: profile)
        let pinched = measured.pinch.map { $0 < profile.pinchDistance }
        let match = rules.first { rule in
            if let wanted = rule.pinched, wanted != pinched { return false }
            guard rule.fingers.allSatisfy({ states[$0.key] == $0.value }) else { return false }
            if rule.thumbUp { return measured.thumbTilt.map { $0 <= profile.thumbsUpTilt } ?? false }
            return true
        }
        guard match?.pose == .openPalm, let handedness else { return match?.pose }
        // An open hand seen edge-on shows neither side, so it is no pose at all.
        guard let palmFacing = palmFacesCamera(measured, handedness: handedness, profile: profile) else { return nil }
        return palmFacing ? .openPalm : .backOfHand
    }

    /// Whether the palm, rather than the back of the hand, is towards the camera; nil when the
    /// hand is edge-on or it is not known which hand it is.
    ///
    /// The knuckles run from index to little finger one way round on a palm and the other way
    /// round on the back, and which is which depends on the hand. Measured on recordings of
    /// both hands, the turn is about ±0.7 to ±0.9 for a hand held flat to the camera.
    public static func palmFacesCamera(_ hand: Hand, profile: PoseProfile = .factory) -> Bool? {
        guard let handedness = hand.handedness else { return nil }
        return palmFacesCamera(measure(hand), handedness: handedness, profile: profile)
    }

    public static func palmFacesCamera(_ measured: HandMeasurements, handedness: Handedness, profile: PoseProfile = .factory) -> Bool? {
        guard let turn = measured.turn, abs(turn) >= profile.minFacingTurn else { return nil }
        return (turn > 0) == (handedness == .right)
    }

    /// The joints the palm size is measured between; no finger can be judged without them.
    private static let yardstickJoints: [Joint] = [.wrist, .middleMCP]
    /// The joints the palm centre is the mean of.
    private static let palmJoints: [Joint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]

    /// Everything the classifier looks at, as plain numbers.
    public static func measure(_ hand: Hand) -> HandMeasurements {
        let count = Finger.allCases.count
        var measured = HandMeasurements(
            reach: Array(repeating: nil, count: count), straightness: Array(repeating: nil, count: count)
        )
        let palm = hand.palmSize
        guard palm > 0, palm.isFinite else { return measured }

        for finger in Finger.allCases {
            let needed = finger.joints + (finger == .thumb ? palmJoints : yardstickJoints)
            guard isTrusted(needed, in: hand) else { continue }
            let points = finger.joints.map { hand[$0] }
            let drawn = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            measured.straightness[finger.rawValue] = drawn > 0 ? points[0].distance(to: points[3]) / drawn : 0

            if finger == .thumb {
                // The thumb folds sideways across the palm instead of towards the wrist. What
                // tells its states apart is which side of the index knuckle its tip is on, along
                // the line of the knuckles: out beyond the hand, or in over the palm. Distance
                // from the palm centre does not: a thumb folded over the palm and one held out
                // were recorded at 0.63 and 0.80.
                let knuckles = hand[.littleMCP] - hand[.indexMCP]
                guard knuckles.length > 0 else {
                    measured.straightness[finger.rawValue] = nil
                    continue
                }
                let fromIndex = hand[.thumbTip] - hand[.indexMCP]
                measured.thumbOutwards = -(fromIndex.x * knuckles.x + fromIndex.y * knuckles.y) / knuckles.length / palm
                let thumb = hand[.thumbTip] - hand[.thumbMCP]
                if thumb.length > 0 { measured.thumbTilt = atan2(abs(thumb.x), thumb.y) * 180 / .pi }
            } else {
                let wrist = hand[.wrist]
                measured.reach[finger.rawValue] = (wrist.distance(to: points[3]) - wrist.distance(to: points[0])) / palm
            }
        }

        if isTrusted([.wrist, .middleMCP, .thumbTip, .indexTip], in: hand) {
            measured.pinch = hand[.thumbTip].distance(to: hand[.indexTip]) / palm
        }
        if isTrusted([.wrist, .indexMCP, .middleMCP, .littleMCP], in: hand) {
            let across = hand[.littleMCP] - hand[.indexMCP]
            let along = hand[.middleMCP] - hand[.wrist]
            measured.turn = (across.x * along.y - across.y * along.x) / (palm * palm)
        }
        return measured
    }

    private static func state(of finger: Finger, _ measured: HandMeasurements, profile: PoseProfile) -> FingerState {
        guard let straightness = measured.straightness[finger.rawValue] else { return .unclear }
        if finger == .thumb {
            guard let outwards = measured.thumbOutwards else { return .unclear }
            if outwards <= profile.thumbInOffset { return .curled }
            if outwards >= profile.thumbOutOffset, straightness >= profile.minThumbStraightness { return .extended }
            return .unclear
        }
        guard let reach = measured.reach[finger.rawValue] else { return .unclear }
        if reach <= profile.curledReach[finger.rawValue] { return .curled }
        if reach >= profile.extendedReach[finger.rawValue], straightness >= profile.minStraightness { return .extended }
        return .unclear
    }

    private static func isTrusted(_ joints: [Joint], in hand: Hand) -> Bool {
        joints.allSatisfy { hand.confidence(of: $0) >= minJointConfidence }
    }
}
