import Foundation

/// Decimals kept of a coordinate in a stored shape: a ten-thousandth of a palm size, far below
/// landmark noise, and short enough to keep the user's file small.
private let pointDecimals = 4
/// Decimals kept of a tilt, in degrees.
private let tiltDecimals = 1

private func rounded(_ value: Double, decimals: Int) -> Double {
    let scale = pow(10, Double(decimals))
    return (value * scale).rounded() / scale
}

/// One hand shape, in the hand's own frame, so it can be compared with another whatever the
/// hand's place, size and tilt in the image and whichever hand it is.
///
/// The frame has the wrist at the origin and the base of the middle finger at (0, 1): points
/// are divided by the palm size and turned until wrist to middle knuckle points up. A left hand
/// is mirrored first, so both hands making one shape give the same points; the thumb of a hand
/// showing its palm is then on the -x side, and on the +x side when it shows its back.
public struct ShapeExample: Codable, Hashable, Sendable {
    /// 21 points indexed by `Joint.rawValue`, in palm sizes, rounded to 4 decimals.
    public var points: [Point2]
    /// How far the hand's axis (wrist to middle knuckle) is off straight up in the image, in
    /// degrees, -180...180, rounded to 0.1. Positive leans outwards: towards the user's right
    /// for a right hand and towards the user's left for a left hand, so the two hands held as
    /// mirror images of each other read the same. A hand whose side is not known is read as a
    /// right hand.
    public var tilt: Double
    /// Whether the palm, rather than the back, is towards the camera; nil when the hand is
    /// edge-on or it is not known which hand it is.
    public var palmFacing: Bool?

    /// Nil when any joint is below `PoseClassifier.minJointConfidence` or the palm has no size:
    /// one misplaced joint would be read as a different shape.
    public init?(_ hand: Hand) {
        guard hand.confidences.allSatisfy({ $0 >= PoseClassifier.minJointConfidence }) else { return nil }
        let palm = hand.palmSize
        guard palm > 0, palm.isFinite else { return nil }

        let mirror: Double = hand.handedness == .left ? -1 : 1
        let wrist = hand[.wrist]
        let knuckle = hand[.middleMCP]
        let up = Point2(x: (knuckle.x - wrist.x) * mirror / palm, y: (knuckle.y - wrist.y) / palm)
        points = hand.points.map { point in
            let x = (point.x - wrist.x) * mirror / palm
            let y = (point.y - wrist.y) / palm
            return Point2(
                x: rounded(x * up.y - y * up.x, decimals: pointDecimals),
                y: rounded(x * up.x + y * up.y, decimals: pointDecimals)
            )
        }
        tilt = rounded(atan2(up.x, up.y) * 180 / .pi, decimals: tiltDecimals)
        palmFacing = PoseClassifier.palmFacesCamera(hand)
    }

    /// How different two shapes are, in palm sizes: the mean displacement of the four joints of
    /// the finger that differs most.
    ///
    /// The worst finger rather than the mean over the hand, because shapes that mean different
    /// things often differ in one finger only (three and four fingers), and averaged over 21
    /// joints that finger would drown in the noise of the other four.
    public func distance(to other: ShapeExample) -> Double {
        var worst = 0.0
        // Joints are numbered wrist first, then four per finger (see `Joint`). Walking the
        // indices keeps this free of allocations: it runs for every stored example on every frame.
        var joint = 1
        for _ in 0..<Self.fingerCount {
            var sum = 0.0
            for _ in 0..<Self.jointsPerFinger {
                sum += points[joint].distance(to: other.points[joint])
                joint += 1
            }
            worst = max(worst, sum / Double(Self.jointsPerFinger))
        }
        return worst
    }

    private static let fingerCount = Finger.allCases.count
    private static let jointsPerFinger = (Joint.allCases.count - 1) / Finger.allCases.count

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case points, tilt, palmFacing
    }

    /// Points are stored as one flat list, x then y for each joint, which takes about half
    /// the space of 21 keyed objects.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let flat = try values.decode([Double].self, forKey: .points)
        guard flat.count == 2 * Joint.allCases.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .points, in: values,
                debugDescription: "Expected \(2 * Joint.allCases.count) coordinates, found \(flat.count)"
            )
        }
        points = stride(from: 0, to: flat.count, by: 2).map { Point2(x: flat[$0], y: flat[$0 + 1]) }
        tilt = try values.decode(Double.self, forKey: .tilt)
        palmFacing = try values.decodeIfPresent(Bool.self, forKey: .palmFacing)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(points.flatMap { [$0.x, $0.y] }, forKey: .points)
        try values.encode(tilt, forKey: .tilt)
        try values.encodeIfPresent(palmFacing, forKey: .palmFacing)
    }
}

