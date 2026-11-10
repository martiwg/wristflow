import Foundation

/// Every number movements are cut out and compared with. Distances are in palm sizes unless
/// stated, so they hold at any distance from the camera. A path distance is in fractions of the
/// larger side of the box around the path; see `MovementPath`.
///
/// None of these has been tuned on recorded movements, because none has been recorded yet: the
/// values come from the design, from synthetic paths and from recordings of other gestures.
public struct MovementConfig: Codable, Equatable, Sendable {
    /// Seconds the palm centre must stay within `restRadius` for the hand to count as at rest.
    /// A movement starts at a rest and ends at the next one.
    public var restTime = 0.15
    /// How far the palm centre may drift within `restTime`, in palm sizes, and still count as resting.
    public var restRadius = 0.12
    /// Longest wait between two frames, in seconds, that is still the same stretch of motion.
    /// After a longer one the hand has to rest again before a movement can start.
    public var maxGap = 0.2
    /// Smallest movement that counts: the diagonal of the box around its path, in palm sizes.
    /// Anything smaller is a hand shifting, not a gesture.
    public var minExtent = 1.5
    /// Shortest movement that counts, in seconds, from leaving rest to resting again.
    public var minDuration = 0.25
    /// Longest movement that counts, in seconds. A hand that has not come to rest by then is
    /// doing something else.
    public var maxDuration = 3.0
    /// Seconds of the starting rest, counted back from the moment the hand leaves it, whose pose
    /// readings decide the starting pose.
    public var startPoseWindow = 0.3
    /// Share of the frames in `startPoseWindow` (ratio, 0...1) that one pose must exceed to be
    /// the starting pose.
    public var startPoseShare = 0.5
    /// Largest tilt, in degrees either way, that is taken out before two paths are compared.
    /// Nobody repeats a movement at exactly the same angle, and 15 degrees left in cost as much
    /// as the whole of `minThreshold`; beyond this the direction is part of the movement.
    public var maxTilt = 15.0
    /// How many times larger or smaller than the median of a template's takes a movement's
    /// extent may be (ratio).
    public var extentTolerance = 2.0
    /// How many times longer or shorter than the median of a template's takes a movement may
    /// last (ratio).
    public var durationTolerance = 2.0
    /// What the largest distance from a take to its nearest other take is multiplied by to give
    /// the template's threshold (ratio).
    public var thresholdSlack = 1.5
    /// Lowest threshold a template can get, as a path distance. Takes recorded in one sitting
    /// are more alike than the movement made again later: synthetic repetitions at other sizes,
    /// speeds and frame rates come out up to 0.097 from the nearest of four takes that are
    /// within 0.06 of each other.
    public var minThreshold = 0.10
    /// Highest threshold a template can get, as a path distance. Above it, movements that were
    /// never recorded start to match: the nearest that anything in the recordings of other
    /// gestures comes to a synthetic movement is 0.233.
    public var maxThreshold = 0.20
    /// How much nearer a movement must be to the nearest template than to the second nearest,
    /// as a path distance. Two enrolments of the same synthetic movement differ by up to 0.046
    /// in how far they are from a repetition of it, so a smaller lead says nothing.
    public var matchMargin = 0.05
    /// Share of a path's own length (ratio, 0...1) that its ends must be apart for it to count
    /// as a straight line.
    public var straightLineRatio = 0.9

    public init() {}

    // Decoded by hand so a file written before a tunable existed still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try values.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        let defaults = MovementConfig()
        restTime = try value(.restTime, defaults.restTime)
        restRadius = try value(.restRadius, defaults.restRadius)
        maxGap = try value(.maxGap, defaults.maxGap)
        minExtent = try value(.minExtent, defaults.minExtent)
        minDuration = try value(.minDuration, defaults.minDuration)
        maxDuration = try value(.maxDuration, defaults.maxDuration)
        startPoseWindow = try value(.startPoseWindow, defaults.startPoseWindow)
        startPoseShare = try value(.startPoseShare, defaults.startPoseShare)
        maxTilt = try value(.maxTilt, defaults.maxTilt)
        extentTolerance = try value(.extentTolerance, defaults.extentTolerance)
        durationTolerance = try value(.durationTolerance, defaults.durationTolerance)
        thresholdSlack = try value(.thresholdSlack, defaults.thresholdSlack)
        minThreshold = try value(.minThreshold, defaults.minThreshold)
        maxThreshold = try value(.maxThreshold, defaults.maxThreshold)
        matchMargin = try value(.matchMargin, defaults.matchMargin)
        straightLineRatio = try value(.straightLineRatio, defaults.straightLineRatio)
    }
}

