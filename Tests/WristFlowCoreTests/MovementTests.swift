import Foundation
import Testing
@testable import WristFlowCore

// There is NO real recording of a free hand movement yet. Every movement in this file is
// synthetic: a point that rests, traces a parametric path and rests again, with seeded noise.
// The numbers these tests pin down (thresholds, margins, tolerances) are therefore what holds
// for such paths, not for people. The only real footage used is the four gesture recordings in
// Fixtures, in which nobody makes any of these movements, so they serve as negatives.

// MARK: - Synthetic movements

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// SplitMix64, mapped to 0..<1.
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }
}

/// The movements the tests enrol and tell apart. Seen as the user sees themselves in a
/// mirror: x to their right, y up.
enum MovementShape: String, CaseIterable, CustomTestStringConvertible {
    /// From the top, towards the user's right first.
    case circleClockwise
    /// From the top, towards the user's left first.
    case circleAnticlockwise
    /// A Z: right along the top, diagonally down to the left, right along the bottom.
    case zigzag
    /// A check mark: a short stroke down to the right, then a long one up to the right.
    case tick
    /// Straight up.
    case lineUp
    /// Two periods of a sine, from left to right.
    case wave

    var testDescription: String { rawValue }

    /// The path as a polyline, in any unit.
    var outline: [Point2] {
        switch self {
        case .circleClockwise:
            return (0...96).map { step in
                let angle = 2 * Double.pi * Double(step) / 96
                return Point2(x: sin(angle), y: cos(angle))
            }
        case .circleAnticlockwise:
            return MovementShape.circleClockwise.outline.map { Point2(x: -$0.x, y: $0.y) }
        case .zigzag:
            return [Point2(x: 0, y: 1), Point2(x: 1, y: 1), Point2(x: 0, y: 0), Point2(x: 1, y: 0)]
        case .tick:
            return [Point2(x: 0, y: 0.4), Point2(x: 0.3, y: 0), Point2(x: 1, y: 1)]
        case .lineUp:
            return [Point2(x: 0, y: 0), Point2(x: 0, y: 1)]
        case .wave:
            return (0...96).map { step in
                let along = Double(step) / 96
                return Point2(x: along, y: 0.2 * sin(4 * Double.pi * along))
            }
        }
    }
}

/// One frame as the tracker is fed it.
private struct TrackedFrame {
    var time: Double
    var center: Point2
    var palmSize: Double
    var pose: Pose?
}

/// A hand that rests, makes one movement and rests again, as a camera would report it.
private struct Take {
    var shape: MovementShape
    /// Diagonal of the box around the path, in palm sizes.
    var size = 3.0
    /// Seconds from setting off to arriving.
    var duration = 1.0
    /// Seconds between two frames; each interval is drawn from this range.
    var interval: ClosedRange<Double>
    /// Palm size, in image heights.
    var palm = 0.15
    /// Largest random offset on each coordinate of each frame, in palm sizes. Real recordings
    /// of a resting hand move about 0.01 from one frame to the next.
    var jitter = 0.02
    /// Chance that a frame is missing. Never two in a row.
    var dropRate = 0.0
    /// Degrees the whole path is turned, anticlockwise.
    var tilt = 0.0
    /// The path is this many times wider and as many times less tall: a sloppy repetition.
    var stretch = 1.0
    /// Left and right swapped.
    var mirrored = false
    /// Nil: the hand sweeps through the corners of the path without slowing down. Otherwise it
    /// comes to a stop at every corner and waits there this many seconds.
    var cornerPause: Double?
    /// Pose read while the hand rests before the movement.
    var restPose: Pose? = .openPalm
    var restBefore = 0.5
    var restAfter = 0.5
    /// Where the hand rests before the movement, in image heights.
    var origin = Point2(x: 0.8, y: 0.5)
    /// Time of the first frame.
    var startTime = 0.0
    var seed: UInt64 = 1

    init(_ shape: MovementShape, fps: Double = 30) {
        self.shape = shape
        interval = 1 / fps...1 / fps
    }

    /// Readings a blurred, moving hand gives: anything, including the pose it started from.
    private static let blurredPoses: [Pose?] = [.fist, nil, .two, nil, .openPalm]
    /// Palm sizes per second from which the hand is too blurred for its pose to be read. A
    /// guess, and a low one: the tracker itself calls a hand slower than 0.8 resting.
    private static let blurSpeed = 2.0

    /// The path in palm sizes, from the origin.
    private var corners: [Point2] {
        let outline = shape.outline
        let xs = outline.map(\.x)
        let ys = outline.map(\.y)
        let diagonal = Point2(x: xs.max()! - xs.min()!, y: ys.max()! - ys.min()!).length
        let angle = tilt * .pi / 180
        return outline.map { point in
            var p = (point - outline[0]) * (size / diagonal)
            if mirrored { p.x = -p.x }
            p = Point2(x: p.x * stretch, y: p.y / stretch)
            return Point2(x: p.x * cos(angle) - p.y * sin(angle), y: p.x * sin(angle) + p.y * cos(angle))
        }
    }

    /// Where the hand rests after the movement, in image heights.
    var endPoint: Point2 {
        origin + corners[corners.count - 1] * palm
    }

