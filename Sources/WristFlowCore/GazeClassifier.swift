import Foundation

/// Turns a face measurement into the numbers the gaze classifier compares.
public enum GazeFeatures {
    // Positions in the vector. Angles are in radians, the face box in image heights and the
    // pupils in eye half-widths, exactly as `FaceFrame` reports them.
    public static let yaw = 0
    public static let pitch = 1
    public static let centerX = 2
    public static let centerY = 3
    public static let size = 4
    public static let pupilX = 5
    public static let pupilY = 6
    /// 1 when the two pupil entries were measured, 0 when the eyes could not be read (the
    /// entries are then 0). A flag for the classifier, never compared as a distance.
    public static let hasPupils = 7
    public static let count = 8

    /// Roll is left out on purpose: tilting the head towards a shoulder does not move the
    /// point the face is aimed at, and it follows posture (a head propped on a hand) rather
    /// than the display, so it could only push a live face away from its own calibration.
    public static func vector(_ face: FaceFrame) -> [Double] {
        var pupils = Point2.zero
        var measured = 0.0
        if let offset = face.pupilOffset, offset.x.isFinite, offset.y.isFinite {
            pupils = offset
            measured = 1
        }
        return [face.yaw, face.pitch, face.center.x, face.center.y, face.size, pupils.x, pupils.y, measured]
    }
}

public struct GazeSample: Codable, Equatable, Sendable {
    /// `DisplayInfo.id` of the display the user was looking at.
    public var display: String
    /// The calibration target point this came from. Samples of one point are near-duplicates,
    /// so they are summarised together and held out together when measuring accuracy.
    public var group: Int
    /// `GazeFeatures.vector` of the face at that moment.
    public var features: [Double]

    public init(display: String, group: Int, features: [Double]) {
        self.display = display
        self.group = group
        self.features = features
    }
}

/// What a calibration run stores on disk.
public struct GazeCalibration: Codable, Equatable, Sendable {
    /// Sorted ids of the displays connected when it was recorded.
    public var displays: [String]
    public var cameraID: String?
    public var createdAt: Date
    public var samples: [GazeSample]

    public init(displays: [String], cameraID: String?, createdAt: Date, samples: [GazeSample]) {
        self.displays = displays.sorted()
        self.cameraID = cameraID
        self.createdAt = createdAt
        self.samples = samples
    }

    /// A calibration only describes the desk it was recorded at: with another set of displays
    /// or another camera the same head angles mean something else.
    public func matches(displays: [String], cameraID: String?) -> Bool {
        self.displays.sorted() == displays.sorted() && self.cameraID == cameraID
    }
}

public struct GazeEstimate: Equatable, Sendable {
    public var display: String
    /// Share of the neighbour vote the display won, 0...1. About 0.5 on the border between
    /// two displays, close to 1 well inside one.
    public var confidence: Double

    public init(display: String, confidence: Double) {
        self.display = display
        self.confidence = confidence
    }
}

/// Weighted nearest neighbours over the target points of one calibration.
///
/// The ~15 samples recorded for a target point are collapsed into one anchor, because they
/// are the same measurement repeated: voting among raw samples would let a single point fill
/// every neighbour slot and make the confidence jump from 0 to 1 at a border.
public struct GazeClassifier: Sendable {
    /// Ids of the calibrated displays, sorted.
    public let displays: [String]
    /// How much each measured feature counts in the vote, 0...1, indexed like `GazeFeatures`
    /// (without the flag). The feature that separates the displays best has weight 1.
    public let weights: [Double]

    /// A place on a display, in standardised features.
    private struct Anchor: Sendable {
        var display: Int
        /// The target point it was recorded at, or the two it lies between.
        var groups: [Int]
        var position: [Double]
    }

    /// The range of raw features that counts as looking at one display.
    private struct Extent: Sendable {
        var lower: [Double]
        var upper: [Double]
    }

    private let samples: [GazeSample]
    private let anchors: [Anchor]
    private let extents: [Extent]
    private let mean: [Double]
    private let scale: [Double]
    /// How much nearer one display has to be than another, in weighted standard deviations,
    /// for the vote to tip clearly its way.
    private let blur: Double

    /// The measured entries of a feature vector; the flag that follows them is not a dimension.
    private static let measured = GazeFeatures.hasPupils

    /// How far each feature wanders in everyday use while the user keeps looking at the same
    /// place (radians, image heights, pupil units). A calibration recorded sitting still for a
    /// few seconds cannot show this, so without it a feature that barely moved would turn a
    /// shifted chair into a huge distance and look more reliable than it is.
    private static let drift = [0.03, 0.03, 0.08, 0.08, 0.04, 0.15, 0.15]
    /// The vote blurs over this many standard deviations of frame noise, and never less than
    /// the minimum. At 3 the noise carries a face on the border to a 0.75 vote for either
    /// side in about one frame out of twenty.
    private static let blurPerNoise = 3.0
    private static let minimumBlur = 0.1
    /// A display reaches this share of its calibrated extent beyond its outermost target
    /// points, which are drawn a little inside the corners...
    private static let extentShare = 0.1
    /// ...this many drifts further, so that shifting in the chair is not looking away...
    private static let driftAllowance = 2.0
    /// ...and this share of the head angle itself (measured from facing the camera), because
    /// how much of a turn the head does, and how much is left to the eyes, changes from one
    /// glance to the next.
    private static let turnTolerance = 0.2

