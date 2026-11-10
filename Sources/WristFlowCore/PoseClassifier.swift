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
    // The finger and thumb numbers below were set on recordings of real hands (see Fixtures);
    // the pinch distance is still the one chosen on a synthetic skeleton.

    /// Joints the detector reports below this confidence (0...1) are not believed.
    static let minJointConfidence: Float = 0.3
    /// Reach, in palm sizes, from which a finger counts as extended. Recorded extended fingers
    /// reach 0.64 and more.
    static let extendedReach = 0.5
    /// Reach, in palm sizes, up to which a finger counts as curled. A finger folded towards
    /// the camera keeps a little reach in the flat image: recorded ones go up to 0.22.
    static let curledReach = 0.3
    /// Knuckle-to-tip distance over the drawn length of the finger (0...1) an extended finger
    /// needs; 0.9 allows a bend of about 50 degrees at one joint.
    static let minStraightness = 0.9
    /// How far out to the side of the index knuckle the thumb tip must be, in palm sizes
    /// measured along the knuckle line, for the thumb to count as extended. Recorded open
    /// palms and thumbs up are at 0.48 and more.
    static let thumbOutOffset = 0.3
    /// How far out to the side the thumb tip may be and still count as folded in. Recorded
    /// four-finger hands have it 0.09 to 0.25 inside the knuckle line; a fist about 0.2 outside,
    /// which is neither.
    static let thumbInOffset = 0.05
    /// Base-to-tip distance over the drawn length of the thumb (0...1) an extended thumb needs.
    static let minThumbStraightness = 0.85
    /// How far from straight up, in degrees, the thumb may point in a thumbs up.
    static let thumbsUpTilt = 50.0
    /// Distance between thumb tip and index tip, in palm sizes, under which they touch.
    static let pinchDistance = 0.3
    /// Smallest turn of the knuckle line against the palm axis (0 edge-on, about 1 flat to the camera) at which a side is called.
    static let minFacingTurn = 0.3

    /// One row per pose. The first row a hand satisfies wins, so a shape that is a special
    /// case of another has to come first.
    private struct Rule {
        let pose: Pose
        /// The state each listed finger must be in; fingers not listed are free.
        let fingers: [Finger: FingerState]
        /// Whether thumb and index tips must touch (true), must not (false) or are free (nil).
        var pinched: Bool?
        /// Something the hand must also satisfy that finger states cannot express.
        var also: (@Sendable (Hand) -> Bool)?
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
            also: { thumbPointsUp($0) }
        ),
        Rule(pose: .fist, fingers: [.index: .curled, .middle: .curled, .ring: .curled, .little: .curled]),
    ]

    /// Whether the thumb points up in the image, give or take `thumbsUpTilt`.
    private static func thumbPointsUp(_ hand: Hand) -> Bool {
        let thumb = hand[.thumbTip] - hand[.thumbMCP]
        guard thumb.length > 0 else { return false }
        let fromUp = atan2(abs(thumb.x), thumb.y) * 180 / .pi
        return fromUp <= thumbsUpTilt
    }

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
            guard rule.fingers.allSatisfy({ states[$0.key] == $0.value }) else { return false }
            return rule.also?(hand) ?? true
        }
        guard match?.pose == .openPalm, hand.handedness != nil else { return match?.pose }
        // An open hand seen edge-on shows neither side, so it is no pose at all.
        guard let palmFacing = palmFacesCamera(hand) else { return nil }
        return palmFacing ? .openPalm : .backOfHand
    }

    /// Whether the palm, rather than the back of the hand, is towards the camera; nil when the
    /// hand is edge-on or it is not known which hand it is.
    ///
    /// The knuckles run from index to little finger one way round on a palm and the other way
    /// round on the back, and which is which depends on the hand. Measured on recordings of
    /// both hands, the turn below is about ±0.7 to ±0.9 for a hand held flat to the camera.
    public static func palmFacesCamera(_ hand: Hand) -> Bool? {
        let palm = hand.palmSize
        guard let handedness = hand.handedness, palm > 0,
              isTrusted([.wrist, .indexMCP, .middleMCP, .littleMCP], in: hand) else { return nil }
        let across = hand[.littleMCP] - hand[.indexMCP]
        let along = hand[.middleMCP] - hand[.wrist]
        let turn = (across.x * along.y - across.y * along.x) / (palm * palm)
        guard abs(turn) >= minFacingTurn else { return nil }
        return (turn > 0) == (handedness == .right)
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
            // The thumb folds sideways across the palm instead of towards the wrist. What
            // tells its states apart is which side of the index knuckle its tip is on, along
            // the line of the knuckles: out beyond the hand, or in over the palm. Distance
            // from the palm centre does not: a thumb folded over the palm and one held out
            // were recorded at 0.63 and 0.80.
            let knuckles = hand[.littleMCP] - hand[.indexMCP]
            guard knuckles.length > 0 else { return .unclear }
            let fromIndex = hand[.thumbTip] - hand[.indexMCP]
            let outwards = -(fromIndex.x * knuckles.x + fromIndex.y * knuckles.y) / knuckles.length / palm
            if outwards <= thumbInOffset { return .curled }
            let bones = finger.joints.map { hand[$0] }
            let drawn = zip(bones, bones.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            let straightness = drawn > 0 ? bones[0].distance(to: bones[3]) / drawn : 0
            if outwards >= thumbOutOffset, straightness >= minThumbStraightness { return .extended }
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