/// The shape a hand traced, free of where in the image it was traced, how large and how fast.
///
/// The path of the palm centre is resampled to `pointCount` points equally spaced along its
/// length, moved so its centroid is the origin, and scaled so the larger side of the box around
/// it is 1. The scale is the same on both axes, so a line stays a line and a circle a circle.
/// Nothing is turned: a clockwise circle is not an anticlockwise one and up is not down.
public struct MovementPath: Codable, Hashable, Sendable {
    /// How many points a path is resampled to. Fixed rather than configurable because stored
    /// takes can only be compared with paths of the same count.
    public static let pointCount = 32

    /// The resampled, centred and scaled path, in fractions of its larger side, rounded to 4 decimals.
    public var points: [Point2]
    /// Diagonal of the box around the path as it was made, in palm sizes.
    public var extent: Double
    /// Seconds the movement took.
    public var duration: Double

    /// The path through `centers`, the palm centres of one movement in the order they were
    /// seen (image heights). Nil when the hand did not go anywhere.
    public init?(centers: [Point2], palmSize: Double, duration: Double) {
        guard let first = centers.first, palmSize > 0 else { return nil }
        var length = 0.0
        var previous = first
        for center in centers {
            length += center.distance(to: previous)
            previous = center
        }
        guard length > 0 else { return nil }

        let resampled = Self.resample(centers, count: Self.pointCount, length: length)
        let (low, high) = Self.box(around: resampled)
        let side = max(high.x - low.x, high.y - low.y)
        guard side > 0 else { return nil }
        let centroid = resampled.reduce(Point2.zero, +) * (1 / Double(resampled.count))
        points = resampled.map { point in
            let scaled = (point - centroid) * (1 / side)
            return Point2(x: Self.rounded(scaled.x), y: Self.rounded(scaled.y))
        }
        let (rawLow, rawHigh) = Self.box(around: centers)
        extent = Self.rounded((rawHigh - rawLow).length / palmSize)
        self.duration = Self.rounded(duration)
    }

    /// How different two paths are: the mean distance between corresponding points, in
    /// fractions of the larger side, once the tilt between them is taken out as far as
    /// `maxTilt` degrees allow. 0 is the same path; a path against its own mirror image or its
    /// own reverse is around 0.5. Infinite when the paths cannot be compared.
    ///
    /// The tilt is the one that minimises the squared distances, which has a closed form, so
    /// nothing is searched. Each path is turned half of it towards the other and scaled again
    /// to a larger side of 1, because the box around a tilted path is not the box around the
    /// upright one: a square Z tilted by 15 degrees is stored a fifth smaller. Meeting half way
    /// makes the distance the same in both directions.
    public func distance(to other: MovementPath, maxTilt: Double = MovementConfig().maxTilt) -> Double {
        guard !points.isEmpty, points.count == other.points.count else { return .infinity }
        var dot = 0.0
        var cross = 0.0
        for (a, b) in zip(points, other.points) {
            dot += a.x * b.x + a.y * b.y
            cross += a.y * b.x - a.x * b.y
        }
        let limit = maxTilt * .pi / 180
        let tilt = min(limit, max(-limit, atan2(cross, dot)))
        let mine = Self.turned(points, by: -tilt / 2)
        let theirs = Self.turned(other.points, by: tilt / 2)
        var total = 0.0
        for (a, b) in zip(mine, theirs) { total += a.distance(to: b) }
        return total / Double(points.count)
    }

    /// `points` turned anticlockwise about the origin by `angle` radians, then scaled so the
    /// larger side of the box around them is 1.
    private static func turned(_ points: [Point2], by angle: Double) -> [Point2] {
        let (sine, cosine) = (sin(angle), cos(angle))
        let turned = points.map { Point2(x: $0.x * cosine - $0.y * sine, y: $0.x * sine + $0.y * cosine) }
        let (low, high) = box(around: turned)
        let side = max(high.x - low.x, high.y - low.y)
        return side > 0 ? turned.map { $0 * (1 / side) } : turned
    }

