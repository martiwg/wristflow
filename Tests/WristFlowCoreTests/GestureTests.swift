import Foundation
import Testing
@testable import WristFlowCore

// MARK: - Pose classifier

/// The same shape at several sizes and tilts, as either hand, with landmark noise.
private func variants(of shape: SyntheticHand) -> [(label: String, hand: Hand)] {
    var result: [(label: String, hand: Hand)] = []
    for scale in [0.07, 0.15, 0.3] {
        for rotation in [-45.0, -20, 0, 20, 45] {
            for isLeft in [false, true] {
                for seed in UInt64(1)...4 {
                    var copy = shape
                    copy.scale = scale
                    copy.rotation = rotation
                    copy.isLeft = isLeft
                    copy.jitter = 0.015
                    copy.seed = seed
                    let label = "scale \(scale), rotation \(rotation), \(isLeft ? "left" : "right"), seed \(seed)"
                    result.append((label, copy.hand()))
                }
            }
        }
    }
    return result
}

/// The variants of `shape` that do not classify as `pose`.
private func misread(_ shape: SyntheticHand, as pose: Pose?) -> [String] {
    variants(of: shape).compactMap { variant in
        let read = PoseClassifier.classify(variant.hand)
        return read == pose ? nil : "\(variant.label) read as \(String(describing: read))"
    }
}

