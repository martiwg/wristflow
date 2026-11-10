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

    /// Open palm at rest at `home`, long enough to arm a swipe and too short to fire the hold.
    mutating func restPalm() {
        hold(.openPalm, for: 0.25)
    }

    /// A quick sweep of the open palm from `start` to `end`.
    mutating func sweep(from start: Point2 = home, to end: Point2, shape: SyntheticHand = .openPalm) {
        move(shape, from: start, to: end, over: 0.25)
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
        (Trigger.swipeLeft, -2.5, 0.0),
        (Trigger.swipeRight, 2.5, 0.0),
        (Trigger.swipeUp, 0.0, 2.5),
    ], frameRates)
    func swipeFromRest(expected: (trigger: Trigger, dx: Double, dy: Double), fps: Double) {
        var session = Session(fps: fps)
        session.restPalm()
        session.sweep(to: away(expected.dx, expected.dy))
        session.hold(.openPalm, at: away(expected.dx, expected.dy), for: 0.2)
        session.nothing(for: 0.3)
        #expect(session.triggers == [expected.trigger])
    }

    @Test func swipeIsReadWhileThePoseIsBlurred() {
        var session = Session()
        session.restPalm()
        // A fast hand smears, and the classifier sees no pose at all on those frames.
        session.sweep(to: away(2.5, 0), shape: .halfClosed)
        session.hold(.openPalm, at: away(2.5, 0), for: 1.5)
        #expect(session.triggers == [.swipeRight])
    }

    @Test(arguments: frameRates)
    func swipeIsReadWhenTheHandVanishesDuringTheFastPart(fps: Double) {
        var session = Session(fps: fps)
        session.restPalm()
        // Smeared so badly that the detector reports no hand until it slows down again.
        session.nothing(for: 0.2)
        session.hold(.openPalm, at: away(2.5, 0), for: 0.15)
        session.sweep(from: away(2.5, 0), to: home)
        session.hold(.openPalm, for: 0.2)
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

    @Test func slightlySlantedSwipeStillCounts() {
        var session = Session()
        session.restPalm()
        session.sweep(to: away(2.5, 0.6))
        session.nothing(for: 0.3)
        #expect(session.triggers == [.swipeRight])
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

    @Test(arguments: frameRates)
    func downwardTravelFiresNothing(fps: Double) {
        var session = Session(fps: fps)
        session.restPalm()
        session.sweep(to: away(0, -2.5))
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    @Test(arguments: [(1.8, 1.8), (-1.8, 1.8), (2.2, 1.3), (1.3, 2.2), (2.0, -1.5)])
    func diagonalMovementFiresNothing(dx: Double, dy: Double) {
        var session = Session()
        session.restPalm()
        session.sweep(to: away(dx, dy))
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    @Test func shortOrSlowMovementIsNotASwipe() {
        var short = Session()
        short.restPalm()
        short.sweep(to: away(0.8, 0))
        short.nothing(for: 0.3)
        #expect(short.triggers.isEmpty)

        // About 2 palm sizes per second: too fast to be a hold, too slow to be a swipe.
        var slow = Session()
        slow.hold(.openPalm, for: 0.2)
        slow.move(.openPalm, from: home, to: away(2.5, 0), over: 1.2, eased: false)
        slow.nothing(for: 0.3)
        #expect(slow.triggers.isEmpty)
    }

    @Test(arguments: [0.0, 0.1], frameRates)
    func returnStrokeIsIgnored(pause: Double, fps: Double) {
        var session = Session(fps: fps)
        session.restPalm()
        session.sweep(to: away(2.5, 0))
        session.hold(.openPalm, at: away(2.5, 0), for: pause)
        session.sweep(from: away(2.5, 0), to: home)
        session.hold(.openPalm, for: 0.2)
        session.nothing(for: 0.3)
        #expect(session.triggers == [.swipeRight])
    }

    @Test(arguments: frameRates)
    func swipeReturnRestSwipeGivesTwoSwipes(fps: Double) {
        var session = Session(fps: fps)
        session.restPalm()
        session.sweep(to: away(2.5, 0))
        session.sweep(from: away(2.5, 0), to: home)
        session.hold(.openPalm, for: 0.5)
        session.sweep(to: away(2.5, 0))
        session.hold(.openPalm, at: away(2.5, 0), for: 1)
        #expect(session.triggers == [.swipeRight, .swipeRight])
    }

    @Test func palmDoesNotFireAfterASwipe() {
        var session = Session()
        session.restPalm()
        session.sweep(to: away(0, 2.5))
        session.hold(.openPalm, at: away(0, 2.5), for: 2)
        #expect(session.triggers == [.swipeUp])
        #expect(session.engine.state.holdProgress == 0)
    }

    @Test func palmFiresAgainOnceTheHandHasChangedAfterASwipe() {
        var session = Session()
        session.restPalm()
        session.sweep(to: away(2.5, 0))
        session.hold(.halfClosed, at: away(2.5, 0), for: 0.3)
        session.hold(.openPalm, at: away(2.5, 0), for: 0.6)
        #expect(session.triggers == [.swipeRight, .palm])
    }

    @Test func noSwipeOnceThePalmHoldHasFired() {
        var session = Session()
        session.hold(.openPalm, for: 0.6)
        session.sweep(to: away(2.5, 0))
        session.sweep(from: away(2.5, 0), to: home)
        session.hold(.openPalm, for: 0.6)
        #expect(session.triggers == [.palm])

        session.nothing(for: 0.3)
        session.restPalm()
        session.sweep(to: away(2.5, 0))
        #expect(session.triggers == [.palm, .swipeRight])
    }

    @Test func fistDoesNotSwipe() {
        var session = Session()
        session.hold(.fist, for: 0.25)
        session.sweep(to: away(2.5, 0), shape: .fist)
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
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
        session.run(0.3) { _ in [tracked, other] }
        #expect(session.engine.state.armedForSwipe)
        session.run(0.3) { _ in [other] }
        session.nothing(for: 0.3)
        #expect(session.triggers.isEmpty)
    }

    // MARK: State and configuration

    @Test func stateFollowsTheHand() {
        var session = Session()
        #expect(session.engine.state == GestureState())

        session.hold(.openPalm, for: 0.25)
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
