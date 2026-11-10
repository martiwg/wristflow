import Foundation
import Testing
@testable import WristFlowCore

// A user simulated from geometry, so the tests do not feed the classifier its own assumptions:
// a head somewhere in front of the camera, displays as rectangles in space, and head angles
// that follow the direction from the head to the point being looked at.
//
// Metres. The camera is the origin, on top of the laptop screen; x runs to the user's right,
// y up, z from the camera towards the user.

private struct Vec3 {
    var x: Double
    var y: Double
    var z: Double
}

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// SplitMix64, mapped to 0..<1.
    mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12)
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * uniform())
    }
}

private struct SimDisplay {
    var id: String
    var center: Vec3
    var width: Double
    var height: Double

    /// `u` and `v` run from -1 to 1 across the width and the height.
    func point(_ u: Double, _ v: Double) -> Vec3 {
        Vec3(x: center.x + u * width / 2, y: center.y + v * height / 2, z: center.z)
    }

    static let laptop = SimDisplay(id: "laptop", center: Vec3(x: 0, y: -0.115, z: 0), width: 0.30, height: 0.19)
    static let above = SimDisplay(id: "above", center: Vec3(x: 0, y: 0.32, z: -0.20), width: 0.60, height: 0.34)
    static let side = SimDisplay(id: "side", center: Vec3(x: 0.60, y: 0.10, z: -0.05), width: 0.60, height: 0.34)
    static let left = SimDisplay(id: "left", center: Vec3(x: -0.60, y: 0.10, z: -0.05), width: 0.60, height: 0.34)
}

private struct SimUser {
    var head = Vec3(x: 0, y: 0.18, z: 0.60)
    /// Share of every turn done by the eyes; the head does the rest.
    var eyeShare = 0.3
    /// Chance that the eyes cannot be read in a frame.
    var pupilDropout = 0.0
    var random: SeededRandom

    /// Eye rotation, in radians, that takes the pupil from the middle of the eye to its corner.
    static let eyeRange = 0.7
    /// The face sits this far in front of the axis the head turns about.
    static let neckToFace = 0.08
    static let faceHeight = 0.22
    /// Image heights per unit of tangent, for a camera with a 50 degree vertical field of view.
    static let imageScale = 1 / (2 * tan(25 * Double.pi / 180))
    static let aspect = 16.0 / 9.0

    init(seed: UInt64) { random = SeededRandom(seed: seed) }

    mutating func face(lookingAt target: Vec3, time: Double) -> FaceFrame {
        let dx = target.x - head.x
        let dy = target.y - head.y
        let forward = head.z - target.z
        let gazeYaw = atan2(dx, forward)
        let gazePitch = atan2(dy, (dx * dx + forward * forward).squareRoot())
        let yaw = (1 - eyeShare) * gazeYaw + 0.012 * random.gaussian()
        let pitch = (1 - eyeShare) * gazePitch + 0.012 * random.gaussian()

        // Turning the head swings the face sideways, so its position in the image follows the
        // display too, by a little.
        let faceX = head.x + Self.neckToFace * sin(yaw)
        let faceY = head.y + Self.neckToFace * sin(pitch)
        let center = Point2(
            x: Self.aspect / 2 + faceX / head.z * Self.imageScale + 0.004 * random.gaussian(),
            y: 0.5 + faceY / head.z * Self.imageScale + 0.004 * random.gaussian()
        )
        let size = Self.faceHeight / head.z * Self.imageScale + 0.004 * random.gaussian()

        var pupils: Point2?
        let dropped = random.uniform() < pupilDropout
        if !dropped {
            pupils = Point2(
                x: min(1, max(-1, eyeShare * gazeYaw / Self.eyeRange + 0.08 * random.gaussian())),
                y: min(1, max(-1, eyeShare * gazePitch / Self.eyeRange + 0.08 * random.gaussian()))
            )
        }
        return FaceFrame(time: time, yaw: yaw, pitch: pitch, roll: 0.03 * random.gaussian(), center: center, size: size, pupilOffset: pupils)
    }