    func frames() -> [TrackedFrame] {
        var random = SeededRandom(seed: seed)
        let corners = corners
        var lengths = [0.0]
        for index in corners.indices.dropFirst() {
            lengths.append(lengths[index - 1] + corners[index].distance(to: corners[index - 1]))
        }
        let strokes = corners.count - 1
        let strokeTime = duration / Double(strokes)
        let moving = duration + Double(strokes - 1) * (cornerPause ?? 0)

        /// Where the hand is `elapsed` seconds after setting off, in palm sizes from the origin.
        func position(_ elapsed: Double) -> Point2 {
            if elapsed <= 0 { return corners[0] }
            if elapsed >= moving { return corners[strokes] }
            if let cornerPause {
                // Each stroke on its own, starting and stopping, with a wait before the next.
                let stroke = min(strokes - 1, Int(elapsed / (strokeTime + cornerPause)))
                let within = (elapsed - Double(stroke) * (strokeTime + cornerPause)) / strokeTime
                return corners[stroke] + (corners[stroke + 1] - corners[stroke]) * Self.eased(within)
            }
            let target = Self.eased(elapsed / duration) * lengths[lengths.count - 1]
            let leg = max(1, lengths.firstIndex { $0 >= target } ?? lengths.count - 1)
            let within = (target - lengths[leg - 1]) / (lengths[leg] - lengths[leg - 1])
            return corners[leg - 1] + (corners[leg] - corners[leg - 1]) * within
        }

        var frames: [TrackedFrame] = []
        var elapsed = -restBefore
        var index = 0
        var dropped = false
        while elapsed <= moving + restAfter {
            let noise = Point2(x: random.uniform(-jitter...jitter), y: random.uniform(-jitter...jitter))
            let speed = position(elapsed + 0.005).distance(to: position(elapsed - 0.005)) / 0.01
            let drop = !dropped && random.unit() < dropRate
            if !drop {
                frames.append(TrackedFrame(
                    time: startTime + restBefore + elapsed,
                    center: origin + (position(elapsed) + noise) * palm,
                    palmSize: palm,
                    pose: speed < Self.blurSpeed ? restPose : Self.blurredPoses[index % Self.blurredPoses.count]
                ))
            }
            dropped = drop
            index += 1
            elapsed += random.uniform(interval)
        }
        return frames
    }

    /// Progress along the path at a share of the time: slow away from rest and slow into it,
    /// the way a hand moves (minimum jerk).
    private static func eased(_ share: Double) -> Double {
        let u = min(1, max(0, share))
        return u * u * u * (10 - 15 * u + 6 * u * u)
    }
}

/// Every movement the tracker cuts out of `frames`.
private func segments(in frames: [TrackedFrame], config: MovementConfig = MovementConfig()) -> [MovementSegment] {
    var tracker = MovementTracker(config: config)
    return frames.compactMap { tracker.ingest(time: $0.time, center: $0.center, palmSize: $0.palmSize, pose: $0.pose) }
}

/// The one movement in a take.
private func segment(of take: Take) throws -> MovementSegment {
    let found = segments(in: take.frames())
    try #require(found.count == 1, "\(take.shape) seed \(take.seed) gave \(found.count) segments")
    return found[0]
}

/// A take the way a person might repeat a movement: up to 10% larger or smaller, 15% faster
/// or slower, tilted by up to 8 degrees and 10% out of proportion, with a tenth of the frames
/// missing. `scale` and `pace` multiply the usual 3 palm sizes and 1.2 seconds.
private func sloppyTake(
    _ shape: MovementShape, seed: UInt64, fps: Double = 30, scale: Double = 1, pace: Double = 1
) -> Take {
    var random = SeededRandom(seed: seed &* 7919 &+ 13)
    var take = Take(shape, fps: fps)
    take.seed = seed
    take.size = 3 * scale * random.uniform(0.9...1.1)
    take.duration = 1.2 * pace * random.uniform(0.85...1.15)
    take.tilt = random.uniform(-8...8)
    take.stretch = random.uniform(0.9...1.1)
    take.dropRate = 0.1
    take.palm = random.uniform(0.1...0.25)
    return take
}

/// Several takes one after the other, each starting where and when the one before ended.
private func chained(_ takes: [Take]) -> [TrackedFrame] {
    var frames: [TrackedFrame] = []
    var origin = takes.first?.origin ?? .zero
    var time = 0.0
    for var take in takes {
        take.origin = origin
        take.startTime = time
        let made = take.frames()
        frames += made
        origin = take.endPoint
        time = (made.last?.time ?? time) + take.interval.lowerBound
    }
    return frames
}

/// A movement enrolled from four takes of about the same size and speed, all starting from
/// `startPose`.
private func enrolled(
    _ shape: MovementShape, startPose: Pose? = nil, firstSeed: UInt64 = 1000
) throws -> MovementTemplate {
    let takes = try (firstSeed..<firstSeed + 4).map { seed -> MovementSegment in
        var take = sloppyTake(shape, seed: seed)
        take.restPose = startPose
        return try segment(of: take)
    }
    return try #require(MovementTemplate(takes: takes))
}

/// The given shapes enrolled without a starting pose, each under its own name.
private func library(
    of shapes: [MovementShape] = MovementShape.allCases
) throws -> [(id: String, template: MovementTemplate)] {
    try shapes.map { (id: $0.rawValue, template: try enrolled($0)) }
}