@Suite struct PoseClassifierTests {
    @Test(arguments: Pose.allCases)
    func poseIsReadAtAnySizeTiltAndHand(pose: Pose) {
        let wrong = misread(.shape(for: pose), as: pose)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func relaxedOpenPalmIsStillAnOpenPalm() {
        let relaxed = SyntheticHand(curls: [.index: 0.15, .middle: 0.2, .ring: 0.2, .little: 0.15])
        let wrong = misread(relaxed, as: .openPalm)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func looseFistIsStillAFist() {
        let loose = SyntheticHand(curls: [.thumb: 0.8, .index: 0.8, .middle: 0.85, .ring: 0.85, .little: 0.8])
        let wrong = misread(loose, as: .fist)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func thumbIsFreeInAFist() {
        let wrong = misread(.thumbsUp, as: .fist)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func okSignToleratesSlightlyBentFingers() {
        let relaxed = SyntheticHand(curls: [.middle: 0.15, .ring: 0.15, .little: 0.1], pinch: 1)
        let wrong = misread(relaxed, as: .ok)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test(arguments: [
        ("three fingers up", SyntheticHand.threeFingers),
        ("pointing", SyntheticHand.pointing),
        ("peace sign", SyntheticHand.peace),
        ("four fingers, thumb tucked", SyntheticHand.fourFingers),
        ("half-closed hand", SyntheticHand.halfClosed),
        ("pinch with ring and little curled", SyntheticHand(curls: [.ring: 1, .little: 1], pinch: 1)),
        ("fist with the index half out", SyntheticHand(curls: [.thumb: 1, .index: 0.45, .middle: 1, .ring: 1, .little: 1])),
    ])
    func nearMissIsNoPose(name: String, shape: SyntheticHand) {
        let wrong = misread(shape, as: nil)
        #expect(wrong.isEmpty, "\(name): \(wrong)")
    }

    @Test func thumbAndIndexApartIsNotOK() {
        let open = variants(of: SyntheticHand(pinch: 0.5)).filter { PoseClassifier.classify($0.hand) == .ok }
        #expect(open.isEmpty)
    }

    @Test func fingerStatesFollowEachFinger() {
        let states = PoseClassifier.fingerStates(SyntheticHand.pointing.hand())
        #expect(states[.index] == .extended)
        #expect(states[.middle] == .curled)
        #expect(states[.ring] == .curled)
        #expect(states[.little] == .curled)
        #expect(states[.thumb] == .curled)

        let half = PoseClassifier.fingerStates(SyntheticHand.halfClosed.hand())
        for finger in [Finger.index, .middle, .ring, .little] {
            #expect(half[finger] == .unclear)
        }
    }

    @Test func doubtfulJointsMakeTheFingerUnclear() {
        var shape = SyntheticHand.openPalm
        shape.doubtfulFingers = [.ring]
        let hand = shape.hand()
        let states = PoseClassifier.fingerStates(hand)
        #expect(states[.ring] == .unclear)
        #expect(states[.middle] == .extended)
        // The palm centre the thumb is measured from includes the ring knuckle.
        #expect(states[.thumb] == .unclear)
        #expect(PoseClassifier.classify(hand) == nil)
    }

    @Test func doubtfulIndexIsNotGuessedIntoAFist() {
        var shape = SyntheticHand.fist
        shape.doubtfulFingers = [.index]
        #expect(PoseClassifier.classify(shape.hand()) == nil)
    }
}

// MARK: - Gesture engine

/// Where the hand rests in most scenes, and its palm size.
private let home = Point2(x: 0.8, y: 0.5)
private let palm = 0.15

/// A point `dx`, `dy` palm sizes away from `home`.
private func away(_ dx: Double, _ dy: Double) -> Point2 {
    Point2(x: home.x + dx * palm, y: home.y + dy * palm)
}

/// Plays hands to an engine at a fixed frame rate and notes what it fires and when.
private struct Session {
    var engine: GestureEngine
    let fps: Double
    /// Landmark noise on every frame, in palm sizes.
    var jitter = 0.01
    private(set) var fired: [(time: Double, trigger: Trigger)] = []
    private var frame = 0

    init(fps: Double = 30, config: GestureConfig = GestureConfig()) {
        self.fps = fps
        engine = GestureEngine(config: config)
    }

    /// Time of the next frame.
    var now: Double { Double(frame) / fps }
    var triggers: [Trigger] { fired.map(\.trigger) }

    /// Feeds frames for `duration` seconds; `scene` says which hands are visible at a given
    /// number of seconds into it.
    mutating func run(_ duration: Double, _ scene: (Double) -> [SyntheticHand]) {
        let count = Int((duration * fps).rounded())
        for step in 0..<count {
            let time = now
            let shapes = scene(Double(step) / fps)
            var hands: [Hand] = []
            for (index, shape) in shapes.enumerated() {
                var copy = shape
                copy.jitter = max(copy.jitter, jitter)
                copy.seed = UInt64(frame * 7 + index + 1)
                hands.append(copy.hand())
            }
            if let trigger = engine.ingest(HandFrame(time: time, hands: hands)) {
                fired.append((time, trigger))
            }
            frame += 1
        }
    }

    mutating func hold(_ shape: SyntheticHand, at center: Point2 = home, for duration: Double) {
        run(duration) { _ in [shape.at(center)] }
    }

    /// Moves the hand in a straight line. Eased moves start and stop gently, like a swipe;
    /// the others keep one speed, like a hand on its way somewhere else.
    mutating func move(_ shape: SyntheticHand, from start: Point2, to end: Point2, over duration: Double, eased: Bool = true) {
        run(duration) { elapsed in
            let u = elapsed / duration
            let progress = eased ? u * u * (3 - 2 * u) : u
            return [shape.at(start + (end - start) * progress)]
        }
    }

    mutating func nothing(for duration: Double) {
        run(duration) { _ in [] }
    }

    /// Open palm at rest at `home`, long enough to settle and too short to fire the hold.
    mutating func restPalm() {
        hold(.openPalm, for: 0.3)
    }

    /// A quick sweep of the whole hand from `start` to `end`.
    mutating func sweep(from start: Point2 = home, to end: Point2, shape: SyntheticHand = .openPalm) {
        move(shape, from: start, to: end, over: 0.25)
    }

    /// Holds the hand leaning `degrees` towards the user's right, its wrist at `home`.
    mutating func lean(_ degrees: Double, for duration: Double, shape: SyntheticHand = .openPalm) {
        run(duration) { _ in [leaning(degrees, shape: shape)] }
    }

    /// Turns the hand about its wrist, the way a wrist flick looks to the camera.
    mutating func flick(from start: Double, to end: Double, over duration: Double = 0.1, shape: SyntheticHand = .openPalm) {
        run(duration) { elapsed in [leaning(start + (end - start) * elapsed / duration, shape: shape)] }
    }
}

/// `shape` turned about its wrist, which stays at `home`: 0 is upright, positive leans towards
/// the user's right.
private func leaning(_ degrees: Double, shape: SyntheticHand = .openPalm) -> SyntheticHand {
    var turned = shape
    turned.scale = palm
    // The skeleton turns counter-clockwise, which in the mirror view is towards the left.
    turned.rotation = -degrees
    turned.center = .zero
    let wrist = turned.hand()[.wrist]
    turned.center = home - wrist
    return turned
}

/// A landmark recording of real gestures and the triggers it has to produce.
private struct Fixture {
    struct Expected: Decodable {
        var triggers: [Trigger]
        /// How many of them the engine is allowed to miss.
        var mayMiss: Int
    }

    let frames: [RecordedFrame]
    let expected: Expected

    init(named name: String) throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        frames = try Recording.load(folder.appendingPathComponent("\(name).jsonl"))
        let data = try Data(contentsOf: folder.appendingPathComponent("\(name).expected.json"))
        expected = try JSONDecoder().decode(Expected.self, from: data)
    }
}

private let frameRates = [10.0, 30.0]

@Suite struct GestureEngineTests {
    // MARK: Holds

    @Test(arguments: frameRates)
    func holdFiresOnceAtAboutHoldTimeAndNotBefore(fps: Double) {
        for pose in Pose.allCases {
            var session = Session(fps: fps)
            session.hold(.shape(for: pose), for: 2)
            #expect(session.triggers == [Trigger(pose: pose)])
            let time = session.fired.first?.time ?? -1
            #expect(time >= 0.4 - 1e-6)
            #expect(time <= 0.4 + 1 / fps + 1e-6)
        }
    }

    @Test func holdTimeIsConfigurable() {
        var config = GestureConfig()
        config.holdTime = 0.8
        var session = Session(config: config)
        session.hold(.fist, for: 0.7)
        #expect(session.triggers.isEmpty)
        session.hold(.fist, for: 0.3)
        #expect(session.triggers == [.fist])
    }

    @Test(arguments: frameRates)
    func holdFiresAgainAfterThePoseIsReleased(fps: Double) {
        var session = Session(fps: fps)
        session.hold(.fist, for: 0.6)
        session.hold(.halfClosed, for: 0.3)
        let shownAgain = session.now
        session.hold(.fist, for: 0.8)
        #expect(session.triggers == [.fist, .fist])
        let time = session.fired.last?.time ?? -1
        #expect(time >= shownAgain + 0.4 - 1e-6)
        #expect(time <= shownAgain + 0.4 + 1 / fps + 1e-6)
    }

    @Test func holdFiresAgainAfterTheHandLeaves() {
        var session = Session()
        session.hold(.ok, for: 0.6)
        session.nothing(for: 0.3)
        session.hold(.ok, for: 0.6)
        #expect(session.triggers == [.ok, .ok])
    }

    @Test func changingPoseFiresTheNewOneFromItsFirstFrame() {
        var session = Session()
        session.hold(.openPalm, for: 0.6)
        let changed = session.now
        session.hold(.fist, for: 0.8)
        #expect(session.triggers == [.palm, .fist])
        let time = session.fired.last?.time ?? -1
        #expect(time >= changed + 0.4 - 1e-6)
        #expect(time <= changed + 0.4 + 1 / 30 + 1e-6)
    }

    enum Glitch: CaseIterable {
        case noPose, otherPose, handLost
    }

    @Test(arguments: Glitch.allCases, [(fps: 30.0, frames: 2.0), (fps: 10.0, frames: 1.0)])
    func holdSurvivesAShortGlitch(glitch: Glitch, rate: (fps: Double, frames: Double)) {
        var session = Session(fps: rate.fps)
        session.hold(.openPalm, for: 0.2)
        let length = rate.frames / rate.fps
        switch glitch {
        case .noPose: session.hold(.halfClosed, for: length)
        case .otherPose: session.hold(.fist, for: length)
        case .handLost: session.nothing(for: length)
        }
        session.hold(.openPalm, for: 1)
        #expect(session.triggers == [.palm])
        // Had the glitch restarted the hold, it would fire 0.2 s and more later than this.
        let time = session.fired.first?.time ?? -1
        #expect(time <= 0.4 + 1 / rate.fps + 1e-6)
    }

    @Test func aLongInterruptionRestartsTheHold() {
        var session = Session()
        session.hold(.fist, for: 0.3)
        session.hold(.halfClosed, for: 0.3)
        let shownAgain = session.now
        session.hold(.fist, for: 0.3)
        #expect(session.triggers.isEmpty)
        session.hold(.fist, for: 0.3)
        #expect(session.triggers == [.fist])
        let time = session.fired.first?.time ?? -1
        #expect(time >= shownAgain + 0.4 - 1e-6)
    }

    @Test func aPoseThatFlickersHalfTheTimeIsNotHeld() {
        var session = Session()
        session.run(3) { elapsed in
            // Two frames of fist, two of nothing recognisable, over and over.
            let showsFist = Int((elapsed * 30).rounded()) % 4 < 2
            return [(showsFist ? SyntheticHand.fist : .halfClosed).at(home)]
        }
        #expect(session.triggers.isEmpty)
    }

    @Test func aPoseCarriedAroundDoesNotFire() {
        var session = Session()
        // 1.5 palm sizes per second: unhurried, and still not "held still".
        session.move(.fist, from: away(-1.5, 0), to: away(1.5, 0), over: 2, eased: false)
        #expect(session.triggers.isEmpty)
        session.hold(.fist, at: away(1.5, 0), for: 0.6)
        #expect(session.triggers == [.fist])
    }

    // MARK: Swipes

    @Test(arguments: [
        (Trigger.swipeRight, -30.0, 45.0),
        (Trigger.swipeLeft, 30.0, -45.0),
        (Trigger.swipeUp, 100.0, 20.0),
    ], frameRates)
    func flickIsASwipe(expected: (trigger: Trigger, from: Double, to: Double), fps: Double) {
        var session = Session(fps: fps)
        session.lean(expected.from, for: 0.3)
        session.flick(from: expected.from, to: expected.to)
        session.lean(expected.to, for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers == [expected.trigger])
    }

    @Test func flickIsReadWhileTheHandIsBlurred() {
        var session = Session()
        session.lean(-30, for: 0.3)
        // The fastest frame of a flick smears: the detector is unsure of the whole hand there.
        var smeared = SyntheticHand.halfClosed
        smeared.confidence = 0.4
        session.run(0.1) { elapsed in
            let shape = elapsed > 0.03 && elapsed < 0.06 ? smeared : SyntheticHand.openPalm
            return [leaning(-30 + 75 * elapsed / 0.1, shape: shape)]
        }
        session.lean(45, for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers == [.swipeRight])
    }

    @Test func timeUnseenDoesNotCountTowardsAHold() {
        var session = Session()
        session.restPalm()
        session.nothing(for: 0.3)
        let back = session.now
        session.hold(.openPalm, for: 0.3)
        #expect(session.triggers.isEmpty)
        session.hold(.openPalm, for: 0.3)
        #expect(session.triggers == [.palm])
        let time = session.fired.first?.time ?? -1
        #expect(time >= back + 0.4 - 1 / 30 - 1e-6)
    }

    @Test(arguments: [0.1, 0.25], frameRates)
    func theWayBackIsNotASwipe(returnTime: Double, fps: Double) {
        var session = Session(fps: fps)
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45)
        session.lean(45, for: 0.1)
        session.flick(from: 45, to: -30, over: returnTime)
        session.lean(-30, for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers == [.swipeRight])
    }

    @Test(arguments: frameRates)
    func flicksInARowEachCount(fps: Double) {
        var session = Session(fps: fps)
        session.lean(30, for: 0.3)
        for _ in 0..<4 {
            session.flick(from: 30, to: -45)
            session.flick(from: -45, to: 30, over: 0.2)
            session.lean(30, for: 0.2)
        }
        session.nothing(for: 0.6)
        #expect(session.triggers == [.swipeLeft, .swipeLeft, .swipeLeft, .swipeLeft])
    }

    @Test func aSwipeTheOtherWayCountsOnceTheHandHasComeBack() {
        var session = Session()
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45)
        session.lean(45, for: 0.6)
        session.flick(from: 45, to: -30)
        session.lean(-30, for: 0.2)
        #expect(session.triggers == [.swipeRight, .swipeLeft])
    }

    @Test func slowTurnOfTheHandIsNotASwipe() {
        var session = Session()
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45, over: 0.4)
        session.lean(45, for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers.isEmpty)
    }

    @Test func smallFlickIsNotASwipe() {
        var session = Session()
        session.lean(-10, for: 0.3)
        session.flick(from: -10, to: 15)
        session.lean(15, for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers.isEmpty)
    }

    @Test(arguments: frameRates)
    func flickDownwardsFiresNothing(fps: Double) {
        var session = Session(fps: fps)
        session.lean(20, for: 0.3)
        session.flick(from: 20, to: 100)
        session.lean(100, for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers.isEmpty)
    }

    @Test func handThatHasJustAppearedDoesNotSwipe() {
        var session = Session()
        session.lean(-30, for: 0.1)
        session.flick(from: -30, to: 45)
        session.lean(45, for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers.isEmpty)
    }

    @Test(arguments: frameRates)
    func handEnteringAlreadyMovingIsNotASwipe(fps: Double) {
        var session = Session(fps: fps)
        session.move(.openPalm, from: Point2(x: 0.1, y: 0.5), to: Point2(x: 1.5, y: 0.5), over: 0.8, eased: false)
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    @Test func raisingTheHandIntoViewIsNotASwipeUp() {
        var session = Session()
        session.move(.openPalm, from: Point2(x: 0.8, y: 0.05), to: home, over: 0.3)
        session.hold(.openPalm, for: 0.3)
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    @Test(arguments: [(2.5, 0.0), (-2.5, 0.0), (0.0, 2.5)])
    func carryingTheWholeHandAcrossIsNotASwipe(dx: Double, dy: Double) {
        var session = Session()
        session.restPalm()
        // As fast as a flick, but wrist and fingers travel together: a hand going somewhere.
        session.move(.openPalm, from: home, to: away(dx, dy), over: 0.1, eased: false)
        session.hold(.openPalm, at: away(dx, dy), for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers.isEmpty)
    }

    @Test func fistDoesNotSwipe() {
        var session = Session()
        session.lean(-30, for: 0.3, shape: .fist)
        session.flick(from: -30, to: 45, shape: .fist)
        session.lean(45, for: 0.2, shape: .fist)
        session.nothing(for: 0.6)
        #expect(session.triggers.isEmpty)
    }

    @Test func palmDoesNotFireAfterASwipe() {
        var session = Session()
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45)
        session.lean(45, for: 2)
        #expect(session.triggers == [.swipeRight])
        #expect(session.engine.state.holdProgress == 0)
    }

    @Test func palmFiresAgainOnceTheHandHasLeftAfterASwipe() {
        var session = Session()
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45)
        session.lean(45, for: 0.1)
        session.nothing(for: 0.6)
        session.hold(.openPalm, for: 0.6)
        #expect(session.triggers == [.swipeRight, .palm])
    }

    @Test func anotherPoseAfterASwipeFreesThePalm() {
        var session = Session()
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45)
        session.lean(45, for: 0.1)
        session.hold(.fist, for: 0.6)
        session.hold(.openPalm, for: 0.6)
        #expect(session.triggers == [.swipeRight, .fist, .palm])
    }

