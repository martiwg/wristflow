import Foundation
import Testing
@testable import WristFlowCore

// MARK: - Pose classifier

/// The same shape at several sizes and tilts, as either hand, with landmark noise.
private func variants(
    of shape: SyntheticHand, rotations: [Double] = [-45, -20, 0, 20, 45], hands: [Bool] = [false, true]
) -> [(label: String, hand: Hand)] {
    var result: [(label: String, hand: Hand)] = []
    for scale in [0.07, 0.15, 0.3] {
        for rotation in rotations {
            for isLeft in hands {
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
    // A thumbs up is the one pose that depends on which way it points; it has its own test.
    @Test(arguments: Pose.builtIn.filter { $0 != .thumbsUp })
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
        for thumb in [0.5, 1.0] {
            let wrong = misread(SyntheticHand(curls: [.thumb: thumb, .index: 1, .middle: 1, .ring: 1, .little: 1]), as: .fist)
            #expect(wrong.isEmpty, "\(wrong)")
        }
        // With the thumb out it is still a fist unless the thumb points up.
        let other = variants(of: .thumbsUp).filter { ![.fist, .thumbsUp].contains(PoseClassifier.classify($0.hand)) }
        #expect(other.isEmpty)
    }

    @Test func okSignToleratesSlightlyBentFingers() {
        let relaxed = SyntheticHand(curls: [.middle: 0.15, .ring: 0.15, .little: 0.1], pinch: 1)
        let wrong = misread(relaxed, as: .ok)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func thumbsUpNeedsTheThumbPointingUp() {
        // The skeleton's thumb leans 40 degrees off its hand, to the left on a right hand.
        // These tilts bring it within 30 degrees of straight up.
        let upright = variants(of: .thumbsUp, rotations: [-70, -40, -10], hands: [false])
            + variants(of: .thumbsUp, rotations: [10, 40, 70], hands: [true])
        let missed = upright.filter { PoseClassifier.classify($0.hand) != .thumbsUp }.map(\.label)
        #expect(missed.isEmpty, "\(missed)")

        // Pointing sideways or down, the same hand is a fist.
        let sideways = variants(of: .thumbsUp, rotations: [60, 140], hands: [false])
            + variants(of: .thumbsUp, rotations: [-60, -140], hands: [true])
        let wrong = sideways.filter { PoseClassifier.classify($0.hand) != .fist }.map(\.label)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test func fiveFingersIsThePalmAndFourIsNot() {
        #expect(PoseClassifier.classify(SyntheticHand.openPalm.hand()) == .openPalm)
        #expect(PoseClassifier.classify(SyntheticHand.fourFingers.hand()) == .four)
        // Thumb half way: neither clearly out nor clearly folded in.
        let between = variants(of: SyntheticHand(curls: [.thumb: 0.35]))
            .filter { [.openPalm, .backOfHand, .four].contains(PoseClassifier.classify($0.hand)) == false }
        #expect(!between.isEmpty)
    }

    @Test(arguments: [
        ("index and little finger up", SyntheticHand(curls: [.thumb: 1, .middle: 1, .ring: 1])),
        ("middle finger alone", SyntheticHand(curls: [.thumb: 1, .index: 1, .ring: 1, .little: 1])),
        ("half-closed hand", SyntheticHand.halfClosed),
        ("pinch with ring and little curled", SyntheticHand(curls: [.ring: 1, .little: 1], pinch: 1)),
        ("fist with the index half out", SyntheticHand(curls: [.thumb: 1, .index: 0.4, .middle: 1, .ring: 1, .little: 1])),
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
        for pose in Pose.builtIn {
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
        (Trigger.swipeRight, -40.0, 50.0),
        (Trigger.swipeLeft, 40.0, -50.0),
        (Trigger.swipeUp, 110.0, 15.0),
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
        session.lean(-40, for: 0.3)
        // The fastest frame of a flick smears: the detector is unsure of the whole hand there.
        var smeared = SyntheticHand.halfClosed
        smeared.confidence = 0.4
        session.run(0.1) { elapsed in
            let shape = elapsed > 0.03 && elapsed < 0.06 ? smeared : SyntheticHand.openPalm
            return [leaning(-40 + 90 * elapsed / 0.1, shape: shape)]
        }
        session.lean(50, for: 0.2)
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
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 0.1)
        session.flick(from: 50, to: -40, over: returnTime)
        session.lean(-40, for: 0.2)
        session.nothing(for: 0.6)
        #expect(session.triggers == [.swipeRight])
    }

    @Test(arguments: frameRates)
    func flicksInARowEachCount(fps: Double) {
        var session = Session(fps: fps)
        session.lean(40, for: 0.3)
        for _ in 0..<4 {
            session.flick(from: 40, to: -50)
            session.flick(from: -50, to: 40, over: 0.2)
            session.lean(40, for: 0.2)
        }
        session.nothing(for: 0.6)
        #expect(session.triggers == [.swipeLeft, .swipeLeft, .swipeLeft, .swipeLeft])
    }

    @Test(arguments: [0.6, 1.5, 2.5])
    func theWayBackIsNotASwipeHoweverLateItComes(pause: Double) {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        // Watching what the swipe did before taking the hand back, just as briskly.
        session.lean(50, for: pause)
        session.flick(from: 50, to: -40)
        session.lean(-40, for: 0.3)
        #expect(session.triggers == [.swipeRight])
    }

    @Test func aSwipeTheOtherWayCountsOnceTheHandHasComeBack() {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 0.3)
        session.flick(from: 50, to: -40)
        session.lean(-40, for: 0.4)
        // Back where it started; winding up and flicking the other way is a new swipe.
        session.flick(from: -40, to: 50, over: 0.5)
        session.lean(50, for: 0.1)
        session.flick(from: 50, to: -40)
        session.lean(-40, for: 0.2)
        #expect(session.triggers == [.swipeRight, .swipeLeft])
    }

    @Test func aSwipeTheOtherWayCountsAfterTheHandWentBackSlowly() {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.flick(from: 50, to: -40, over: 0.6)
        session.lean(-40, for: 0.4)
        session.flick(from: -40, to: 50, over: 0.5)
        session.flick(from: 50, to: -40)
        session.lean(-40, for: 0.2)
        #expect(session.triggers == [.swipeRight, .swipeLeft])
    }

    @Test func aHandLeftWhereTheSwipeEndedCanSwipeBackEventually() {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 3.5, shape: .halfClosed)
        session.flick(from: 50, to: -40)
        session.lean(-40, for: 0.2)
        #expect(session.triggers == [.swipeRight, .swipeLeft])
    }

    @Test func slowTurnOfTheHandIsNotASwipe() {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50, over: 0.4)
        session.lean(50, for: 0.2)
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
        session.lean(-40, for: 0.1)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 0.2)
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
        session.lean(-40, for: 0.3, shape: .fist)
        session.flick(from: -40, to: 50, shape: .fist)
        session.lean(50, for: 0.2, shape: .fist)
        session.nothing(for: 0.6)
        #expect(session.triggers.isEmpty)
    }

    @Test func palmDoesNotFireAfterASwipe() {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 2)
        #expect(session.triggers == [.swipeRight])
        #expect(session.engine.state.holdProgress == 0)
    }

    @Test func palmFiresAgainOnceTheHandHasLeftAfterASwipe() {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 0.1)
        session.nothing(for: 0.6)
        session.hold(.openPalm, for: 0.6)
        #expect(session.triggers == [.swipeRight, .palm])
    }

    @Test func anotherPoseAfterASwipeFreesThePalm() {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 0.1)
        session.hold(.fist, for: 0.6)
        session.hold(.openPalm, for: 0.6)
        #expect(session.triggers == [.swipeRight, .fist, .palm])
    }

    @Test func noSwipeOnceThePalmHoldHasFired() {
        var session = Session()
        session.lean(-40, for: 0.6)
        session.flick(from: -40, to: 50)
        session.flick(from: 50, to: -40, over: 0.2)
        session.lean(-40, for: 0.6)
        #expect(session.triggers == [.palm])

        session.nothing(for: 0.6)
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 0.1)
        #expect(session.triggers == [.palm, .swipeRight])
    }

    // MARK: Recorded gestures

    @Test(arguments: ["wrist-flick-swipes", "palm-and-back", "hand-at-face", "finger-counts"])
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
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        // A flick often leaves the hand turned over.
        session.lean(50, for: 2, shape: .backOfHand)
        #expect(session.triggers == [.swipeRight])
    }

    // MARK: Hand back by the head

    /// A face next to which the hand at `home` looks `ratio` face heights large.
    private static func face(handLooks ratio: Double, time: Double = 0) -> FaceFrame {
        FaceFrame(time: time, yaw: 0, pitch: 0, roll: 0, center: away(0, 0.8), size: palm / ratio, pupilOffset: nil)
    }

    @Test(arguments: [SyntheticHand.fist, .openPalm, .ok, .pointing])
    func handBackByTheHeadIsNotAPose(shape: SyntheticHand) {
        var session = Session()
        // At the face's own distance from the camera a palm is about 0.8 face heights.
        session.engine.ingest(Self.face(handLooks: 0.8))
        session.hold(shape, for: 2)
        #expect(session.triggers.isEmpty)
        #expect(session.engine.state.withdrawn)
        #expect(session.engine.state.pose == nil)
    }

    @Test func handHeldOutTowardsTheCameraIsRead() {
        var session = Session()
        session.engine.ingest(Self.face(handLooks: 1.15))
        session.hold(.fist, for: 1)
        #expect(session.triggers == [.fist])
        #expect(!session.engine.state.withdrawn)
    }

    @Test func handNearTheBoundaryDoesNotFlicker() {
        var session = Session()
        // Held out, then drifting back to in between: still held out.
        session.engine.ingest(Self.face(handLooks: 1.1))
        session.hold(.fist, for: 0.2)
        session.engine.ingest(Self.face(handLooks: 0.95, time: session.now))
        session.hold(.fist, for: 0.6)
        #expect(session.triggers == [.fist])

        // Back by the head, then drifting forward to in between: still back.
        var other = Session()
        other.engine.ingest(Self.face(handLooks: 0.8))
        other.hold(.fist, for: 0.2)
        other.engine.ingest(Self.face(handLooks: 0.95, time: other.now))
        other.hold(.fist, for: 1)
        #expect(other.triggers.isEmpty)
    }

    @Test func withoutAFaceEveryHandIsRead() {
        var session = Session()
        session.hold(.fist, for: 1)
        #expect(session.triggers == [.fist])
    }

    @Test func aFaceNotSeenForAWhileIsForgotten() {
        var session = Session()
        session.engine.ingest(Self.face(handLooks: 0.8))
        session.nothing(for: 4)
        session.hold(.fist, for: 1)
        #expect(session.triggers == [.fist])
    }

    @Test func swipeFromAHandBackByTheHeadStillCounts() {
        var session = Session()
        session.engine.ingest(Self.face(handLooks: 0.8))
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 0.2)
        #expect(session.triggers == [.swipeRight])
    }

    // MARK: Counting and thumbs up

    @Test func fingerCountsFireInTurn() {
        var session = Session()
        for shape in [SyntheticHand.pointing, .peace, .threeFingers, .fourFingers, .openPalm] {
            session.hold(shape, for: 0.6)
        }
        #expect(session.triggers == [.oneFinger, .twoFingers, .threeFingers, .fourFingers, .palm])
    }

    @Test func fourFingersDoNotFireAfterASwipe() {
        var session = Session()
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        // The thumb often folds in during a flick, leaving four fingers showing.
        session.lean(50, for: 2, shape: .fourFingers)
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

// MARK: - Combinations

/// Where the user's two hands are in the scenes below: the left one on their left.
private let leftSpot = Point2(x: 0.5, y: 0.5)
private let rightSpot = Point2(x: 1.1, y: 0.5)

private func leftHand(_ shape: SyntheticHand) -> SyntheticHand {
    var hand = shape.at(leftSpot)
    hand.isLeft = true
    return hand
}

/// The right hand is drawn a little larger, which makes it the one followed for its own gestures.
private func rightHand(_ shape: SyntheticHand) -> SyntheticHand {
    shape.at(rightSpot).scaled(0.17)
}

@Suite struct CombinationTests {
    private let fistAndOne = Combination(id: "fist-one", left: .fist, right: .oneFinger, eitherWay: false)

    private func session(fps: Double = 30, _ combinations: [Combination]) -> Session {
        var session = Session(fps: fps)
        session.engine.library.combinations = combinations
        return session
    }

    @Test(arguments: frameRates)
    func twoHandsHoldingTheirPosesFireTheCombinationOnce(fps: Double) {
        var session = session(fps: fps, [fistAndOne])
        session.run(2) { _ in [leftHand(.fist), rightHand(.pointing)] }
        #expect(session.triggers == [.combination("fist-one")])
        let time = session.fired.first?.time ?? 0
        #expect(time >= 0.4 - 1e-9 && time <= 0.4 + 2 / fps + 0.12)
    }

    @Test func handsTheOtherWayRoundCountOnlyWhenAllowed() {
        var strict = session([fistAndOne])
        strict.run(2) { _ in [leftHand(.pointing), rightHand(.fist)] }
        // The fist is half of a combination but this is not it, so it fires as a fist.
        #expect(strict.triggers == [.fist])

        var lenient = session([Combination(id: "either", left: .fist, right: .oneFinger, eitherWay: true)])
        lenient.run(2) { _ in [leftHand(.pointing), rightHand(.fist)] }
        #expect(lenient.triggers == [.combination("either")])
    }

    @Test func handsAreToldApartByPlaceWhenTheDetectorNamesThemTheSame() {
        var session = session([fistAndOne])
        session.run(2) { _ in
            var left = leftHand(.fist)
            left.isLeft = false
            return [left, rightHand(.pointing)]
        }
        #expect(session.triggers == [.combination("fist-one")])
    }

    @Test func thePoseOfACombinationStillFiresAloneAfterALittleLonger() {
        var session = session([fistAndOne])
        session.run(2) { _ in [rightHand(.pointing)] }
        #expect(session.triggers == [.oneFinger])
        let time = session.fired.first?.time ?? 0
        #expect(time >= 0.65 - 1e-9 && time <= 0.65 + 0.2)
    }

    @Test func posesOutsideEveryCombinationFireAsBefore() {
        var session = session([fistAndOne])
        session.run(2) { _ in [rightHand(.openPalm)] }
        #expect(session.triggers == [.palm])
        let time = session.fired.first?.time ?? 0
        #expect(time <= 0.4 + 0.2)
    }

    @Test(arguments: [0.2, 0.4, 0.6])
    func theOtherHandMayComeUpAMomentLater(delay: Double) {
        var session = session([fistAndOne])
        session.run(delay) { _ in [rightHand(.pointing)] }
        session.run(2) { _ in [leftHand(.fist), rightHand(.pointing)] }
        #expect(session.triggers == [.combination("fist-one")])
    }

    @Test func aHandThatComesUpAfterThePoseFiredStillMakesTheCombination() {
        var session = session([fistAndOne])
        session.run(1.2) { _ in [rightHand(.pointing)] }
        session.run(2) { _ in [leftHand(.fist), rightHand(.pointing)] }
        #expect(session.triggers == [.oneFinger, .combination("fist-one")])
    }

    @Test func aSecondHandShowingNothingOnlyDelaysThePose() {
        var session = session([fistAndOne])
        session.run(2) { _ in [leftHand(.halfClosed), rightHand(.pointing)] }
        #expect(session.triggers == [.oneFinger])
        #expect((session.fired.first?.time ?? 0) <= 0.65 + 0.2)
    }

    @Test func showingOneHandAgainMakesTheCombinationAgain() {
        var session = session([fistAndOne])
        session.run(1) { _ in [leftHand(.fist), rightHand(.pointing)] }
        session.run(0.6) { _ in [rightHand(.pointing)] }
        session.run(1) { _ in [leftHand(.fist), rightHand(.pointing)] }
        #expect(session.triggers == [.combination("fist-one"), .combination("fist-one")])
    }

    @Test func bothHandsMayShowTheSamePose() {
        var session = session([Combination(id: "palms", left: .palm, right: .palm)])
        session.run(2) { _ in [leftHand(.openPalm), rightHand(.openPalm)] }
        #expect(session.triggers == [.combination("palms")])
    }

    @Test func aHandThatKeepsMovingDoesNotCompleteTheCombination() {
        var session = session([fistAndOne])
        session.run(1.5) { elapsed in
            [leftHand(.fist).at(Point2(x: leftSpot.x, y: 0.3 + 0.3 * elapsed)), rightHand(.pointing)]
        }
        #expect(!session.triggers.contains(.combination("fist-one")))
    }

    @Test func aHandBackByTheHeadIsNoHalfOfACombination() {
        var session = session([fistAndOne])
        // A face as tall as 1.4 palms of the left hand: that hand is back at the face.
        session.engine.ingest(FaceFrame(time: 0, yaw: 0, pitch: 0, roll: 0, center: Point2(x: 0.8, y: 0.7), size: 0.15 * 1.4, pupilOffset: nil))
        session.run(2) { _ in [leftHand(.fist), rightHand(.pointing).scaled(0.25)] }
        #expect(session.triggers == [.oneFinger])
    }

    @Test func withoutCombinationsASecondHandChangesNothing() {
        var session = Session()
        session.run(2) { _ in [leftHand(.fist), rightHand(.pointing)] }
        #expect(session.triggers == [.oneFinger])
        #expect((session.fired.first?.time ?? 0) <= 0.4 + 0.1)
    }
}

// MARK: - Recorded shapes

@Suite struct RecordedShapeTests {
    /// Index and little finger up: a shape no built-in pose covers.
    private static let horns = SyntheticHand(curls: [.thumb: 1, .middle: 1, .ring: 1])

    /// A library holding `horns`, recorded in three takes that differ a little, as real ones do.
    private func library() throws -> GestureLibrary {
        let takes: [[Hand]] = (0..<3).map { take in
            (0..<10).map { frame in
                var shape = Self.horns
                shape.rotation = Double(take - 1) * 8
                shape.scale = 0.14 + 0.01 * Double(take)
                shape.jitter = 0.01
                shape.seed = UInt64(take * 100 + frame + 1)
                return shape.hand()
            }
        }
        let template = try #require(ShapeTemplate(hands: takes))
        var library = GestureLibrary()
        library.customGestures = [CustomGesture(id: "horns", name: "Horns", shape: template)]
        return library
    }

    @Test(arguments: [false, true])
    func aRecordedShapeHeldStillFiresItsOwnTrigger(isLeft: Bool) throws {
        var session = Session()
        session.engine.library = try library()
        var shape = Self.horns
        shape.isLeft = isLeft
        session.hold(shape, for: 1)
        #expect(session.triggers == [.custom("horns")])
        #expect(session.engine.state.pose == .custom("horns"))
    }

    @Test func builtInPosesAreReadAsBeforeNextToARecordedShape() throws {
        for pose in Pose.builtIn {
            var session = Session()
            session.engine.library = try library()
            session.hold(.shape(for: pose), for: 1)
            #expect(session.triggers == [Trigger(pose: pose)])
        }
    }

    @Test func aRecordedShapeCanBeHalfOfACombination() throws {
        var session = Session()
        var library = try library()
        library.combinations = [Combination(id: "rock", left: .custom("horns"), right: .fist, eitherWay: false)]
        session.engine.library = library
        session.run(2) { _ in [leftHand(Self.horns), rightHand(.fist)] }
        #expect(session.triggers == [.combination("rock")])
    }

    @Test func aShapeRecordedOverABuiltInPoseTakesItsPlace() throws {
        // Two fingers, as recorded, taught as a gesture of the user's own.
        let fixture = try Fixture(named: "finger-counts")
        let shown = fixture.frames.compactMap { frame -> Hand? in
            guard case .hands(let hands) = frame, (9.0...11.5).contains(hands.time) else { return nil }
            return hands.hands.max { $0.palmSize < $1.palmSize }
        }
        let third = shown.count / 3
        let template = try #require(ShapeTemplate(hands: [
            Array(shown[..<third]), Array(shown[third..<(2 * third)]), Array(shown[(2 * third)...]),
        ]))
        var engine = GestureEngine()
        engine.library.customGestures = [CustomGesture(id: "mine", name: "Mine", shape: template, alsoReadAs: .two)]

        var fired: [Trigger] = []
        for frame in fixture.frames {
            switch frame {
            case .face(let face): engine.ingest(face)
            case .hands(let hands): if let trigger = engine.ingest(hands) { fired.append(trigger) }
            }
        }
        // Only the two fingers change hands; every other pose in the recording reads as it did.
        let expected = fixture.expected.triggers.map { $0 == .twoFingers ? Trigger.custom("mine") : $0 }
        #expect(fired == expected)
    }
}