    /// Centre and four corners per display, 15 frames each, as the calibration screen asks for.
    mutating func calibrate(_ displays: [SimDisplay]) -> [GazeSample] {
        var samples: [GazeSample] = []
        var group = 0
        var time = 0.0
        for display in displays {
            for (u, v) in [(0.0, 0.0), (-0.85, -0.85), (0.85, -0.85), (-0.85, 0.85), (0.85, 0.85)] {
                // Nobody fixates the dot exactly.
                var target = display.point(u, v)
                target.x += 0.005 * random.gaussian()
                target.y += 0.005 * random.gaussian()
                for _ in 0..<15 {
                    let frame = face(lookingAt: target, time: time)
                    samples.append(GazeSample(display: display.id, group: group, features: GazeFeatures.vector(frame)))
                    time += 0.1
                }
                group += 1
            }
        }
        return samples
    }
}

private typealias Change = (time: Double, display: String)

/// The user keeps looking at `target`; frames arrive at `rate` Hz, each early or late by up
/// to half of `jitter` frame intervals.
private func watch(
    _ tracker: inout GazeTracker, _ user: inout SimUser, _ target: Vec3,
    from start: Double, for duration: Double, rate: Double = 10, jitter: Double = 0.3
) -> [Change] {
    var changes: [Change] = []
    var index = 0
    while Double(index) / rate < duration - 1e-9 {
        let time = start + (Double(index) + jitter * (user.random.uniform() - 0.5)) / rate
        if let display = tracker.ingest(user.face(lookingAt: target, time: time)) { changes.append((time, display)) }
        index += 1
    }
    return changes
}

private func names(_ changes: [Change]) -> [String] {
    changes.map { $0.display }
}

private func between(_ a: Vec3, _ b: Vec3, _ share: Double) -> Vec3 {
    Vec3(x: a.x + (b.x - a.x) * share, y: a.y + (b.y - a.y) * share, z: a.z + (b.z - a.z) * share)
}

/// Looks at a grid of points all over every display and counts what the classifier says.
private func survey(_ classifier: GazeClassifier, _ displays: [SimDisplay], _ user: inout SimUser) -> (right: Double, wrong: Double, rejected: Double) {
    var right = 0.0
    var wrong = 0.0
    var rejected = 0.0
    let steps = 15
    for display in displays {
        for i in 0..<steps {
            for j in 0..<steps {
                let u = -0.97 + 1.94 * Double(i) / Double(steps - 1)
                let v = -0.97 + 1.94 * Double(j) / Double(steps - 1)
                let frame = user.face(lookingAt: display.point(u, v), time: 0)
                switch classifier.classify(GazeFeatures.vector(frame))?.display {
                case display.id: right += 1
                case nil: rejected += 1
                default: wrong += 1
                }
            }
        }
    }
    let total = Double(displays.count * steps * steps)
    return (right / total, wrong / total, rejected / total)
}

private let layouts: [[SimDisplay]] = [
    [.laptop, .above],
    [.laptop, .side],
    [.left, .laptop, .side],
    [.laptop, .above, .side],
]

private func calibrated(_ displays: [SimDisplay], seed: UInt64 = 7) throws -> (classifier: GazeClassifier, user: SimUser) {
    var user = SimUser(seed: seed)
    let classifier = try #require(GazeClassifier(samples: user.calibrate(displays)))
    return (classifier, user)
}

// MARK: - Classifier

@Test func gazeHoldOutAccuracyWithTwoDisplays() throws {
    let stacked = try calibrated([.laptop, .above]).classifier.evaluate()
    let sideBySide = try calibrated([.laptop, .side]).classifier.evaluate()
    #expect(stacked >= 0.95)
    // A held-out corner of the laptop screen that faces the monitor is sometimes given to it.
    #expect(sideBySide >= 0.85)
}