    /// Distance between the ends of the path over its length: 1 for a perfectly straight
    /// line, 0 for a path that ends where it began.
    public var straightness: Double {
        guard let first = points.first, let last = points.last else { return 0 }
        var length = 0.0
        var previous = first
        for point in points {
            length += point.distance(to: previous)
            previous = point
        }
        return length > 0 ? first.distance(to: last) / length : 0
    }

    /// Whether the path is barely longer than the distance between its ends. Hands make such
    /// movements all the time without meaning anything by them, so the app warns about
    /// recording one. Uses the default `MovementConfig.straightLineRatio`; compare
    /// `straightness` with a tuned one.
    public var isStraightLine: Bool { straightness >= MovementConfig().straightLineRatio }

    /// `count` points equally spaced along the polyline through `points`, whose length is `length`.
    private static func resample(_ points: [Point2], count: Int, length: Double) -> [Point2] {
        let step = length / Double(count - 1)
        var result = [points[0]]
        result.reserveCapacity(count)
        var walked = 0.0
        for index in points.indices.dropFirst() {
            let from = points[index - 1]
            let to = points[index]
            let stretch = from.distance(to: to)
            guard stretch > 0 else { continue }
            while result.count < count - 1, walked + stretch >= Double(result.count) * step {
                let along = (Double(result.count) * step - walked) / stretch
                result.append(from + (to - from) * along)
            }
            walked += stretch
        }
        // The end is put in as it is; rounding in the sums above can also leave a point short.
        while result.count < count { result.append(points[points.count - 1]) }
        return result
    }

    /// Opposite corners of the box around `points`.
    private static func box(around points: [Point2]) -> (low: Point2, high: Point2) {
        var low = points[0]
        var high = points[0]
        for point in points {
            low = Point2(x: min(low.x, point.x), y: min(low.y, point.y))
            high = Point2(x: max(high.x, point.x), y: max(high.y, point.y))
        }
        return (low, high)
    }

    /// Four decimals are far finer than the landmarks and keep stored takes short.
    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}

/// One finished movement of a hand.
public struct MovementSegment: Hashable, Sendable {
    public var path: MovementPath
    /// The pose the hand held before it set off, when one was read clearly.
    public var startPose: Pose?
    /// Time the hand left rest, in seconds on the clock of the frames.
    public var start: Double
    /// Time it came to rest again.
    public var end: Double

    public init(path: MovementPath, startPose: Pose?, start: Double, end: Double) {
        self.path = path
        self.startPose = startPose
        self.start = start
        self.end = end
    }
}

/// Frame times are sums of floating-point intervals, so "0.15 s later" can arrive as 0.1499….
private func reached(_ elapsed: Double, _ needed: Double) -> Bool {
    elapsed >= needed - 1e-9
}

/// Cuts a hand's motion into movements. One per followed hand.
///
/// A movement is the hand still, then moving, then still again, all of it in view. It starts at
/// the last frame of a rest and ends at the first frame of the next rest. A hand that comes into
/// view already moving has no rest to start from, which is what keeps a hand being raised from
/// counting, and a hand that leaves view never reaches the rest that would end its movement.
///
/// All timing comes from the frame times, so the frame rate may vary and frames may be missing.
public struct MovementTracker: Sendable {
    public var config: MovementConfig

    private struct Sample: Sendable {
        var time: Double
        var center: Point2
        var palmSize: Double
        var pose: Pose?
    }

    private enum Phase: Sendable {
        /// Seen, but not at rest since it appeared: whatever it is doing cannot become a movement.
        case unsettled
        /// At rest since this time.
        case resting(since: Double)
        /// Left rest. `palmSize` is the one measured at rest, before motion blurred the hand.
        case moving(startPose: Pose?, palmSize: Double)
    }

    private var phase = Phase.unsettled
    /// Oldest first. While moving, everything from the last resting sample on; otherwise only
    /// as far back as a rest and the starting pose are judged on.
    private var samples: [Sample] = []

    public init(config: MovementConfig = MovementConfig()) {
        self.config = config
    }