    @Test func noSwipeOnceThePalmHoldHasFired() {
        var session = Session()
        session.lean(-30, for: 0.6)
        session.flick(from: -30, to: 45)
        session.flick(from: 45, to: -30, over: 0.2)
        session.lean(-30, for: 0.6)
        #expect(session.triggers == [.palm])

        session.nothing(for: 0.6)
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45)
        session.lean(45, for: 0.1)
        #expect(session.triggers == [.palm, .swipeRight])
    }

    // MARK: Recorded gestures

    @Test(arguments: ["wrist-flick-swipes", "palm-and-back", "hand-at-face"])
    func recordedGesturesAreRead(name: String) throws {
        let fixture = try Fixture(named: name)
        var engine = GestureEngine()
        var fired: [Trigger] = []
        for frame in fixture.frames {
            switch frame {
            case .face(let face): engine.ingest(face)
            case .hands(let hands): if let trigger = engine.ingest(hands) { fired.append(trigger) }
            }
        }
        // Everything fired has to be one of the gestures that were made, in the order they
        // were made; a few may be missed where the fixture says so, none may be invented.
        var remaining = fixture.expected.triggers[...]
        var invented: [Trigger] = []
        for trigger in fired {
            if let index = remaining.firstIndex(of: trigger) {
                remaining = remaining[(index + 1)...]
            } else {
                invented.append(trigger)
            }
        }
        #expect(invented.isEmpty)
        #expect(fired.count >= fixture.expected.triggers.count - fixture.expected.mayMiss)
    }

    // MARK: Palm and back

    @Test(arguments: [false, true])
    func backOfTheHandIsItsOwnGesture(isLeft: Bool) {
        var palm = SyntheticHand.openPalm
        palm.isLeft = isLeft
        var back = SyntheticHand.backOfHand
        back.isLeft = isLeft
        #expect(PoseClassifier.classify(palm.hand()) == .openPalm)
        #expect(PoseClassifier.classify(back.hand()) == .backOfHand)

        var session = Session()
        session.hold(palm, for: 0.6)
        session.hold(back, for: 0.6)
        session.hold(palm, for: 0.6)
        #expect(session.triggers == [.palm, .palmBack, .palm])
    }

    @Test func openHandOfUnknownSideIsAPalm() {
        var hand = SyntheticHand.backOfHand.hand()
        hand.handedness = nil
        #expect(PoseClassifier.classify(hand) == .openPalm)
    }

    @Test func backOfTheHandDoesNotFireAfterASwipe() {
        var session = Session()
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45)
        // A flick often leaves the hand turned over.
        session.lean(45, for: 2, shape: .backOfHand)
        #expect(session.triggers == [.swipeRight])
    }

    // MARK: Hand at the face

    /// A face about as large next to `home`'s hand as a real one is next to a hand touching it.
    private static func face(at center: Point2, time: Double) -> FaceFrame {
        FaceFrame(time: time, yaw: 0, pitch: 0, roll: 0, center: center, size: palm / 0.8, pupilOffset: nil)
    }

    @Test(arguments: [SyntheticHand.fist, .openPalm, .ok])
    func handAtTheFaceIsNotAPose(shape: SyntheticHand) {
        var session = Session()
        session.engine.ingest(Self.face(at: away(0, 0.8), time: 0))
        session.hold(shape, for: 2)
        #expect(session.triggers.isEmpty)
        #expect(session.engine.state.atFace)
        #expect(session.engine.state.pose == nil)
    }

    @Test func handBesideTheFaceIsRead() {
        var session = Session()
        session.engine.ingest(Self.face(at: away(-4, 0.5), time: 0))
        session.hold(.fist, for: 1)
        #expect(session.triggers == [.fist])
        #expect(!session.engine.state.atFace)
    }

    @Test func handHeldInFrontOfTheFaceIsRead() {
        var session = Session()
        // Nearer the camera than the face, so it looks large next to it.
        var face = Self.face(at: away(0, 0.8), time: 0)
        face.size = palm / 1.3
        session.engine.ingest(face)
        session.hold(.fist, for: 1)
        #expect(session.triggers == [.fist])
    }

    @Test func aFaceNotSeenForAWhileIsForgotten() {
        var session = Session()
        session.engine.ingest(Self.face(at: away(0, 0.8), time: 0))
        session.nothing(for: 4)
        session.hold(.fist, for: 1)
        #expect(session.triggers == [.fist])
    }

    @Test func swipeInFrontOfTheFaceStillCounts() {
        var session = Session()
        session.engine.ingest(Self.face(at: away(0, 0.8), time: 0))
        session.lean(-30, for: 0.3)
        session.flick(from: -30, to: 45)
        session.lean(45, for: 0.2)
        #expect(session.triggers == [.swipeRight])
    }

    // MARK: Things that must fire nothing

    @Test func farSmallHandIsIgnored() {
        var session = Session()
        let far = SyntheticHand.openPalm.scaled(0.04)
        session.hold(far, for: 1)
        #expect(!session.engine.state.handVisible)
        session.move(far, from: home, to: Point2(x: home.x + 2.5 * 0.04, y: home.y), over: 0.25)
        session.hold(SyntheticHand.fist.scaled(0.04), for: 1)
        #expect(session.triggers.isEmpty)
    }

    @Test func lowConfidenceHandIsIgnored() {
        var session = Session()
        var faint = SyntheticHand.openPalm
        faint.confidence = 0.3
        session.hold(faint, for: 1)
        #expect(!session.engine.state.handVisible)
        session.sweep(to: away(2.5, 0), shape: faint)
        var faintFist = SyntheticHand.fist
        faintFist.confidence = 0.3
        session.hold(faintFist, at: away(2.5, 0), for: 1)
        #expect(session.triggers.isEmpty)
    }

    @Test(arguments: frameRates)
    func handPassingThroughWithChangingPosesFiresNothing(fps: Double) {
        var session = Session(fps: fps)
        let shapes: [SyntheticHand] = [.openPalm, .fist, .ok, .pointing, .openPalm, .halfClosed, .fist]
        let start = Point2(x: 0.1, y: 0.3)
        let end = Point2(x: 1.5, y: 0.6)
        session.run(1.5) { elapsed in
            let shape = shapes[Int(elapsed / 0.2) % shapes.count]
            return [shape.at(start + (end - start) * (elapsed / 1.5))]
        }
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    @Test(arguments: [0.12, 0.2, 0.3], frameRates)
    func scratchingTheHeadFiresNothing(amplitude: Double, fps: Double) {
        var session = Session(fps: fps)
        session.jitter = 0.03
        let spot = Point2(x: 0.9, y: 0.9)
        session.run(3) { elapsed in
            // Fingers working between a loose and a tight fist while the hand rubs back and forth.
            let curl = 0.78 + 0.2 * sin(2 * .pi * 3.3 * elapsed)
            var shape = SyntheticHand(curls: [.thumb: 0.6, .index: curl, .middle: curl, .ring: curl, .little: curl])
            shape.center = Point2(
                x: spot.x + amplitude * palm * sin(2 * .pi * 4 * elapsed),
                y: spot.y + amplitude * 0.7 * palm * cos(2 * .pi * 4 * elapsed)
            )
            return [shape]
        }
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    @Test(arguments: [0.6, 1.0, 2.5], frameRates)
    func reachingAcrossTheFrameFiresNothing(duration: Double, fps: Double) {
        var session = Session(fps: fps)
        // An open hand on its way to a cup: one steady movement, in and out of view.
        session.move(.openPalm, from: Point2(x: 0.2, y: 0.15), to: Point2(x: 1.4, y: 0.55), over: duration, eased: false)
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    // MARK: Several hands

    @Test func keepsFollowingTheHandItAlreadyTracks() {
        var session = Session()
        let bigPalm = SyntheticHand.openPalm.scaled(0.25).at(Point2(x: 1.4, y: 0.5))
        session.hold(.fist, for: 0.2)
        session.run(1) { _ in [bigPalm, SyntheticHand.fist.at(home)] }
        #expect(session.triggers == [.fist])
    }

    @Test func takesTheLargestHandWhenNoneIsTracked() {
        var session = Session()
        let smallFist = SyntheticHand.fist.scaled(0.1).at(Point2(x: 0.4, y: 0.5))
        let bigPalm = SyntheticHand.openPalm.scaled(0.2).at(Point2(x: 1.2, y: 0.5))
        session.run(1) { _ in [smallFist, bigPalm] }
        #expect(session.triggers == [.palm])
    }

    @Test(arguments: frameRates)
    func losingTheTrackedHandToAnotherOneIsNotASwipe(fps: Double) {
        var session = Session(fps: fps)
        let tracked = SyntheticHand.openPalm.scaled(0.2).at(Point2(x: 0.6, y: 0.5))
        let other = SyntheticHand.openPalm.at(Point2(x: 1.2, y: 0.5))
        session.run(0.4) { _ in [tracked, other] }
        #expect(session.engine.state.armedForSwipe)
        session.run(0.3) { _ in [other] }
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    // MARK: State and configuration

    @Test func stateFollowsTheHand() {
        var session = Session()
        #expect(session.engine.state == GestureState())

        session.hold(.openPalm, for: 0.3)
        var state = session.engine.state
        #expect(state.handVisible)
        #expect(state.pose == .openPalm)
        #expect(state.holdProgress > 0.3)
        #expect(state.holdProgress < 1)
        #expect(state.armedForSwipe)

        session.hold(.openPalm, for: 0.4)
        state = session.engine.state
        #expect(state.holdProgress == 1)
        #expect(!state.armedForSwipe)

        session.hold(.fist, for: 0.3)
        state = session.engine.state
        #expect(state.pose == .fist)
        #expect(state.holdProgress < 1)
        #expect(!state.armedForSwipe)

        session.nothing(for: 0.1)
        #expect(session.engine.state.handVisible)
        session.nothing(for: 0.3)
        #expect(session.engine.state == GestureState())
    }

    @Test func resetForgetsTheHand() {
        var session = Session()
        session.hold(.fist, for: 0.3)
        session.engine.reset()
        #expect(session.engine.state == GestureState())
        session.hold(.fist, for: 0.3)
        #expect(session.triggers.isEmpty)
        session.hold(.fist, for: 0.2)
        #expect(session.triggers == [.fist])
    }

    @Test func configFromAnOlderFileKeepsDefaults() throws {
        let config = try JSONDecoder().decode(GestureConfig.self, from: Data(#"{"holdTime": 0.6}"#.utf8))
        var expected = GestureConfig()
        expected.holdTime = 0.6
        #expect(config == expected)

        let roundTrip = try JSONDecoder().decode(GestureConfig.self, from: JSONEncoder().encode(expected))
        #expect(roundTrip == expected)
    }
}