/// Repetitions of a shape that were not enrolled: smaller and larger, faster and slower.
private func repetitions(of shape: MovementShape, fps: Double) -> [Take] {
    var takes: [Take] = []
    for scale in [0.7, 1.0, 1.4] {
        for pace in [0.7, 1.0, 1.6] {
            for _ in 0..<3 {
                let seed = UInt64(fps) * 100 + UInt64(takes.count)
                takes.append(sloppyTake(shape, seed: seed, fps: fps, scale: scale, pace: pace))
            }
        }
    }
    return takes
}

private let fixtureNames = ["wrist-flick-swipes", "palm-and-back", "hand-at-face", "finger-counts"]

/// Every movement the tracker cuts out of a landmark recording, following the largest hand of
/// each frame that is near enough to use, with no pose read on it.
private func recordedSegments(in name: String) throws -> [MovementSegment] {
    let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    var tracker = MovementTracker()
    var found: [MovementSegment] = []
    for frame in try Recording.load(folder.appendingPathComponent("\(name).jsonl")) {
        guard case .hands(let hands) = frame,
              let hand = hands.hands.filter({ $0.palmSize >= 0.06 }).max(by: { $0.palmSize < $1.palmSize })
        else { continue }
        let ended = tracker.ingest(time: hands.time, center: hand.palmCenter, palmSize: hand.palmSize, pose: nil)
        if let ended { found.append(ended) }
    }
    return found
}

// MARK: - Tracker

@Suite struct MovementTrackerTests {
    @Test(arguments: MovementShape.allCases, [10.0, 15, 30])
    func restMoveRestGivesExactlyOneSegment(shape: MovementShape, fps: Double) throws {
        for seed in UInt64(1)...5 {
            var take = Take(shape, fps: fps)
            take.dropRate = 0.1
            take.seed = seed
            let found = segments(in: take.frames())
            try #require(found.count == 1, "seed \(seed): \(found.count) segments")
            let movement = found[0]

            // It starts at the last still frame and ends at the first one, so it may begin a
            // frame or two early and loses the slow first and last stretch of the path.
            let slack = 2 / fps + 1e-6
            #expect(movement.start >= take.restBefore - slack)
            #expect(movement.start <= take.restBefore + 0.35 * take.duration)
            #expect(movement.end >= take.restBefore + 0.65 * take.duration)
            #expect(movement.end <= take.restBefore + take.duration + slack)
            // The fewer the frames, the more the corners of the path are cut.
            #expect(abs(movement.path.extent - take.size) < 0.25 + 4 / fps)
            #expect(abs(movement.path.duration - (movement.end - movement.start)) < 1e-4)
        }
    }

    @Test(arguments: MovementShape.allCases)
    func framesMayComeAtIrregularIntervals(shape: MovementShape) {
        for seed in UInt64(1)...5 {
            var take = Take(shape)
            take.interval = 1.0 / 30...1.0 / 10
            take.seed = seed
            #expect(segments(in: take.frames()).count == 1, "seed \(seed)")
        }
    }

    @Test func movementsInARowEachGiveASegment() {
        let frames = chained([Take(.lineUp), Take(.tick), Take(.circleClockwise), Take(.zigzag)])
        let found = segments(in: frames)
        #expect(found.count == 4)
        for (earlier, later) in zip(found, found.dropFirst()) {
            #expect(earlier.end < later.start)
        }
    }

    @Test(arguments: MovementShape.allCases)
    func handThatAppearsMovingGivesNoSegment(shape: MovementShape) {
        let take = Take(shape)
        // The first frame already shows the hand a fifth of the way along: no rest before it.
        let raised = take.frames().filter { $0.time >= take.restBefore + 0.2 * take.duration }
        #expect(segments(in: raised).isEmpty)

        // Having come to rest, it can start a movement like any other hand.
        var next = Take(.wave)
        next.origin = take.endPoint
        next.startTime = (raised.last?.time ?? 0) + 1.0 / 30
        #expect(segments(in: raised + next.frames()).count == 1)
    }

    @Test(arguments: MovementShape.allCases)
    func handThatLeavesBeforeRestingGivesNoSegment(shape: MovementShape) {
        let take = Take(shape)
        let cutShort = take.frames().filter { $0.time <= take.restBefore + 0.8 * take.duration }
        #expect(segments(in: cutShort).isEmpty)

        // Seconds later a hand is resting somewhere else. That is not where the movement ended.
        let back = (0..<30).map { index in
            TrackedFrame(time: 5 + Double(index) / 30, center: Point2(x: 0.3, y: 0.3), palmSize: take.palm, pose: nil)
        }
        #expect(segments(in: cutShort + back).isEmpty)
    }

    @Test func resetForgetsTheMovementUnderWay() {
        let take = Take(.circleClockwise)
        var tracker = MovementTracker()
        var found: [MovementSegment] = []
        let halfWay = take.restBefore + 0.5 * take.duration
        for frame in take.frames() {
            if frame.time > halfWay, frame.time <= halfWay + 1.0 / 30 {
                #expect(tracker.isMoving)
                tracker.reset()
                #expect(!tracker.isMoving)
                #expect(tracker.trail.isEmpty)
            }
            let ended = tracker.ingest(time: frame.time, center: frame.center, palmSize: frame.palmSize, pose: frame.pose)
            if let ended { found.append(ended) }
        }
        #expect(found.isEmpty)
    }