@Test func gazeHoldOutAccuracyWithThreeDisplays() throws {
    let row = try calibrated([.left, .laptop, .side]).classifier.evaluate()
    #expect(row >= 0.9)
    // Here corners of two monitors almost touch, and a corner that is held out is nearer to
    // the other monitor than to what is left of its own. Three of the fifteen points go that way.
    let corner = try calibrated([.laptop, .above, .side]).classifier.evaluate()
    #expect(corner >= 0.7)
}

@Test func gazeLooksAllOverEachDisplayAreClassified() throws {
    for displays in layouts {
        var (classifier, user) = try calibrated(displays)
        let result = survey(classifier, displays, &user)
        #expect(result.right >= 0.98)
        #expect(result.wrong <= 0.01)
    }
}

@Test func gazeSurvivesAHeadShiftedAfterCalibrating() throws {
    for displays in layouts {
        for shift in [Vec3(x: 0.04, y: -0.02, z: 0.03), Vec3(x: -0.05, y: 0.03, z: 0.05)] {
            var (classifier, user) = try calibrated(displays)
            user.head.x += shift.x
            user.head.y += shift.y
            user.head.z += shift.z
            let result = survey(classifier, displays, &user)
            #expect(result.right >= 0.97)
            #expect(result.wrong <= 0.02)
        }
    }
}

@Test func gazeWorksWithoutPupilsInUse() throws {
    for displays in layouts {
        var (classifier, user) = try calibrated(displays)
        user.pupilDropout = 1
        let result = survey(classifier, displays, &user)
        #expect(result.right >= 0.98)
    }
}

@Test func gazeWorksWithPupilsMissingFromTheCalibration() throws {
    for dropout in [0.4, 1.0] {
        var user = SimUser(seed: 7)
        user.pupilDropout = dropout
        let displays: [SimDisplay] = [.laptop, .above, .side]
        let classifier = try #require(GazeClassifier(samples: user.calibrate(displays)))
        // With and without readable eyes in use.
        for liveDropout in [0.0, 1.0] {
            user.pupilDropout = liveDropout
            let result = survey(classifier, displays, &user)
            #expect(result.right >= 0.98)
        }
    }
}

@Test func gazeWorksWhenOneDisplayWasCalibratedWithoutPupils() throws {
    // Looking down at the laptop, the lids can hide the pupils for the whole recording.
    let displays: [SimDisplay] = [.laptop, .above]
    var user = SimUser(seed: 7)
    let samples = user.calibrate(displays).map { sample -> GazeSample in
        guard sample.display == "laptop" else { return sample }
        var features = sample.features
        features[GazeFeatures.pupilX] = 0
        features[GazeFeatures.pupilY] = 0
        features[GazeFeatures.hasPupils] = 0
        return GazeSample(display: sample.display, group: sample.group, features: features)
    }
    let classifier = try #require(GazeClassifier(samples: samples))
    let result = survey(classifier, displays, &user)
    #expect(result.right >= 0.98)
}

@Test func gazeSameFaceWithAndWithoutPupilsLandsOnTheSameDisplay() throws {
    let displays: [SimDisplay] = [.laptop, .above, .side]
    var (classifier, user) = try calibrated(displays)
    for display in displays {
        for (u, v) in [(0.0, 0.0), (-0.6, 0.6), (0.6, -0.6)] {
            var frame = user.face(lookingAt: display.point(u, v), time: 0)
            let seeing = classifier.classify(GazeFeatures.vector(frame))
            frame.pupilOffset = nil
            let blind = classifier.classify(GazeFeatures.vector(frame))
            #expect(seeing?.display == display.id)
            #expect(blind?.display == display.id)
        }
    }
}