/// A recorded shape: what to compare a hand with, and how close is close enough.
///
/// The numbers below come from recordings of one person (Fixtures/finger-counts.jsonl and
/// palm-and-back.jsonl), measured with `ShapeExample.distance(to:)`:
/// - the same shape within one take: 0.03 to 0.15 palm sizes;
/// - the same shape in another session or on the other hand: 0.12 to 0.25;
/// - different shapes: 0.39 and more (the closest pair is three and four fingers).
public struct ShapeTemplate: Codable, Hashable, Sendable {
    /// A few of the recorded hands, chosen to cover everything the takes showed.
    public var examples: [ShapeExample]
    /// The largest distance to the nearest example, in palm sizes, at which a hand still shows
    /// this shape.
    public var threshold: Double
    /// The middle of the tilts recorded, in degrees as in `ShapeExample.tilt`. Nil, together
    /// with `tiltTolerance`, when the shape was recorded at every tilt and so means the same
    /// whichever way it points.
    public var tiltCentre: Double?
    /// How far from `tiltCentre` a hand may be tilted, in degrees. This is what tells a thumbs
    /// down from a thumbs up: in the hand's own frame they are the same shape.
    public var tiltTolerance: Double?
    /// The side of the hand that was recorded, when (nearly) every frame agreed on it; nil
    /// when either side will do.
    public var palmFacing: Bool?

    /// Where a threshold may lie, in palm sizes. The same shape in another session is 0.12 to
    /// 0.25 away, so a threshold under 0.25 would too often miss a shape on another day than
    /// the one it was recorded on; different shapes start at 0.39, and 0.32 leaves a hand that
    /// is held less carefully than when recording some room before it reaches them.
    public static let thresholdRange = 0.25...0.32
    /// What the spread between takes is multiplied by to get the threshold. Takes recorded one
    /// after the other differ less than the same shape does on another day, so the spread seen
    /// is an underestimate.
    static let spreadFactor = 1.6
    /// The share of frames (0...1) whose distance to the other takes the spread has to cover.
    /// Not all of them, so that a few stray frames do not set it.
    static let spreadPercentile = 0.9
    /// The threshold, in palm sizes, of a shape recorded in a single take, which says nothing
    /// about the spread between takes: the middle of `thresholdRange`, just above the 0.25
    /// measured for the same shape in another session.
    static let singleTakeThreshold = 0.27
    /// The most examples kept. Twelve cover three takes of a held shape with distances between
    /// neighbours well under the threshold, and keep a template to a few kilobytes on disk.
    static let maxExamples = 12
    /// The fewest usable frames a shape can be learned from: a fifth of a second at 30 frames
    /// per second. Fewer do not show how much a held hand wanders.
    static let minFrames = 6
    /// The largest distance, in palm sizes, measured between two showings of one shape (another
    /// session, the other hand). A recorded frame farther than this from most of the recording
    /// is not the shape.
    static let maxSameShapeDistance = 0.25
    /// Distance, in palm sizes, under which a frame adds nothing to the examples already
    /// chosen: the smallest distance measured between frames of one held shape.
    static let minExampleSeparation = 0.03
    /// How much farther than recorded a hand may be tilted, in degrees. Generous, because
    /// people do not hold a hand at the same angle twice, and still well short of the 180
    /// degrees between a shape and the same shape upside down.
    static let tiltMargin = 45.0
    /// The share of frames (0...1) that must show the same side of the hand for the template
    /// to insist on that side.
    static let facingAgreement = 0.9