    @Test(arguments: MovementShape.allCases)
    func smallDriftGivesNoSegment(shape: MovementShape) {
        for size in [0.3, 0.8, 1.3] {
            var take = Take(shape)
            take.size = size
            #expect(segments(in: take.frames()).isEmpty, "size \(size)")
        }
    }

    @Test func handHeldStillGivesNoSegment() {
        // Ten seconds of a hand whose landmarks tremble by a third of the rest radius.
        var random = SeededRandom(seed: 1)
        let palm = 0.15
        let frames = (0..<300).map { index in
            let tremble = Point2(x: random.uniform(-0.04...0.04), y: random.uniform(-0.04...0.04))
            return TrackedFrame(
                time: Double(index) / 30, center: Point2(x: 0.8, y: 0.5) + tremble * palm, palmSize: palm, pose: .fist
            )
        }
        var tracker = MovementTracker()
        for frame in frames {
            let ended = tracker.ingest(time: frame.time, center: frame.center, palmSize: frame.palmSize, pose: frame.pose)
            #expect(ended == nil)
            #expect(!tracker.isMoving)
        }
    }

    @Test(arguments: [10.0, 30])
    func longGapAbandonsTheMovement(fps: Double) {
        let take = Take(.circleClockwise, fps: fps)
        let middle = take.restBefore + 0.5 * take.duration
        /// The take with the frames of `seconds` around the middle of the movement missing.
        func withGap(_ seconds: Double) -> [TrackedFrame] {
            take.frames().filter { abs($0.time - middle) > seconds / 2 }
        }
        #expect(segments(in: withGap(0.35)).isEmpty)
        // A gap within `maxGap` is a few lost frames, and the movement goes on.
        #expect(segments(in: withGap(0.12)).count == 1)
    }

    @Test func clockRunningBackwardsStartsOver() {
        let frames = Take(.tick).frames()
        #expect(segments(in: frames + frames).count == 2)
        // Without its starting rest the second run is a hand that appears moving.
        let moving = frames.filter { $0.time >= 0.7 }
        #expect(segments(in: frames + moving).count == 1)
    }

    @Test func tooQuickOrTooSlowIsNoMovement() {
        var flick = Take(.lineUp)
        flick.duration = 0.25
        #expect(segments(in: flick.frames()).isEmpty)

        var crawl = Take(.circleClockwise)
        crawl.size = 12
        crawl.duration = 4.5
        #expect(segments(in: crawl.frames()).isEmpty)

        // The limits are the configured ones.
        var patient = MovementConfig()
        patient.maxDuration = 6
        #expect(segments(in: crawl.frames(), config: patient).count == 1)
        var hasty = MovementConfig()
        hasty.minDuration = 0.05
        #expect(segments(in: flick.frames(), config: hasty).count == 1)
    }

    // MARK: Corners

    @Test func briskStrokesThatStopAtCornersAreOneMovement() throws {
        var take = Take(.tick)
        take.size = 5
        take.duration = 0.5
        take.cornerPause = 0
        let found = segments(in: take.frames())
        try #require(found.count == 1)
        #expect(!found[0].path.isStraightLine)
    }

    /// The limit of cutting by rests: a hand that lingers at a corner for `restTime` has, as far
    /// as the tracker can tell, finished one movement and begun another.
    @Test func lingeringAtACornerCutsTheMovementInTwo() {
        var take = Take(.tick)
        take.size = 5
        take.duration = 1.2
        take.cornerPause = 0.2
        let found = segments(in: take.frames())
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.path.isStraightLine })
    }

    // MARK: Starting pose

    @Test(arguments: [Pose.fist, .openPalm, .one, .custom("mine")])
    func startPoseIsThePoseOfTheStartingRest(pose: Pose) throws {
        for fps in [10.0, 30] {
            var take = Take(.wave, fps: fps)
            take.restPose = pose
            // Whatever is read on the hand once it moves fast enough to blur does not count.
            #expect(try segment(of: take).startPose == pose)
        }
    }

    @Test func startPoseIsNilWhenNoneWasRead() throws {
        var take = Take(.wave)
        take.restPose = nil
        #expect(try segment(of: take).startPose == nil)
    }

    @Test func startPoseIsNilWhenNoPoseDominated() throws {
        var take = Take(.wave)
        take.restPose = nil
        // Three poses taking turns while the hand rests: none is read on more than half the frames.
        let flickering: [Pose] = [.one, .two, .three]
        let frames = take.frames().enumerated().map { index, frame -> TrackedFrame in
            var changed = frame
            if frame.time <= take.restBefore { changed.pose = flickering[index % flickering.count] }
            return changed
        }
        let found = segments(in: frames)
        try #require(found.count == 1)
        #expect(found[0].startPose == nil)
    }

    @Test func startPoseIsTheOneHeldJustBeforeMoving() throws {
        var take = Take(.wave)
        take.restBefore = 2
        take.restPose = .fist
        // An open palm for most of the rest; the fist only for the last 0.35 s of it.
        let frames = take.frames().map { frame -> TrackedFrame in
            var changed = frame
            if frame.time < take.restBefore - 0.35 { changed.pose = .openPalm }
            return changed
        }
        let found = segments(in: frames)
        try #require(found.count == 1)
        #expect(found[0].startPose == .fist)
    }

    // MARK: Live view

    @Test func trailFollowsTheMovementUnderWay() {
        let take = Take(.circleAnticlockwise)
        var tracker = MovementTracker()
        var longest = 0
        var ended = false
        for frame in take.frames() {
            let segment = tracker.ingest(time: frame.time, center: frame.center, palmSize: frame.palmSize, pose: frame.pose)
            if segment != nil { ended = true }
            #expect(tracker.isMoving == !tracker.trail.isEmpty)
            if frame.time < take.restBefore - 0.05 || ended {
                #expect(!tracker.isMoving, "at \(frame.time)")
            }
            if frame.time > take.restBefore + 0.3 * take.duration, frame.time < take.restBefore + 0.7 * take.duration {
                #expect(tracker.isMoving, "at \(frame.time)")
                // Raw palm centres, oldest first: from where the hand rested to where it is now.
                #expect(tracker.trail.count > longest)
                #expect(tracker.trail.last == frame.center)
                #expect((tracker.trail.first?.distance(to: take.origin) ?? 1) < 0.15 * take.palm)
                longest = tracker.trail.count
            }
        }
        #expect(ended)
        #expect(longest > 5)
    }
}