@Test func gazeFeatureVectorHasAFixedLengthAndIgnoresRoll() {
    var face = FaceFrame(time: 0, yaw: 0.1, pitch: -0.2, roll: 0, center: Point2(x: 0.9, y: 0.5), size: 0.3, pupilOffset: Point2(x: 0.2, y: -0.1))
    let upright = GazeFeatures.vector(face)
    face.roll = 0.4
    #expect(GazeFeatures.vector(face) == upright)
    face.pupilOffset = nil
    let blind = GazeFeatures.vector(face)
    #expect(upright.count == GazeFeatures.count)
    #expect(blind.count == GazeFeatures.count)
    let finite = blind.allSatisfy { $0.isFinite }
    #expect(finite)
    #expect(blind[GazeFeatures.hasPupils] == 0)
    #expect(upright[GazeFeatures.hasPupils] == 1)
}

@Test func gazeLookingAwayIsRejected() throws {
    let elsewhere: [Vec3] = [
        Vec3(x: 0, y: -0.35, z: 0.45),     // a phone in the lap
        Vec3(x: 0, y: -0.21, z: 0.30),     // the desk in front of the laptop
        Vec3(x: 0.28, y: -0.21, z: 0.20),  // a phone lying beside the laptop
        Vec3(x: -1.5, y: 0.2, z: 0.3),     // someone standing on the left
        Vec3(x: 1.5, y: 0.2, z: 0.3),      // the door on the right
        Vec3(x: 0, y: 1.5, z: -0.2),       // the ceiling
    ]
    for displays in layouts {
        var (classifier, user) = try calibrated(displays)
        for target in elsewhere {
            var accepted = 0
            for _ in 0..<100 where classifier.classify(GazeFeatures.vector(user.face(lookingAt: target, time: 0))) != nil { accepted += 1 }
            #expect(accepted == 0)
        }
    }
}

@Test func gazeUnusableVectorsAreRejected() throws {
    let classifier = try calibrated([.laptop, .above]).classifier
    #expect(classifier.classify([]) == nil)
    #expect(classifier.classify([0, 0, 0.9]) == nil)
    #expect(classifier.classify([.nan, 0, 0.9, 0.5, 0.3, 0, 0, 1]) == nil)
}

@Test func gazeClassifierNeedsTwoDisplays() {
    var user = SimUser(seed: 7)
    let samples = user.calibrate([.laptop, .above])
    #expect(GazeClassifier(samples: []) == nil)
    #expect(GazeClassifier(samples: samples.filter { $0.display == "laptop" }) == nil)
    #expect(GazeClassifier(samples: samples) != nil)
    // A calibration recorded with another vector layout is as good as none.
    let outdated = samples.map { GazeSample(display: $0.display, group: $0.group, features: Array($0.features.prefix(5))) }
    #expect(GazeClassifier(samples: outdated) == nil)
}

// MARK: - Tracker

@Test(arguments: [5.0, 15.0])
func gazeTrackerSettlesAfterTheDwellAndNotBefore(rate: Double) throws {
    var (classifier, user) = try calibrated([.laptop, .above])
    var tracker = GazeTracker(classifier: classifier)
    let dwell = tracker.config.dwellTime

    // The first display has to be dwelt on like any other.
    let first = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2, rate: rate, jitter: 0)
    #expect(names(first) == ["laptop"])
    let firstDelay = try #require(first.first).time
    #expect(firstDelay >= dwell)
    #expect(firstDelay < dwell + 1 / rate)

    var changes: [Change] = []
    var index = 0
    while changes.isEmpty, index < 100 {
        let time = 2 + Double(index) / rate
        if let display = tracker.ingest(user.face(lookingAt: SimDisplay.above.center, time: time)) {
            changes.append((time, display))
        } else {
            #expect(tracker.settled == "laptop")
            #expect(tracker.candidate == "above")
            #expect(tracker.progress < 1)
        }
        index += 1
    }
    #expect(names(changes) == ["above"])
    let delay = try #require(changes.first).time - 2
    #expect(delay >= dwell)
    #expect(delay < dwell + 1 / rate)
    #expect(tracker.settled == "above")
    #expect(tracker.candidate == nil)
    #expect(tracker.progress == 0)
}