// MARK: - Recorded movements

@Suite struct RecordedMovementTests {
    /// Where the palm centre is `progress` (0...1) of the way round a circle 3 palm sizes
    /// across that starts and ends at `home`, going up and to the user's right first.
    private static func circle(_ progress: Double, clockwise: Bool = true) -> Point2 {
        let radius = 1.5 * palm
        let angle = 2 * Double.pi * progress * (clockwise ? 1 : -1)
        return Point2(x: home.x + radius * sin(angle), y: home.y + radius * (1 - cos(angle)))
    }

    /// Up, across and up again: nothing like a circle.
    private static func zigzag(_ progress: Double) -> Point2 {
        let corners = [home, away(2, 1), away(-2, 2), away(2, 3)]
        let scaled = min(max(progress, 0), 1) * Double(corners.count - 1)
        let index = min(Int(scaled), corners.count - 2)
        return corners[index] + (corners[index + 1] - corners[index]) * (scaled - Double(index))
    }

    /// Rest, one movement along `path` lasting `duration` seconds, rest.
    private static func play(
        _ path: @escaping (Double) -> Point2, over duration: Double = 0.9, with shape: SyntheticHand = .pointing,
        restingFirst rest: Double = 0.3, in session: inout Session
    ) {
        session.hold(shape, at: path(0), for: rest)
        session.run(duration) { elapsed in [shape.at(path(elapsed / duration))] }
        session.hold(shape, at: path(1), for: 0.8)
    }