// MARK: - Paths

@Suite struct MovementPathTests {
    @Test(arguments: MovementShape.allCases)
    func pathIsResampledCentredAndScaled(shape: MovementShape) throws {
        let path = try segment(of: Take(shape)).path
        #expect(path.points.count == MovementPath.pointCount)

        let centroid = path.points.reduce(Point2.zero, +) * (1 / Double(path.points.count))
        #expect(centroid.length < 1e-3)
        let width = path.points.map(\.x).max()! - path.points.map(\.x).min()!
        let height = path.points.map(\.y).max()! - path.points.map(\.y).min()!
        #expect(abs(max(width, height) - 1) < 1e-3)
        for point in path.points {
            #expect((point.x * 10_000).rounded() / 10_000 == point.x)
            #expect((point.y * 10_000).rounded() / 10_000 == point.y)
        }
    }

    @Test func pointsAreEquallySpacedAlongThePath() throws {
        // Unevenly timed frames of a hand that speeds up and slows down.
        let centers = [0, 0.01, 0.05, 0.2, 0.25, 0.7, 0.9, 0.98, 1].map { Point2(x: 0.5, y: 0.2 + 0.6 * $0) }
        let path = try #require(MovementPath(centers: centers, palmSize: 0.2, duration: 1))
        for (index, point) in path.points.enumerated() {
            #expect(abs(point.y - (Double(index) / 31 - 0.5)) < 1e-4)
            #expect(point.x == 0)
        }
        #expect(path.extent == 3)
        #expect(path.duration == 1)
    }

    @Test func handThatWentNowhereHasNoPath() {
        let spot = Point2(x: 0.4, y: 0.4)
        #expect(MovementPath(centers: [], palmSize: 0.2, duration: 1) == nil)
        #expect(MovementPath(centers: [spot], palmSize: 0.2, duration: 1) == nil)
        #expect(MovementPath(centers: [spot, spot, spot], palmSize: 0.2, duration: 1) == nil)
        #expect(MovementPath(centers: [spot, .zero], palmSize: 0, duration: 1) == nil)
    }

    @Test(arguments: MovementShape.allCases)
    func sameMovementIsTheSamePathAnywhereAtAnySizeAndSpeed(shape: MovementShape) throws {
        let reference = try segment(of: Take(shape)).path
        var other = Take(shape, fps: 15)
        other.origin = Point2(x: 0.3, y: 0.2)
        other.palm = 0.08
        other.size = 4.5
        other.duration = 1.8
        other.seed = 9
        let path = try segment(of: other).path
        #expect(reference.distance(to: path) < 0.05)
        #expect(abs(reference.distance(to: path) - path.distance(to: reference)) < 1e-12)
        #expect(reference.distance(to: reference) == 0)
        #expect(abs(path.extent - 4.5) < 0.5)
    }

    @Test func directionMatters() throws {
        let clockwise = try segment(of: Take(.circleClockwise)).path
        let anticlockwise = try segment(of: Take(.circleAnticlockwise)).path
        #expect(clockwise.distance(to: anticlockwise) > 0.4)

        let up = try segment(of: Take(.lineUp)).path
        var downwards = Take(.lineUp)
        downwards.tilt = 180
        #expect(up.distance(to: try segment(of: downwards).path) > 0.4)
        var sideways = Take(.lineUp)
        sideways.tilt = 90
        #expect(up.distance(to: try segment(of: sideways).path) > 0.3)

        let zigzag = try segment(of: Take(.zigzag)).path
        var mirrored = Take(.zigzag)
        mirrored.mirrored = true
        #expect(zigzag.distance(to: try segment(of: mirrored).path) > 0.4)
    }

