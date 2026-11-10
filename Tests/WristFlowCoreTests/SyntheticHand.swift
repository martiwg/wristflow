import Foundation
@testable import WristFlowCore

/// A hand drawn from a simple skeleton, so tests can ask for any shape, place, size and tilt.
///
/// The skeleton is a right hand with its palm to the camera, measured in palm sizes: wrist at
/// the origin, middle knuckle at (0, 1), thumb on the -x side (a right hand as its owner sees
/// it in a mirror). A finger curls towards the camera, so in the image it gets shorter and
/// then points back at the wrist, which is how the landmarks of a real fist look in 2D.
struct SyntheticHand {
    /// 0 is straight, 1 fully closed. Fingers not listed are straight.
    var curls: [Finger: Double] = [:]
    /// 0 leaves thumb and index alone, 1 brings their tips together in front of the palm.
    var pinch = 0.0
    /// Where the palm centre lands in the image.
    var center = Point2(x: 0.8, y: 0.5)
    /// Palm size in image heights.
    var scale = 0.15
    /// Tilt in the image plane, in degrees, counter-clockwise.
    var rotation = 0.0
    var isLeft = false
    /// Largest random offset added to each coordinate, in palm sizes.
    var jitter = 0.0
    var seed: UInt64 = 0
    var confidence: Float = 0.9
    /// Fingers whose joints the detector is unsure about.
    var doubtfulFingers: Set<Finger> = []

    static let openPalm = SyntheticHand()
    static let fist = SyntheticHand(curls: [.thumb: 1, .index: 1, .middle: 1, .ring: 1, .little: 1])
    static let ok = SyntheticHand(pinch: 1)
    static let pointing = SyntheticHand(curls: [.thumb: 1, .middle: 1, .ring: 1, .little: 1])
    static let peace = SyntheticHand(curls: [.thumb: 1, .ring: 1, .little: 1])
    static let threeFingers = SyntheticHand(curls: [.thumb: 1, .little: 1])
    static let fourFingers = SyntheticHand(curls: [.thumb: 1])
    static let thumbsUp = SyntheticHand(curls: [.index: 1, .middle: 1, .ring: 1, .little: 1])
    static let halfClosed = SyntheticHand(curls: [.thumb: 0.5, .index: 0.5, .middle: 0.5, .ring: 0.5, .little: 0.5])

    static func shape(for pose: Pose) -> SyntheticHand {
        switch pose {
        case .openPalm: openPalm
        case .fist: fist
        case .ok: ok
        }
    }

    func at(_ center: Point2) -> SyntheticHand {
        var copy = self
        copy.center = center
        return copy
    }

    func scaled(_ scale: Double) -> SyntheticHand {
        var copy = self
        copy.scale = scale
        return copy
    }

    func hand() -> Hand {
        var local = [Point2.zero]
        local += thumbPoints()
        for finger in [Finger.index, .middle, .ring, .little] {
            local += fingerPoints(finger)
        }

        let palmJoints: [Joint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let palmCenter = palmJoints.reduce(Point2.zero) { $0 + local[$1.rawValue] } * (1 / Double(palmJoints.count))
        let angle = rotation * .pi / 180
        var random = SplitMix64(state: seed)

        let points = local.map { point -> Point2 in
            var p = point - palmCenter
            p = p + Point2(x: random.signedUnit() * jitter, y: random.signedUnit() * jitter)
            if isLeft { p.x = -p.x }
            let turned = Point2(x: p.x * cos(angle) - p.y * sin(angle), y: p.x * sin(angle) + p.y * cos(angle))
            return center + turned * scale
        }

        var confidences = [Float](repeating: confidence, count: points.count)
        for finger in doubtfulFingers {
            for joint in finger.joints { confidences[joint.rawValue] = 0.1 }
        }
        return Hand(handedness: isLeft ? .left : .right, points: points, confidences: confidences)
    }

    // MARK: Skeleton

    private struct Bones {
        /// The knuckle.
        let base: Point2
        /// Direction the straight finger points in, in degrees from straight up towards +x.
        let splay: Double
        /// Lengths of the three bones, from the knuckle outwards.
        let lengths: [Double]
    }

    private static let skeleton: [Finger: Bones] = [
        .index: Bones(base: Point2(x: -0.26, y: 0.95), splay: -10, lengths: [0.42, 0.26, 0.21]),
        .middle: Bones(base: Point2(x: 0, y: 1), splay: 0, lengths: [0.47, 0.30, 0.22]),
        .ring: Bones(base: Point2(x: 0.22, y: 0.94), splay: 9, lengths: [0.43, 0.28, 0.21]),
        .little: Bones(base: Point2(x: 0.41, y: 0.80), splay: 20, lengths: [0.33, 0.20, 0.19]),
    ]

    /// How far each joint of a finger bends at full curl, in degrees: knuckle, middle, last.
    private static let fullFlexion = [85.0, 105.0, 70.0]
    /// Where one palm size of depth towards the camera lands in the image. The camera never
    /// looks at a palm exactly square on, so a curled finger is not drawn on a perfect line.
    private static let depthSkew = Point2(x: 0.04, y: -0.03)

    private static let thumbBase = Point2(x: -0.30, y: 0.22)
    private static let thumbLengths = [0.40, 0.32, 0.27]
    /// Direction of the straight thumb, in degrees from straight up towards +x.
    private static let thumbSplay = -40.0
    /// How far each thumb bone swings across the palm at full curl, in degrees.
    private static let thumbSweep = [30.0, 100.0, 130.0]

    /// Where thumb and index tips meet in an OK sign, and the joints leading there.
    private static let pinchPoint = Point2(x: -0.50, y: 1.05)
    private static let pinchedThumb = [thumbBase, Point2(x: -0.52, y: 0.52), Point2(x: -0.62, y: 0.80), pinchPoint]
    private static let pinchedIndex = [
        Point2(x: -0.26, y: 0.95), Point2(x: -0.36, y: 1.27), Point2(x: -0.47, y: 1.22), pinchPoint,
    ]

    private static func direction(_ degrees: Double) -> Point2 {
        let angle = degrees * .pi / 180
        return Point2(x: sin(angle), y: cos(angle))
    }

    private func fingerPoints(_ finger: Finger) -> [Point2] {
        guard let bones = Self.skeleton[finger] else { return [] }
        let curl = curls[finger] ?? 0
        let along = Self.direction(bones.splay)
        var point = bones.base
        var bend = 0.0
        var points = [point]
        for (length, flexion) in zip(bones.lengths, Self.fullFlexion) {
            bend += flexion * curl * .pi / 180
            point = point + along * (length * cos(bend)) + Self.depthSkew * (length * sin(bend))
            points.append(point)
        }
        return finger == .index ? Self.blend(points, towards: Self.pinchedIndex, by: pinch) : points
    }

    private func thumbPoints() -> [Point2] {
        let curl = curls[.thumb] ?? 0
        var point = Self.thumbBase
        var points = [point]
        for (length, sweep) in zip(Self.thumbLengths, Self.thumbSweep) {
            point = point + Self.direction(Self.thumbSplay + sweep * curl) * length
            points.append(point)
        }
        return Self.blend(points, towards: Self.pinchedThumb, by: pinch)
    }

    private static func blend(_ points: [Point2], towards target: [Point2], by amount: Double) -> [Point2] {
        zip(points, target).map { $0 + ($1 - $0) * amount }
    }
}

/// A small seeded generator, so a failing case can be reproduced from its seed.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in -1...1.
    mutating func signedUnit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }
}
