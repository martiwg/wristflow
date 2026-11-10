import Foundation

/// What a single finger is doing, as far as flat landmarks can tell.
public enum FingerState: Sendable {
    case extended
    case curled
    /// Half bent, or its joints were not seen well enough to say.
    case unclear
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
    // The numbers below were chosen on a synthetic skeleton; they need checking against
    // recordings of real hands.

    /// Joints the detector reports below this confidence (0...1) are not believed.
    static let minJointConfidence: Float = 0.3
    /// Reach, in palm sizes, from which a finger counts as extended.
    static let extendedReach = 0.45
    /// Reach, in palm sizes, up to which a finger counts as curled: the tip is no farther
    /// from the wrist than its knuckle.
    static let curledReach = 0.0
    /// Knuckle-to-tip distance over the drawn length of the finger (0...1) an extended finger
    /// needs; 0.9 allows a bend of about 50 degrees at one joint.
    static let minStraightness = 0.9
    /// Distance from the thumb tip to the palm centre, in palm sizes, from which the thumb
    /// counts as extended: the tip is clear of the palm.
    static let thumbExtendedClearance = 0.6
    /// Distance from the thumb tip to the palm centre, in palm sizes, up to which the thumb
    /// counts as curled: the tip lies over the palm.
    static let thumbCurledClearance = 0.4
    /// Distance between thumb tip and index tip, in palm sizes, under which they touch.
    static let pinchDistance = 0.3

    /// One row per pose. The first row a hand satisfies wins, so a shape that is a special
    /// case of another has to come first.
    private struct Rule {
        let pose: Pose
        /// The state each listed finger must be in; fingers not listed are free.
        let fingers: [Finger: FingerState]
        /// Whether thumb and index tips must touch (true), must not (false) or are free (nil).
        let pinched: Bool?
    }

    private static let rules: [Rule] = [
        Rule(pose: .ok, fingers: [.middle: .extended, .ring: .extended, .little: .extended], pinched: true),
        Rule(
            pose: .openPalm,
            fingers: [.thumb: .extended, .index: .extended, .middle: .extended, .ring: .extended, .little: .extended],
            pinched: false
        ),
        Rule(pose: .fist, fingers: [.index: .curled, .middle: .curled, .ring: .curled, .little: .curled], pinched: nil),
    ]

    public static func fingerStates(_ hand: Hand) -> [Finger: FingerState] {
        var states: [Finger: FingerState] = [:]
        for finger in Finger.allCases {
            states[finger] = state(of: finger, in: hand)
        }
        return states
    }

    /// The pose the hand shows, or nil when it shows none of them.
    public static func classify(_ hand: Hand) -> Pose? {
        let states = fingerStates(hand)
        let pinched = isPinched(hand)
        let match = rules.first { rule in
            if let wanted = rule.pinched, wanted != pinched { return false }
            return rule.fingers.allSatisfy { states[$0.key] == $0.value }
        }
        return match?.pose
    }

    /// Whether thumb and index tips touch; nil when either tip was not seen well enough.
    static func isPinched(_ hand: Hand) -> Bool? {
        let palm = hand.palmSize
        guard palm > 0, isTrusted([.wrist, .middleMCP, .thumbTip, .indexTip], in: hand) else { return nil }
        return hand[.thumbTip].distance(to: hand[.indexTip]) / palm < pinchDistance
    }

    /// The joints the palm size is measured between; no finger can be judged without them.
    private static let yardstickJoints: [Joint] = [.wrist, .middleMCP]
    /// The joints the palm centre is the mean of.
    private static let palmJoints: [Joint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]

    private static func state(of finger: Finger, in hand: Hand) -> FingerState {
        let palm = hand.palmSize
        let needed = finger.joints + (finger == .thumb ? palmJoints : yardstickJoints)
        guard palm > 0, palm.isFinite, isTrusted(needed, in: hand) else { return .unclear }

        if finger == .thumb {
            // The thumb folds sideways across the palm instead of towards the wrist, so what
            // tells its states apart is how far its tip is from the middle of the palm.
            let clearance = hand[.thumbTip].distance(to: hand.palmCenter) / palm
            if clearance >= thumbExtendedClearance { return .extended }
            if clearance <= thumbCurledClearance { return .curled }
            return .unclear
        }

        let points = finger.joints.map { hand[$0] }
        let wrist = hand[.wrist]
        let reach = (wrist.distance(to: points[3]) - wrist.distance(to: points[0])) / palm
        if reach <= curledReach { return .curled }

        let drawnLength = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        let straightness = drawnLength > 0 ? points[0].distance(to: points[3]) / drawnLength : 0
        if reach >= extendedReach, straightness >= minStraightness { return .extended }
        return .unclear
    }

    private static func isTrusted(_ joints: [Joint], in hand: Hand) -> Bool {
        joints.allSatisfy { hand.confidence(of: $0) >= minJointConfidence }
    }
}