    /// Why the tilt is taken out rather than left to the threshold: 15 degrees of tilt alone
    /// put a path 0.07 to 0.15 away from itself, which is the whole of the lowest threshold, and
    /// taken out they leave the 0.02 or less that two takes differ by anyway. Measured on 324
    /// synthetic repetitions leaning 15 degrees more than the enrolled takes: left in, 110 are
    /// over 0.10 from their template (up to 0.18); taken out, 1 is (0.102). What it costs is
    /// that shapes which are nearly one another at a different angle come closer: the tick and
    /// the line up go from 0.19 to 0.13 apart. The nearest movement in the gesture recordings
    /// stays at 0.23.
    @Test(arguments: MovementShape.allCases, [-15.0, 15])
    func smallTiltIsTakenOut(shape: MovementShape, tilt: Double) throws {
        let upright = try segment(of: Take(shape)).path
        var take = Take(shape)
        take.tilt = tilt
        take.seed = 2
        let tilted = try segment(of: take).path
        let asCompared = upright.distance(to: tilted)
        let leftIn = upright.distance(to: tilted, maxTilt: 0)
        #expect(asCompared < 0.03)
        #expect(leftIn > 0.06)
        #expect(leftIn > asCompared + 0.05)
    }

    @Test(arguments: MovementShape.allCases, [-60.0, 60])
    func largeTiltIsADifferentMovement(shape: MovementShape, tilt: Double) throws {
        let upright = try segment(of: Take(shape)).path
        var take = Take(shape)
        take.tilt = tilt
        #expect(upright.distance(to: try segment(of: take).path) > MovementConfig().maxThreshold)
    }

    @Test func pathsOfDifferentLengthsCannotBeCompared() throws {
        let path = try segment(of: Take(.wave)).path
        var shorter = path
        shorter.points.removeLast()
        #expect(path.distance(to: shorter) == .infinity)
        shorter.points = []
        #expect(shorter.distance(to: shorter) == .infinity)
    }

    @Test func onlyALineIsAStraightLine() throws {
        for shape in MovementShape.allCases {
            for tilt in [0.0, 37, 90, 200] {
                var take = Take(shape)
                take.tilt = tilt
                let path = try segment(of: take).path
                #expect(path.isStraightLine == (shape == .lineUp), "\(shape) tilted \(tilt): \(path.straightness)")
            }
        }
    }

    @Test func pathSurvivesCoding() throws {
        let path = try segment(of: Take(.tick)).path
        let decoded = try JSONDecoder().decode(MovementPath.self, from: JSONEncoder().encode(path))
        #expect(decoded == path)
    }
}

// MARK: - Templates and matching

@Suite struct MovementMatcherTests {
    @Test(arguments: MovementShape.allCases, [15.0, 30])
    func enrolledShapeIsRecognisedAtOtherSizesAndSpeeds(shape: MovementShape, fps: Double) throws {
        let movements = try library()
        for take in repetitions(of: shape, fps: fps) {
            let made = try segment(of: take)
            let match = MovementMatcher.match(made, among: movements)
            #expect(match == shape.rawValue, "seed \(take.seed), size \(take.size), \(take.duration) s")
        }
    }

    /// The worst case for a wrong match: the shape that was made is not there to win.
    @Test(arguments: MovementShape.allCases, [15.0, 30])
    func shapeThatWasNotEnrolledMatchesNothing(shape: MovementShape, fps: Double) throws {
        let others = try library(of: MovementShape.allCases.filter { $0 != shape })
        for take in repetitions(of: shape, fps: fps) {
            let match = MovementMatcher.match(try segment(of: take), among: others)
            #expect(match == nil, "seed \(take.seed)")
        }
    }

    @Test func clockwiseAndAnticlockwiseCirclesAreToldApart() throws {
        let clockwise = try enrolled(.circleClockwise)
        for take in repetitions(of: .circleAnticlockwise, fps: 30) {
            let made = try segment(of: take)
            #expect(MovementMatcher.match(made, among: [("clockwise", clockwise)]) == nil)
            #expect((clockwise.distance(to: made) ?? 1) > 2 * clockwise.threshold)
        }
    }

    @Test func mirroredZigzagIsNotTheZigzag() throws {
        let zigzag = try enrolled(.zigzag)
        for var take in repetitions(of: .zigzag, fps: 30) {
            #expect(MovementMatcher.match(try segment(of: take), among: [("zigzag", zigzag)]) == "zigzag")
            take.mirrored = true
            let mirrored = try segment(of: take)
            #expect(MovementMatcher.match(mirrored, among: [("zigzag", zigzag)]) == nil)
            #expect((zigzag.distance(to: mirrored) ?? 1) > 2 * zigzag.threshold)
        }
    }

    @Test(arguments: MovementShape.allCases)
    func tiltedRepetitionIsStillRecognised(shape: MovementShape) throws {
        let movements = try library()
        for tilt in [-15.0, 15] {
            var take = Take(shape)
            take.tilt = tilt
            #expect(MovementMatcher.match(try segment(of: take), among: movements) == shape.rawValue, "tilt \(tilt)")
        }
    }

    // MARK: Gates

    @Test func movementHasToStartFromTheEnrolledPose() throws {
        let fromFist = try enrolled(.circleClockwise, startPose: .fist)
        #expect(fromFist.startPose == Trigger.fist.key)

        var take = sloppyTake(.circleClockwise, seed: 1)
        take.restPose = .fist
        let rightPose = try segment(of: take)
        #expect(MovementMatcher.match(rightPose, among: [("circle", fromFist)]) == "circle")

        for pose in [Pose.openPalm, .one, nil] {
            take.restPose = pose
            let wrongPose = try segment(of: take)
            #expect(fromFist.distance(to: wrongPose) == nil)
            #expect(MovementMatcher.match(wrongPose, among: [("circle", fromFist)]) == nil)
        }
    }