    /// Forgets the hand, as when it has been lost.
    public mutating func reset() {
        phase = .unsettled
        samples = []
    }

    /// A movement is under way.
    public var isMoving: Bool {
        if case .moving = phase { return true }
        return false
    }

    /// The palm centres of the movement under way (image heights), oldest first, for drawing
    /// it live. Empty at rest.
    public var trail: [Point2] {
        isMoving ? samples.map(\.center) : []
    }

    /// Takes one frame of the followed hand: where its palm centre is and how large its palm
    /// (image heights), and the pose read on it, nil when none was clear. Returns the movement
    /// that this frame shows to have ended, if it was large and long enough to count.
    public mutating func ingest(time: Double, center: Point2, palmSize: Double, pose: Pose?) -> MovementSegment? {
        // After a long gap nobody knows where the hand went in between; a clock that runs
        // backwards means a new camera session.
        if let last = samples.last, time < last.time || time - last.time > config.maxGap + 1e-9 { reset() }
        samples.append(Sample(time: time, center: center, palmSize: palmSize, pose: pose))

        switch phase {
        case .unsettled:
            if let first = restStart() { phase = .resting(since: samples[first].time) }
            forgetOldSamples()
            return nil

        case .resting(let since):
            guard restStart() == nil else {
                forgetOldSamples()
                return nil
            }
            // This frame broke the rest, so the one before it is where the movement starts.
            let start = samples.count - 2
            let window = max(since, samples[start].time - config.startPoseWindow)
            phase = .moving(startPose: dominantPose(from: window, through: start), palmSize: samples[start].palmSize)
            samples.removeFirst(start)
            return nil

        case .moving(let startPose, let restingPalmSize):
            guard let end = restStart() else {
                // Too long to count whenever it ends, so its samples need not be kept. The
                // allowance is what it takes to see the rest that would have ended it in time:
                // `restTime`, and the wait for one more frame.
                if time - samples[0].time > config.maxDuration + config.restTime + config.maxGap { reset() }
                return nil
            }
            let centers = samples[...end].map(\.center)
            let (start, finish) = (samples[0].time, samples[end].time)
            phase = .resting(since: finish)
            samples.removeFirst(end)
            let duration = finish - start
            guard reached(duration, config.minDuration), duration <= config.maxDuration,
                  let path = MovementPath(centers: centers, palmSize: restingPalmSize, duration: duration),
                  path.extent >= config.minExtent else { return nil }
            return MovementSegment(path: path, startPose: startPose, start: start, end: finish)
        }
    }

    /// Index of the first sample of the rest the hand is in now, or nil when it is not at rest:
    /// the latest sample and all those before it that lie within `restRadius` of it have to
    /// span `restTime`.
    private func restStart() -> Int? {
        guard let newest = samples.last else { return nil }
        let radius = config.restRadius * newest.palmSize
        var first = samples.count - 1
        while first > 0, samples[first - 1].center.distance(to: newest.center) <= radius { first -= 1 }
        return reached(newest.time - samples[first].time, config.restTime) ? first : nil
    }

    /// Drops what neither a rest nor a starting pose is judged on any more. Keeps one sample
    /// at or beyond the horizon, so a rest of exactly that length can be seen.
    private mutating func forgetOldSamples() {
        guard let newest = samples.last else { return }
        let horizon = newest.time - max(config.restTime, config.startPoseWindow)
        var stale = 0
        while stale + 1 < samples.count, samples[stale + 1].time <= horizon { stale += 1 }
        samples.removeFirst(stale)
    }

    /// The pose read on more than `startPoseShare` of the samples from time `since` through
    /// index `last`, or nil when no pose was read that often. Poses read later, on the moving
    /// hand, are blurred and never looked at.
    private func dominantPose(from since: Double, through last: Int) -> Pose? {
        var counts: [Pose: Int] = [:]
        var total = 0
        for sample in samples[...last] where sample.time >= since {
            total += 1
            if let pose = sample.pose { counts[pose, default: 0] += 1 }
        }
        guard let top = counts.max(by: { $0.value < $1.value }),
              Double(top.value) > config.startPoseShare * Double(total) else { return nil }
        return top.key
    }
}