@Test func gazeTrackerSettlesWithIrregularFrames() throws {
    var (classifier, user) = try calibrated([.laptop, .above])
    var tracker = GazeTracker(classifier: classifier)
    _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2, jitter: 0.8)
    let changes = watch(&tracker, &user, SimDisplay.above.center, from: 2, for: 2, jitter: 0.8)
    #expect(names(changes) == ["above"])
    let delay = try #require(changes.first).time - 2
    #expect(delay >= 0.5 - 0.04)
    #expect(delay <= 0.5 + 0.2)
}

@Test func gazeGlanceDoesNotSwitch() throws {
    var (classifier, user) = try calibrated([.laptop, .above])
    var tracker = GazeTracker(classifier: classifier)
    _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2)
    let glance = watch(&tracker, &user, SimDisplay.above.center, from: 2, for: 0.3)
    #expect(glance.isEmpty)
    #expect(tracker.candidate == "above")
    #expect(tracker.progress > 0)
    let back = watch(&tracker, &user, SimDisplay.laptop.center, from: 2.3, for: 2)
    #expect(back.isEmpty)
    #expect(tracker.settled == "laptop")
    #expect(tracker.candidate == nil)
    #expect(tracker.progress == 0)
}

@Test func gazeRepeatedGlancesDoNotAddUp() throws {
    var (classifier, user) = try calibrated([.laptop, .above])
    var tracker = GazeTracker(classifier: classifier)
    _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2)
    var time = 2.0
    for _ in 0..<5 {
        #expect(watch(&tracker, &user, SimDisplay.above.center, from: time, for: 0.3).isEmpty)
        #expect(watch(&tracker, &user, SimDisplay.laptop.center, from: time + 0.3, for: 0.3).isEmpty)
        time += 0.6
    }
    #expect(tracker.settled == "laptop")
}

@Test func gazeNoiseOnTheBorderDoesNotFlicker() throws {
    for other in [SimDisplay.above, SimDisplay.side] {
        for seed in [1, 2, 3] as [UInt64] {
            // From well inside the laptop to well inside the other display, across the border.
            for share in stride(from: 0.30, through: 0.60, by: 0.02) {
                var (classifier, user) = try calibrated([.laptop, other], seed: seed)
                var tracker = GazeTracker(classifier: classifier)
                _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2)
                let target = between(SimDisplay.laptop.center, other.center, share)
                let changes = watch(&tracker, &user, target, from: 2, for: 60)
                // It may go over once, where the point is on the other side; never back.
                #expect(changes.count <= 1)
            }
        }
    }
}

@Test func gazeSettledDisplayIsStickyOnTheBorder() throws {
    // The point half way between the nearest calibration points of the two displays, where
    // the vote is split: whichever display is settled stays settled.
    let border = between(SimDisplay.laptop.point(0, 0.85), SimDisplay.above.point(0, -0.85), 0.5)
    for start in [SimDisplay.laptop, SimDisplay.above] {
        var (classifier, user) = try calibrated([.laptop, .above])
        var tracker = GazeTracker(classifier: classifier)
        _ = watch(&tracker, &user, start.center, from: 0, for: 2)
        #expect(tracker.settled == start.id)
        #expect(watch(&tracker, &user, border, from: 2, for: 60).isEmpty)
        #expect(tracker.settled == start.id)
    }
}

@Test func gazeLosingTheFaceKeepsTheSettledDisplay() throws {
    var (classifier, user) = try calibrated([.laptop, .above])
    var tracker = GazeTracker(classifier: classifier)
    _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2)
    #expect(watch(&tracker, &user, SimDisplay.above.center, from: 2, for: 0.3, jitter: 0).isEmpty)
    // No frames at all for two seconds.
    #expect(tracker.settled == "laptop")
    // What was seen before the gap does not count towards the dwell after it.
    let changes = watch(&tracker, &user, SimDisplay.above.center, from: 4.3, for: 2, jitter: 0)
    #expect(names(changes) == ["above"])
    let resumed = try #require(changes.first).time
    #expect(resumed >= 4.3 + 0.5)
}