    /// Learns a shape from separate showings of it (the user lowers the hand between them),
    /// each a run of frames. Nil when there is too little to go on: fewer than `minFrames`
    /// frames that agree with each other, which is also what takes of different shapes leave.
    public init?(takes: [[ShapeExample]]) {
        let takes = Self.withoutOutliers(takes)
        let frames = takes.flatMap { $0 }
        guard frames.count >= Self.minFrames else { return nil }

        examples = Self.cover(frames, count: Self.maxExamples)
        let learned = Self.spread(between: takes).map { $0 * Self.spreadFactor } ?? Self.singleTakeThreshold
        threshold = min(max(learned, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)

        let radians = frames.map { $0.tilt * .pi / 180 }
        let centre = atan2(radians.reduce(0) { $0 + sin($1) }, radians.reduce(0) { $0 + cos($1) }) * 180 / .pi
        let tolerance = (frames.map { Self.angle(between: centre, and: $0.tilt) }.max() ?? 0) + Self.tiltMargin
        if tolerance < 180 {
            tiltCentre = rounded(centre, decimals: tiltDecimals)
            tiltTolerance = rounded(tolerance, decimals: tiltDecimals)
        }

        let needed = Self.facingAgreement * Double(frames.count)
        palmFacing = [true, false].first { side in
            Double(frames.count { $0.palmFacing == side }) >= needed
        }
    }

    /// Learns a shape from recorded hands, leaving out the frames that cannot be read.
    public init?(hands takes: [[Hand]]) {
        self.init(takes: takes.map { $0.compactMap(ShapeExample.init) })
    }

    /// How far a hand is from this shape, in palm sizes: the distance to the nearest example.
    /// Nil when its tilt or the side it shows rules it out, whatever its shape.
    public func distance(to example: ShapeExample) -> Double? {
        if let tiltCentre, let tiltTolerance, Self.angle(between: tiltCentre, and: example.tilt) > tiltTolerance {
            return nil
        }
        // A hand whose side cannot be told (edge-on) is not ruled out: a side read with the
        // hand turned a little further than when recording would otherwise drop the shape.
        if let palmFacing, let shown = example.palmFacing, shown != palmFacing { return nil }
        return examples.lazy.map { $0.distance(to: example) }.min()
    }

    public func matches(_ example: ShapeExample) -> Bool {
        distance(to: example).map { $0 <= threshold } ?? false
    }

    /// How close two recorded shapes come, in palm sizes: the smallest distance between an
    /// example of one and the other. Nil when tilt or side keeps them apart altogether.
    public func distance(to other: ShapeTemplate) -> Double? {
        let distances = examples.compactMap(other.distance(to:)) + other.examples.compactMap(distance(to:))
        return distances.min()
    }

    /// How much separate takes of one shape differ, in palm sizes: the distance from a frame to
    /// the nearest frame of any other take, at the `spreadPercentile` over all frames. Nil with
    /// fewer than two takes that have frames.
    public static func spread(between takes: [[ShapeExample]]) -> Double? {
        let takes = takes.filter { !$0.isEmpty }
        guard takes.count > 1 else { return nil }
        var nearest: [Double] = []
        for (index, take) in takes.enumerated() {
            for frame in take {
                var best = Double.infinity
                for (otherIndex, other) in takes.enumerated() where otherIndex != index {
                    for candidate in other { best = min(best, frame.distance(to: candidate)) }
                }
                nearest.append(best)
            }
        }
        nearest.sort()
        let rank = Int((Double(nearest.count) * spreadPercentile).rounded(.up))
        return nearest[min(max(rank, 1), nearest.count) - 1]
    }

    /// The takes without the frames that are not the shape: a hand still arriving or already
    /// leaving, or lost and found again by the detector. A frame is one of those when it is
    /// farther than `maxSameShapeDistance` from most of the other frames. Left in, it would be
    /// picked as an example for being unlike the rest, and widen what the template matches.
    private static func withoutOutliers(_ takes: [[ShapeExample]]) -> [[ShapeExample]] {
        let frames = takes.flatMap { $0 }
        var kept: [[ShapeExample]] = []
        for take in takes {
            let usual = take.filter { frame in
                var distances = frames.map { frame.distance(to: $0) }
                distances.sort()
                // The frame itself is in the list at distance 0, so the median of the others
                // is one place further up.
                return distances[frames.count / 2] <= maxSameShapeDistance
            }
            if !usual.isEmpty { kept.append(usual) }
        }
        return kept
    }

    /// Up to `count` frames that between them are close to every frame: the one closest to all
    /// the others first, then each time the frame farthest from those already chosen.
    private static func cover(_ frames: [ShapeExample], count: Int) -> [ShapeExample] {
        var first = 0
        var smallestTotal = Double.infinity
        for (index, frame) in frames.enumerated() {
            let total = frames.reduce(0) { $0 + frame.distance(to: $1) }
            if total < smallestTotal {
                smallestTotal = total
                first = index
            }
        }

        var chosen = [frames[first]]
        var toChosen = frames.map { $0.distance(to: frames[first]) }
        while chosen.count < count {
            guard let farthest = toChosen.indices.max(by: { toChosen[$0] < toChosen[$1] }),
                  toChosen[farthest] >= minExampleSeparation
            else { break }
            chosen.append(frames[farthest])
            for index in frames.indices {
                toChosen[index] = min(toChosen[index], frames[index].distance(to: frames[farthest]))
            }
        }
        return chosen
    }

    /// The angle between two directions given in degrees, 0...180.
    private static func angle(between a: Double, and b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return difference > 180 ? 360 - difference : difference
    }
}

/// Reads the shapes the user recorded.
public enum ShapeMatcher {
    /// The id of the recorded shape a hand shows: the closest one within its own threshold, or
    /// nil when it shows none of them or cannot be read.
    public static func match(_ hand: Hand, among shapes: [(id: String, template: ShapeTemplate)]) -> String? {
        guard !shapes.isEmpty, let example = ShapeExample(hand) else { return nil }
        return match(example, among: shapes)
    }