    /// A library that knows the clockwise circle drawn with one finger, from four takes of it.
    private func library() throws -> GestureLibrary {
        var tracker = MovementTracker()
        var takes: [MovementSegment] = []
        var time = 0.0
        for take in 0..<4 {
            let duration = 0.8 + 0.1 * Double(take)
            let frames = Int((0.3 + duration + 0.5) * 30)
            for frame in 0..<frames {
                let elapsed = Double(frame) / 30
                let progress = min(max((elapsed - 0.3) / duration, 0), 1)
                let segment = tracker.ingest(time: time, center: Self.circle(progress), palmSize: palm, pose: .one)
                if let segment { takes.append(segment) }
                time += 1.0 / 30
            }
        }
        #expect(takes.count == 4)
        let template = try #require(MovementTemplate(takes: takes))
        #expect(template.startPose == Trigger.oneFinger.key)
        var library = GestureLibrary()
        library.customGestures = [CustomGesture(id: "circle", name: "Circle", movement: template)]
        return library
    }

    @Test(arguments: frameRates)
    func aRecordedMovementFiresOnceAsTheHandComesToRest(fps: Double) throws {
        var session = Session(fps: fps)
        session.engine.library = try library()
        Self.play({ Self.circle($0) }, in: &session)
        // The finger it was drawn with is still up afterwards, and is not a pose being shown.
        #expect(session.triggers == [.custom("circle")])
    }

    @Test func anotherMovementOrTheWrongWayRoundFiresNothing() throws {
        var session = Session()
        session.engine.library = try library()
        Self.play(Self.zigzag, in: &session)
        session.nothing(for: 0.5)
        Self.play({ Self.circle($0, clockwise: false) }, in: &session)
        #expect(!session.triggers.contains(.custom("circle")))
    }

    @Test func theMovementCountsOnlyFromTheHandShapeItWasRecordedWith() throws {
        var session = Session()
        session.engine.library = try library()
        Self.play({ Self.circle($0) }, with: .fist, in: &session)
        #expect(!session.triggers.contains(.custom("circle")))
    }

    @Test func swipesAndPosesWorkAsBeforeNextToARecordedMovement() throws {
        var session = Session()
        session.engine.library = try library()
        session.hold(.fist, for: 1)
        session.nothing(for: 0.5)
        session.lean(-40, for: 0.3)
        session.flick(from: -40, to: 50)
        session.lean(50, for: 0.3)
        #expect(session.triggers == [.fist, .swipeRight])
    }
}