@Test func gazeLookingAwayKeepsTheSettledDisplay() throws {
    let lap = Vec3(x: 0, y: -0.35, z: 0.45)
    var (classifier, user) = try calibrated([.laptop, .above])
    var tracker = GazeTracker(classifier: classifier)
    _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2)
    #expect(watch(&tracker, &user, lap, from: 2, for: 5).isEmpty)
    #expect(tracker.settled == "laptop")
    #expect(tracker.candidate == nil)
    #expect(tracker.estimate == nil)

    // Looking away in the middle of a dwell starts it over.
    #expect(watch(&tracker, &user, SimDisplay.above.center, from: 7, for: 0.3, jitter: 0).isEmpty)
    #expect(watch(&tracker, &user, lap, from: 7.3, for: 0.3, jitter: 0).isEmpty)
    #expect(tracker.candidate == nil)
    let changes = watch(&tracker, &user, SimDisplay.above.center, from: 7.6, for: 2, jitter: 0)
    #expect(names(changes) == ["above"])
    let resumed = try #require(changes.first).time
    #expect(resumed >= 7.6 + 0.5)
}

@Test func gazeOneStrayOrMissingFrameDoesNotRestartTheDwell() throws {
    for stray in ["contrary", "away", "missing"] {
        var (classifier, user) = try calibrated([.laptop, .above])
        var tracker = GazeTracker(classifier: classifier)
        _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2)
        var changes: [Change] = []
        for index in 0..<10 {
            let time = 2 + Double(index) / 10
            var target = SimDisplay.above.center
            if index == 3 {
                if stray == "missing" { continue }
                target = stray == "contrary" ? SimDisplay.laptop.center : Vec3(x: 0, y: -0.35, z: 0.45)
            }
            if let display = tracker.ingest(user.face(lookingAt: target, time: time)) { changes.append((time, display)) }
        }
        #expect(names(changes) == ["above"])
        let settledAt = try #require(changes.first).time
        #expect(abs(settledAt - 2.5) < 1e-9)
    }
}

@Test func gazeTwoStrayFramesRestartTheDwell() throws {
    var (classifier, user) = try calibrated([.laptop, .above])
    var tracker = GazeTracker(classifier: classifier)
    _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2)
    var changes: [Change] = []
    for index in 0..<15 {
        let time = 2 + Double(index) / 10
        let target = index == 3 || index == 4 ? SimDisplay.laptop.center : SimDisplay.above.center
        if let display = tracker.ingest(user.face(lookingAt: target, time: time)) { changes.append((time, display)) }
    }
    #expect(names(changes) == ["above"])
    // Counted again from the first frame after the interruption, at 2.5 s.
    let settledAt = try #require(changes.first).time
    #expect(abs(settledAt - 3.0) < 1e-9)
}

@Test func gazeEveryChangeIsReportedExactlyOnce() throws {
    let displays: [SimDisplay] = [.laptop, .above, .side]
    var (classifier, user) = try calibrated(displays)
    var tracker = GazeTracker(classifier: classifier)
    var reported: [String] = []
    var time = 0.0
    for display in [SimDisplay.laptop, .above, .side, .laptop, .side] {
        let changes = watch(&tracker, &user, display.center, from: time, for: 3)
        #expect(changes.count == 1)
        #expect(tracker.settled == display.id)
        reported += names(changes)
        time += 3
    }
    #expect(reported == ["laptop", "above", "side", "laptop", "side"])
}

@Test func gazeTrackerResetForgetsTheSettledDisplay() throws {
    var (classifier, user) = try calibrated([.laptop, .above])
    var tracker = GazeTracker(classifier: classifier)
    _ = watch(&tracker, &user, SimDisplay.laptop.center, from: 0, for: 2)
    _ = watch(&tracker, &user, SimDisplay.above.center, from: 2, for: 0.3)
    tracker.reset()
    #expect(tracker.settled == nil)
    #expect(tracker.candidate == nil)
    #expect(tracker.progress == 0)
    // The same display is announced again, as the first one.
    let changes = watch(&tracker, &user, SimDisplay.laptop.center, from: 2.3, for: 2)
    #expect(names(changes) == ["laptop"])
}