    /// The same for a hand already put in its own frame.
    public static func match(
        _ example: ShapeExample, among shapes: [(id: String, template: ShapeTemplate)]
    ) -> String? {
        var best: (id: String, distance: Double)?
        for shape in shapes {
            guard let distance = shape.template.distance(to: example), distance <= shape.template.threshold else {
                continue
            }
            if best.map({ distance < $0.distance }) ?? true { best = (shape.id, distance) }
        }
        return best?.id
    }

    /// What a newly recorded shape could be confused with, to tell the user before saving.
    public struct Review: Equatable, Sendable {
        /// The built-in pose at least `builtInMajority` of the recorded frames are read as, or
        /// nil: recording it again as a gesture of its own would make both fire.
        public var builtIn: Pose?
        /// The share of recorded frames (0...1) read as `builtIn`; 0 when that is nil.
        public var builtInShare: Double
        /// Ids of the other recorded shapes this one comes too close to, nearest first.
        public var similar: [String]
        /// How much the takes differ, in palm sizes (see `ShapeTemplate.spread(between:)`),
        /// with every readable frame counted; 0 when there was a single take.
        public var spread: Double
        /// False when the takes differ so much that they were probably not the same shape, and
        /// the user should record again.
        public var isConsistent: Bool

        public init(builtIn: Pose?, builtInShare: Double, similar: [String], spread: Double, isConsistent: Bool) {
            self.builtIn = builtIn
            self.builtInShare = builtInShare
            self.similar = similar
            self.spread = spread
            self.isConsistent = isConsistent
        }
    }

    /// The share of recorded frames (0...1) from which a shape counts as a built-in pose: when
    /// half of what was shown already fires a built-in gesture, the two cannot be told apart.
    static let builtInMajority = 0.5
    /// Two recorded shapes are too close when their nearest examples are within the looser of
    /// their thresholds times this. A live hand wanders from the examples, so shapes need more
    /// than a threshold between them; 1.2 is the most that still leaves the closest pair of
    /// distinct shapes measured (three and four fingers, 0.39 palm sizes) apart when both
    /// thresholds are at the top of their range (0.32 × 1.2 = 0.384).
    static let similarityMargin = 1.2
    /// The largest spread between takes, in palm sizes, that is still one shape: beyond it the
    /// learned threshold would exceed the range thresholds are kept in.
    static let maxConsistentSpread = ShapeTemplate.thresholdRange.upperBound / ShapeTemplate.spreadFactor

    public static func review(
        takes: [[Hand]], template: ShapeTemplate, others: [(id: String, template: ShapeTemplate)], profile: PoseProfile
    ) -> Review {
        var readings: [Pose: Int] = [:]
        var frameCount = 0
        for hand in takes.joined() {
            frameCount += 1
            if let pose = PoseClassifier.classify(hand, profile: profile) { readings[pose, default: 0] += 1 }
        }
        let commonest = Pose.builtIn.max { (readings[$0] ?? 0) < (readings[$1] ?? 0) }
        let share = frameCount > 0 ? Double(commonest.flatMap { readings[$0] } ?? 0) / Double(frameCount) : 0
        let isBuiltIn = share >= builtInMajority

        let close = others.compactMap { other -> (id: String, distance: Double)? in
            guard let distance = template.distance(to: other.template) else { return nil }
            let limit = max(template.threshold, other.template.threshold) * similarityMargin
            return distance < limit ? (other.id, distance) : nil
        }

        let spread = ShapeTemplate.spread(between: takes.map { $0.compactMap(ShapeExample.init) }) ?? 0
        return Review(
            builtIn: isBuiltIn ? commonest : nil,
            builtInShare: isBuiltIn ? share : 0,
            similar: close.sorted { $0.distance < $1.distance }.map(\.id),
            spread: spread,
            isConsistent: spread <= maxConsistentSpread
        )
    }
}