/// A movement the user recorded, as the takes they made of it.
public struct MovementTemplate: Codable, Hashable, Sendable {
    /// The recorded takes; a movement is compared with the nearest one.
    public var takes: [MovementPath]
    /// Largest path distance to the nearest take at which a movement is still this one.
    public var threshold: Double
    /// `Trigger(pose:).key` of the pose every take started from, which a movement then has to
    /// start from too. Nil when the takes did not agree; the movement then counts from any pose.
    public var startPose: String?
    /// How much the takes differ: the largest path distance from a take to its nearest other
    /// take. When this times `thresholdSlack` is above `maxThreshold`, the takes were too
    /// different for the threshold to cover them all.
    public var spread: Double

    /// Nil with fewer than 2 usable takes: one take says nothing about how much the movement
    /// varies from one time to the next.
    public init?(takes: [MovementSegment], config: MovementConfig = MovementConfig()) {
        let usable = takes.filter { $0.path.points.count == MovementPath.pointCount }
        guard usable.count >= 2 else { return nil }
        let paths = usable.map(\.path)
        let nearest = paths.indices.map { index in
            paths.indices.filter { $0 != index }
                .map { paths[index].distance(to: paths[$0], maxTilt: config.maxTilt) }
                .min() ?? .infinity
        }
        let spread = nearest.max() ?? .infinity
        let poses = Set(usable.map { $0.startPose.map { Trigger(pose: $0).key } })

        self.takes = paths
        self.spread = spread
        threshold = min(config.maxThreshold, max(config.minThreshold, spread * config.thresholdSlack))
        startPose = poses.count == 1 ? poses.first.flatMap { $0 } : nil
    }

    /// Path distance from a movement to the nearest take, or nil when the movement cannot be
    /// this one whatever its shape: it started from another pose, or it is more than
    /// `extentTolerance` times larger or smaller, or `durationTolerance` times longer or
    /// shorter, than the takes usually were.
    public func distance(to segment: MovementSegment, config: MovementConfig = MovementConfig()) -> Double? {
        if let startPose, segment.startPose.map({ Trigger(pose: $0).key }) != startPose { return nil }
        let usualExtent = Self.median(takes.map(\.extent))
        let usualDuration = Self.median(takes.map(\.duration))
        guard Self.isWithin(segment.path.extent, of: usualExtent, factor: config.extentTolerance),
              Self.isWithin(segment.path.duration, of: usualDuration, factor: config.durationTolerance)
        else { return nil }
        return takes.map { $0.distance(to: segment.path, maxTilt: config.maxTilt) }.min()
    }

    /// Whether any take is a straight line. One is enough for the straight movements hands
    /// make by accident to match, since a movement is compared with the nearest take.
    public var isStraightLine: Bool {
        takes.contains(where: \.isStraightLine)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Whether `value` is neither more than `factor` times `usual` nor less than `usual` over `factor`.
    private static func isWithin(_ value: Double, of usual: Double, factor: Double) -> Bool {
        value <= usual * factor && value * factor >= usual
    }
}

/// Decides which recorded movement, if any, a finished movement is.
public enum MovementMatcher {
    /// The id of the movement `segment` is, or nil when it is none of them.
    ///
    /// The nearest template wins, provided the movement is within that template's threshold
    /// and at least `matchMargin` nearer to it than to the second nearest. Every template the
    /// gates let through counts as a rival, whether or not the movement is within its
    /// threshold: a movement about as near to two recorded movements is ambiguous, and doing
    /// nothing is better than running the wrong action.
    public static func match(
        _ segment: MovementSegment, among movements: [(id: String, template: MovementTemplate)],
        config: MovementConfig = MovementConfig()
    ) -> String? {
        var nearest: (id: String, distance: Double, threshold: Double)?
        var runnerUp = Double.infinity
        for (id, template) in movements {
            guard let distance = template.distance(to: segment, config: config) else { continue }
            if let best = nearest, best.distance <= distance {
                runnerUp = min(runnerUp, distance)
            } else {
                runnerUp = nearest?.distance ?? runnerUp
                nearest = (id, distance, template.threshold)
            }
        }
        guard let nearest, nearest.distance <= nearest.threshold,
              nearest.distance + config.matchMargin <= runnerUp else { return nil }
        return nearest.id
    }
}