@Test func gazeDwellTimeIsConfigurable() throws {
    var (classifier, user) = try calibrated([.laptop, .above])
    var config = GazeConfig()
    config.dwellTime = 1.2
    var tracker = GazeTracker(classifier: classifier, config: config)
    let changes = watch(&tracker, &user, SimDisplay.above.center, from: 0, for: 3, jitter: 0)
    #expect(names(changes) == ["above"])
    let delay = try #require(changes.first).time
    #expect(delay >= 1.2)
    #expect(delay < 1.3 + 1e-9)
}

// MARK: - Stored data

@Test func gazeCalibrationMatchesOnlyItsOwnDisplaysAndCamera() {
    let calibration = GazeCalibration(displays: ["b", "a"], cameraID: "built-in", createdAt: Date(timeIntervalSince1970: 1_750_000_000), samples: [])
    #expect(calibration.displays == ["a", "b"])
    #expect(calibration.matches(displays: ["a", "b"], cameraID: "built-in"))
    #expect(calibration.matches(displays: ["b", "a"], cameraID: "built-in"))
    #expect(!calibration.matches(displays: ["a"], cameraID: "built-in"))
    #expect(!calibration.matches(displays: ["a", "b", "c"], cameraID: "built-in"))
    #expect(!calibration.matches(displays: ["a", "c"], cameraID: "built-in"))
    #expect(!calibration.matches(displays: ["a", "b"], cameraID: "external"))
    #expect(!calibration.matches(displays: ["a", "b"], cameraID: nil))

    let anyCamera = GazeCalibration(displays: ["a", "b"], cameraID: nil, createdAt: Date(timeIntervalSince1970: 1_750_000_000), samples: [])
    #expect(anyCamera.matches(displays: ["a", "b"], cameraID: nil))
    #expect(!anyCamera.matches(displays: ["a", "b"], cameraID: "built-in"))
}

@Test func gazeCalibrationSurvivesARoundTripThroughJSON() throws {
    var user = SimUser(seed: 7)
    user.pupilDropout = 0.2
    let displays: [SimDisplay] = [.laptop, .above]
    let calibration = GazeCalibration(
        displays: displays.map(\.id), cameraID: "built-in",
        createdAt: Date(timeIntervalSince1970: 1_750_000_000), samples: user.calibrate(displays)
    )
    let decoded = try JSONDecoder().decode(GazeCalibration.self, from: JSONEncoder().encode(calibration))
    #expect(decoded == calibration)

    // The classifier built from the file answers exactly like the one built in memory.
    let original = try #require(GazeClassifier(samples: calibration.samples))
    let restored = try #require(GazeClassifier(samples: decoded.samples))
    for display in displays {
        let features = GazeFeatures.vector(user.face(lookingAt: display.point(0.3, -0.4), time: 0))
        #expect(original.classify(features) == restored.classify(features))
        #expect(restored.classify(features)?.display == display.id)
    }
}

@Test func gazeConfigSurvivesARoundTripAndKeepsDefaultsForMissingKeys() throws {
    var config = GazeConfig()
    config.dwellTime = 0.8
    config.switchConfidence = 0.9
    let decoded = try JSONDecoder().decode(GazeConfig.self, from: JSONEncoder().encode(config))
    #expect(decoded == config)

    let older = try JSONDecoder().decode(GazeConfig.self, from: Data(#"{"dwellTime": 0.7}"#.utf8))
    #expect(older.dwellTime == 0.7)
    #expect(older.switchConfidence == GazeConfig().switchConfidence)
    #expect(GazeConfig().dwellTime == 0.5)
}