    @Test func recordedShapeCanBeTheStartingPose() throws {
        let template = try enrolled(.tick, startPose: .custom("horns"))
        #expect(template.startPose == Trigger.custom("horns").key)
        var take = sloppyTake(.tick, seed: 1)
        take.restPose = .custom("horns")
        #expect(template.distance(to: try segment(of: take)) != nil)
        take.restPose = .custom("other")
        #expect(template.distance(to: try segment(of: take)) == nil)
    }

    @Test func takesFromDifferentPosesLeaveThePoseFree() throws {
        let poses: [Pose?] = [.fist, .fist, .openPalm, .fist]
        let takes = try poses.enumerated().map { index, pose -> MovementSegment in
            var take = sloppyTake(.wave, seed: 1000 + UInt64(index))
            take.restPose = pose
            return try segment(of: take)
        }
        let template = try #require(MovementTemplate(takes: takes))
        #expect(template.startPose == nil)
        #expect(try enrolled(.wave, startPose: nil).startPose == nil)

        var take = sloppyTake(.wave, seed: 1)
        take.restPose = .three
        #expect(MovementMatcher.match(try segment(of: take), among: [("wave", template)]) == "wave")
    }

    @Test func muchLargerOrSmallerMovementIsNotTheSame() throws {
        // Enrolled at about 3 palm sizes across.
        let template = try enrolled(.circleClockwise)
        for (size, isAllowed) in [(1.7, true), (5.0, true), (7.5, false)] {
            var take = Take(.circleClockwise)
            take.size = size
            take.palm = 0.1
            #expect((template.distance(to: try segment(of: take)) != nil) == isAllowed, "size \(size)")
        }
        // 1.5 palm sizes is the least the tracker reports, so only a template of large takes
        // can be undercut.
        let large = try #require(MovementTemplate(takes: (UInt64(1)...4).map { seed in
            var take = Take(.circleClockwise)
            take.size = 5
            take.palm = 0.1
            take.seed = seed
            return try segment(of: take)
        }))
        var small = Take(.circleClockwise)
        small.size = 2
        #expect(large.distance(to: try segment(of: small)) == nil)
    }

    @Test func muchFasterOrSlowerMovementIsNotTheSame() throws {
        // Enrolled at about 1.2 s from start to stop.
        let template = try enrolled(.wave)
        for (duration, isAllowed) in [(0.5, false), (0.8, true), (2.0, true), (3.2, false)] {
            var take = Take(.wave)
            take.duration = duration
            #expect((template.distance(to: try segment(of: take)) != nil) == isAllowed, "\(duration) s")
        }
    }

    // MARK: Choosing between templates

    @Test(arguments: MovementShape.allCases)
    func movementAsNearToTwoTemplatesIsNeither(shape: MovementShape) throws {
        // The same movement enrolled twice, from different takes.
        let first = try enrolled(shape, firstSeed: 1000)
        let second = try enrolled(shape, firstSeed: 2000)
        for take in repetitions(of: shape, fps: 30) {
            let made = try segment(of: take)
            #expect(MovementMatcher.match(made, among: [("first", first)]) == "first")
            #expect(MovementMatcher.match(made, among: [("second", second)]) == "second")
            #expect(MovementMatcher.match(made, among: [("first", first), ("second", second)]) == nil)
        }
    }

    @Test func rivalThatAGateRulesOutDoesNotCount() throws {
        let fromFist = try enrolled(.zigzag, startPose: .fist, firstSeed: 1000)
        let fromPalm = try enrolled(.zigzag, startPose: .openPalm, firstSeed: 2000)
        var take = sloppyTake(.zigzag, seed: 1)
        take.restPose = .openPalm
        let made = try segment(of: take)
        #expect(MovementMatcher.match(made, among: [("fist", fromFist), ("palm", fromPalm)]) == "palm")
    }

    @Test func marginIsConfigurable() throws {
        let tick = try enrolled(.tick)
        let line = try enrolled(.lineUp)
        let made = try segment(of: sloppyTake(.tick, seed: 1))
        let movements = [(id: "tick", template: tick), (id: "line", template: line)]
        #expect(MovementMatcher.match(made, among: movements) == "tick")

        // A tick is not half a path width nearer to itself than to a line.
        var strict = MovementConfig()
        strict.matchMargin = 0.5
        #expect(MovementMatcher.match(made, among: movements, config: strict) == nil)
        #expect(MovementMatcher.match(made, among: [(id: "tick", template: tick)], config: strict) == "tick")
    }

    @Test func nothingEnrolledMatchesNothing() throws {
        #expect(MovementMatcher.match(try segment(of: Take(.wave)), among: []) == nil)
    }

    // MARK: Enrolling

    @Test func templateNeedsTwoTakes() throws {
        let takes = try (UInt64(1)...2).map { try segment(of: sloppyTake(.wave, seed: $0)) }
        #expect(MovementTemplate(takes: []) == nil)
        #expect(MovementTemplate(takes: [takes[0]]) == nil)
        #expect(MovementTemplate(takes: takes)?.takes.count == 2)

        var broken = takes[1]
        broken.path.points.removeLast(5)
        #expect(MovementTemplate(takes: [takes[0], broken]) == nil)
        #expect(MovementTemplate(takes: takes + [broken])?.takes.count == 2)
    }

    @Test(arguments: MovementShape.allCases)
    func thresholdIsLearnedFromHowMuchTheTakesDiffer(shape: MovementShape) throws {
        let takes = try (UInt64(1000)..<1004).map { try segment(of: sloppyTake(shape, seed: $0)) }
        var unbounded = MovementConfig()
        unbounded.minThreshold = 0
        unbounded.maxThreshold = 10
        let free = try #require(MovementTemplate(takes: takes, config: unbounded))

        // The take that is farthest from its nearest neighbour sets the spread.
        let paths = takes.map(\.path)
        let nearest = paths.indices.map { index in
            paths.indices.filter { $0 != index }.map { paths[index].distance(to: paths[$0]) }.min()!
        }
        #expect(free.spread == nearest.max())
        #expect(free.threshold == free.spread * unbounded.thresholdSlack)

        // Takes this alike would give a threshold too tight for the next day; it is held up.
        let bounded = try #require(MovementTemplate(takes: takes))
        #expect(bounded.spread == free.spread)
        #expect(bounded.spread < 0.06)
        #expect(bounded.threshold == MovementConfig().minThreshold)
    }

    @Test func takesThatDifferTooMuchAreHeldToTheHighestThreshold() throws {
        let takes = try [MovementShape.tick, .wave, .zigzag, .lineUp].map { try segment(of: Take($0)) }
        let template = try #require(MovementTemplate(takes: takes))
        let config = MovementConfig()
        #expect(template.spread * config.thresholdSlack > config.maxThreshold)
        #expect(template.threshold == config.maxThreshold)
    }

    @Test func templateWithAStraightTakeIsAStraightLine() throws {
        #expect(try enrolled(.lineUp).isStraightLine)
        for shape in MovementShape.allCases where shape != .lineUp {
            #expect(try !enrolled(shape).isStraightLine)
        }
        let mixed = try [MovementShape.wave, .wave, .lineUp].map { try segment(of: Take($0)) }
        #expect(MovementTemplate(takes: mixed)?.isStraightLine == true)
    }

    // MARK: Files

    @Test func templateSurvivesCoding() throws {
        for pose in [Pose.fist, nil] {
            let template = try enrolled(.circleAnticlockwise, startPose: pose)
            let decoded = try JSONDecoder().decode(MovementTemplate.self, from: JSONEncoder().encode(template))
            #expect(decoded == template)
        }
        let gesture = CustomGesture(id: "circle", name: "Circle", movement: try enrolled(.circleClockwise))
        var stored = GestureLibrary()
        stored.customGestures = [gesture]
        let library = try JSONDecoder().decode(GestureLibrary.self, from: JSONEncoder().encode(stored))
        #expect(library == stored)
        let made = try segment(of: sloppyTake(.circleClockwise, seed: 1))
        #expect(MovementMatcher.match(made, among: library.movements) == "circle")
    }

    @Test func configSurvivesCoding() throws {
        var config = MovementConfig()
        config.restRadius = 0.2
        config.matchMargin = 0.5
        let decoded = try JSONDecoder().decode(MovementConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    @Test func configFromAnOlderFileKeepsDefaults() throws {
        let config = try JSONDecoder().decode(MovementConfig.self, from: Data(#"{"minExtent": 2}"#.utf8))
        var expected = MovementConfig()
        expected.minExtent = 2
        #expect(config == expected)
    }

    // MARK: Recorded footage

    /// Nobody makes a circle, a zigzag, a tick or a wave in the gesture recordings, so whatever
    /// the tracker cuts out of them must match nothing. The templates have no starting pose,
    /// which is the worst case: nothing but the path, its size and its duration can rule a
    /// movement out.
    ///
    /// Measured when this was written: 1 segment in wrist-flick-swipes, 1 in palm-and-back, 3 in
    /// hand-at-face, 0 in finger-counts. The nearest any of them comes to any take is 0.233
    /// (palm-and-back, to the clockwise circle); the others are 0.27 or more away.
    @Test func recordedGesturesMatchNoMovement() throws {
        let movements = try library()
        let config = MovementConfig()
        var total = 0
        for name in fixtureNames {
            for made in try recordedSegments(in: name) {
                total += 1
                let label = "\(name) at \(made.start) s"
                #expect(MovementMatcher.match(made, among: movements) == nil, "\(label)")
                for (id, template) in movements {
                    // On its own, so that no rival can be what keeps it from matching.
                    #expect(MovementMatcher.match(made, among: [(id, template)]) == nil, "\(label) as \(id)")
                    // Nor would it match with the widest threshold and no gate on size or duration.
                    let nearest = template.takes.map { $0.distance(to: made.path) }.min() ?? 0
                    #expect(nearest > config.maxThreshold, "\(label) is \(nearest) from \(id)")
                }
            }
        }
        // The recordings do contain hands that rest, move and rest again.
        #expect(total >= 3)
    }
}
