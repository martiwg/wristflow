import Foundation

/// A point in the camera image, seen from the user's side (as in a mirror).
///
/// Both axes use the image height as their unit, so distances and angles are not distorted:
/// `y` runs from 0 (bottom) to 1 (top) and `x` from 0 (the user's left) to the aspect ratio
/// (the user's right). Moving the hand to your right increases `x`; raising it increases `y`.
public struct Point2: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2(x: 0, y: 0)

    public static func + (a: Point2, b: Point2) -> Point2 { Point2(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Point2, b: Point2) -> Point2 { Point2(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Point2, k: Double) -> Point2 { Point2(x: a.x * k, y: a.y * k) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Point2) -> Double { (self - other).length }
}

/// The 21 hand joints, in the order MediaPipe numbers them. Apple Vision reports the same
/// skeleton, so every platform fills a `Hand` the same way.
public enum Joint: Int, CaseIterable, Codable, Sendable {
    case wrist = 0
    case thumbCMC, thumbMCP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

public enum Finger: Int, CaseIterable, Codable, Sendable {
    case thumb, index, middle, ring, little

    /// The four joints of the finger, from the palm outwards.
    public var joints: [Joint] {
        let first = 1 + rawValue * 4
        return (first..<first + 4).compactMap(Joint.init(rawValue:))
    }

    public var tip: Joint { joints[3] }
}

public enum Handedness: String, Codable, Sendable {
    case left, right
}

/// One detected hand.
public struct Hand: Codable, Sendable {
    /// Which of the user's hands this is, when the detector can tell.
    public var handedness: Handedness?
    /// 21 points indexed by `Joint.rawValue`.
    public var points: [Point2]
    /// Detector confidence per joint, 0...1, indexed like `points`.
    public var confidences: [Float]

    public init(handedness: Handedness? = nil, points: [Point2], confidences: [Float]) {
        precondition(points.count == Joint.allCases.count && confidences.count == points.count)
        self.handedness = handedness
        self.points = points
        self.confidences = confidences
    }

    public subscript(joint: Joint) -> Point2 { points[joint.rawValue] }

    public func confidence(of joint: Joint) -> Float { confidences[joint.rawValue] }

    /// Mean confidence over all joints.
    public var confidence: Float { confidences.reduce(0, +) / Float(confidences.count) }

    /// Wrist to the base of the middle finger: the yardstick every hand measurement is
    /// divided by, so nothing depends on how far the hand is from the camera.
    public var palmSize: Double { self[.wrist].distance(to: self[.middleMCP]) }

    /// Middle of the palm (mean of the wrist and the four finger bases).
    public var palmCenter: Point2 {
        let joints: [Joint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let sum = joints.reduce(Point2.zero) { $0 + self[$1] }
        return sum * (1 / Double(joints.count))
    }
}

/// Every hand seen in one camera frame.
public struct HandFrame: Codable, Sendable {
    /// Seconds on a monotonic clock.
    public var time: Double
    public var hands: [Hand]

    public init(time: Double, hands: [Hand]) {
        self.time = time
        self.hands = hands
    }
}

/// The user's face in one camera frame.
public struct FaceFrame: Codable, Sendable {
    /// Seconds on the same clock as `HandFrame.time`.
    public var time: Double
    /// Head angles in radians, from the user's side: positive yaw turns towards the user's
    /// right, positive pitch looks up, positive roll tilts towards the user's right shoulder.
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Centre of the face box.
    public var center: Point2
    /// Height of the face box, in image heights.
    public var size: Double
    /// Where the pupils sit inside the eyes, averaged over both eyes: 0 is the middle of the
    /// eye, ±1 its corners (x) or lids (y). Nil when the eyes could not be read.
    public var pupilOffset: Point2?

    public init(time: Double, yaw: Double, pitch: Double, roll: Double, center: Point2, size: Double, pupilOffset: Point2?) {
        self.time = time
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.center = center
        self.size = size
        self.pupilOffset = pupilOffset
    }
}