    /// Nil unless at least two displays have usable samples. Samples whose vector has another
    /// length (a calibration from another version) are ignored.
    public init?(samples: [GazeSample]) {
        let usable = samples.filter { $0.features.count == GazeFeatures.count && $0.features.allSatisfy(\.isFinite) }
        let displays = Set(usable.map(\.display)).sorted()
        guard displays.count >= 2 else { return nil }
        let displayIndex = Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($1, $0) })
        self.samples = usable
        self.displays = displays

        var mean = Array(repeating: 0.0, count: Self.measured)
        var scale = Array(repeating: 1.0, count: Self.measured)
        var separation = Array(repeating: 0.0, count: Self.measured)
        for dimension in 0..<Self.measured {
            var byDisplay = Array(repeating: [Double](), count: displays.count)
            for sample in usable where Self.measures(dimension, in: sample.features) {
                byDisplay[displayIndex[sample.display]!].append(sample.features[dimension])
            }
            let count = Double(byDisplay.reduce(0) { $0 + $1.count })
            guard count > 0 else { continue }
            let total = byDisplay.reduce(0) { $0 + $1.reduce(0, +) } / count
            var between = 0.0
            var within = 0.0
            for values in byDisplay where !values.isEmpty {
                let center = values.reduce(0, +) / Double(values.count)
                between += Double(values.count) * (center - total) * (center - total)
                within += values.reduce(0) { $0 + ($1 - center) * ($1 - center) }
            }
            let drift = Self.drift[dimension] * Self.drift[dimension]
            mean[dimension] = total
            scale[dimension] = ((between + within) / count + drift).squareRoot()
            // Fisher ratio: how far apart the displays are in this feature, against how much
            // it varies while looking at one display.
            separation[dimension] = between / (within + count * drift)
        }
        self.mean = mean
        self.scale = scale
        let best = separation.max() ?? 0
        let weights = separation.map { best > 1e-9 ? $0 / best : 1 }
        self.weights = weights

        // One point per target: the median of its samples, so a blink or a stray glance while
        // it was being recorded does not move it. Nil where nothing was measured (pupils that
        // were never readable).
        var members: [[Int]: [[Double]]] = [:]
        for sample in usable {
            members[[displayIndex[sample.display]!, sample.group], default: []].append(sample.features)
        }
        var points: [(display: Int, group: Int, raw: [Double?])] = []
        var scatter = Array(repeating: 0.0, count: Self.measured)
        var freedom = Array(repeating: 0.0, count: Self.measured)
        for key in members.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let rows = members[key]!
            let raw: [Double?] = (0..<Self.measured).map { dimension in
                let values = rows.filter { Self.measures(dimension, in: $0) }.map { $0[dimension] }.sorted()
                guard !values.isEmpty else { return nil }
                let center = values.reduce(0, +) / Double(values.count)
                scatter[dimension] += values.reduce(0) { $0 + ($1 - center) * ($1 - center) }
                freedom[dimension] += Double(values.count - 1)
                return values[values.count / 2]
            }
            points.append((key[0], key[1], raw))
        }

        // The samples of one target point differ only by what shakes from frame to frame. The
        // noisier the frames, the wider the band between two displays where neither wins the
        // vote, so that noise alone cannot carry a face across it and back.
        var noise = 0.0
        for dimension in 0..<Self.measured where freedom[dimension] > 0 {
            let perUnit = weights[dimension] / scale[dimension]
            noise += perUnit * perUnit * scatter[dimension] / freedom[dimension]
        }
        blur = max(Self.minimumBlur, Self.blurPerNoise * noise.squareRoot())

        // In head angles a display covers the box its target points span. A head aimed
        // outside every box is looking at something else. The other features stay out of
        // this: sitting somewhere else is not looking away, and the pupils are too noisy and
        // too dependent on how the turn was split to draw a line with.
        var extents: [Extent] = []
        for display in displays.indices {
            var extent = Extent(
                lower: Array(repeating: -Double.infinity, count: Self.measured),
                upper: Array(repeating: Double.infinity, count: Self.measured)
            )
            let own = points.filter { $0.display == display }
            // Fewer than three points do not span a box, so nothing can be told to be outside.
            if own.count >= 3 {
                for dimension in [GazeFeatures.yaw, GazeFeatures.pitch] {
                    let values = own.compactMap { $0.raw[dimension] }
                    guard let low = values.min(), let high = values.max() else { continue }
                    let margin = Self.extentShare * (high - low) + Self.driftAllowance * Self.drift[dimension]
                    extent.lower[dimension] = min(low * (1 - Self.turnTolerance), low * (1 + Self.turnTolerance)) - margin
                    extent.upper[dimension] = max(high * (1 - Self.turnTolerance), high * (1 + Self.turnTolerance)) + margin
                }
            }
            extents.append(extent)
        }
        self.extents = extents

        var anchors: [Anchor] = []
        for point in points {
            let position: [Double] = (0..<Self.measured).map { dimension in
                if let value = point.raw[dimension] { return (value - mean[dimension]) / scale[dimension] }
                // A point recorded without readable eyes takes the pupils typical of its
                // display, so it is neither nearer to nor further from a face on that account.
                let known = points.filter { $0.raw[dimension] != nil }
                let sameDisplay = known.filter { $0.display == point.display }
                let donors = (sameDisplay.isEmpty ? known : sameDisplay).compactMap { $0.raw[dimension] }
                guard !donors.isEmpty else { return 0 }
                return (donors.reduce(0, +) / Double(donors.count) - mean[dimension]) / scale[dimension]
            }
            anchors.append(Anchor(display: point.display, groups: [point.group], position: position))
        }
        // A display is convex: whatever lies between two of its target points is on it too.
        // Five points leave the middle of every edge far from all of them, and there the
        // corner of a neighbouring display would otherwise be the nearest anchor.
        let recorded = anchors
        for (index, first) in recorded.enumerated() {
            for second in recorded[(index + 1)...] where second.display == first.display {
                let middle = zip(first.position, second.position).map { ($0 + $1) / 2 }
                anchors.append(Anchor(display: first.display, groups: first.groups + second.groups, position: middle))
            }
        }
        self.anchors = anchors
    }

    /// Nil when the face is unlike anything calibrated: looking away, down at the desk or at
    /// a phone.
    public func classify(_ features: [Double]) -> GazeEstimate? {
        guard let query = standardised(features) else { return nil }
        let familiar = extents.contains { extent in
            (0..<query.dimensions).allSatisfy { extent.lower[$0] <= features[$0] && features[$0] <= extent.upper[$0] }
        }
        guard familiar else { return nil }
        return vote(query, excluding: nil)
    }

    /// Leave-one-group-out accuracy, 0...1: every sample is classified with its own target
    /// point removed, and counts when the vote still names its display.
    ///
    /// Whether the face is familiar is not checked, and the figure is pessimistic: a held-out
    /// corner lies outside what remains of its display, which no point of a display does in
    /// real use. Corners that almost touch a neighbouring display are lost this way.
    public func evaluate() -> Double {
        var correct = 0
        var total = 0
        for sample in samples {
            guard let query = standardised(sample.features), let display = displays.firstIndex(of: sample.display) else { continue }
            total += 1
            if vote(query, excluding: (display, sample.group))?.display == sample.display { correct += 1 }
        }
        return total > 0 ? Double(correct) / Double(total) : 0
    }

    private func vote(_ query: (position: [Double], dimensions: Int), excluding: (display: Int, group: Int)?) -> GazeEstimate? {
        // Each display votes with its nearest anchor only. Counting several would reward the
        // display whose anchors coincide in the features that carry weight (the corners of
        // one edge, when the displays are stacked) and make the vote jump at the border.
        var nearest = Array(repeating: Double.infinity, count: displays.count)
        for anchor in anchors {
            if let excluding, anchor.display == excluding.display, anchor.groups.contains(excluding.group) { continue }
            var sum = 0.0
            for dimension in 0..<query.dimensions {
                let d = (query.position[dimension] - anchor.position[dimension]) * weights[dimension]
                sum += d * d
            }
            nearest[anchor.display] = min(nearest[anchor.display], sum.squareRoot())
        }
        guard let closest = nearest.min(), closest.isFinite else { return nil }
        // A softmax of the distances: only how much nearer a display is counts, so a third
        // display far away takes nothing from the vote.
        var scores = Array(repeating: 0.0, count: displays.count)
        var total = 0.0
        for (display, distance) in nearest.enumerated() where distance.isFinite {
            scores[display] = exp(-(distance - closest) / blur)
            total += scores[display]
        }
        var best = 0
        for index in scores.indices where scores[index] > scores[best] { best = index }
        return GazeEstimate(display: displays[best], confidence: scores[best] / total)
    }

    /// The measured features in standard deviations, and how many of them to compare: the
    /// pupils come last, so a face without readable eyes is simply compared on fewer
    /// dimensions, against every anchor alike.
    private func standardised(_ features: [Double]) -> (position: [Double], dimensions: Int)? {
        guard features.count == GazeFeatures.count, features.allSatisfy(\.isFinite) else { return nil }
        let position = (0..<Self.measured).map { (features[$0] - mean[$0]) / scale[$0] }
        let dimensions = features[GazeFeatures.hasPupils] >= 0.5 ? Self.measured : GazeFeatures.pupilX
        return (position, dimensions)
    }

    private static func measures(_ dimension: Int, in features: [Double]) -> Bool {
        dimension < GazeFeatures.pupilX || features[GazeFeatures.hasPupils] >= 0.5
    }
}
