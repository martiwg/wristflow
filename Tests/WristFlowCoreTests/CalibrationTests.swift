import Foundation
import Testing
@testable import WristFlowCore

// MARK: - Recorded sessions

/// A landmark recording of real gestures and the triggers it has to produce.
private struct RecordedSession {
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

    var handFrames: [HandFrame] {
        frames.compactMap { frame in
            if case .hands(let hands) = frame { return hands }
            return nil
        }
    }

    /// What a capture of `step` would hold had it run from `start` to `end` seconds: the
    /// largest hand of every frame, and its palm size over the height of the face last seen.
    func sample(_ step: CalibrationStep, from start: Double = 0, to end: Double = .infinity) -> CalibrationSample {
        var sample = CalibrationSample(step: step)
        var face: FaceFrame?
        for frame in frames {
            switch frame {
            case .face(let seen):
                face = seen
            case .hands(let seen):
                guard seen.time >= start, seen.time <= end,
                      let hand = seen.hands.max(by: { $0.palmSize < $1.palmSize }) else { continue }
                sample.hands.append(hand)
                if let face, face.size > 0 { sample.palmToFace.append(hand.palmSize / face.size) }
            }
        }
        return sample
    }
}

/// The swipes of the swipe fixture, group by group as they were made, in seconds. Each group
/// stands for one swipe step of a calibration; the times were read off the recording.
private let swipeGroups: [(trigger: Trigger, start: Double, end: Double)] = [
    (.swipeRight, 0.8, 3.5), (.swipeLeft, 3.6, 5.8), (.swipeUp, 6.0, 8.3), (.swipeLeft, 9.3, 10.8),
    (.swipeRight, 11.0, 12.8), (.swipeUp, 12.9, 14.4), (.swipeLeft, 14.9, 17.0), (.swipeRight, 17.5, 19.5),
    (.swipeLeft, 20.2, 22.4), (.swipeRight, 22.6, 24.4), (.swipeUp, 24.9, 27.0),
]

/// The four fixtures cut up into the steps of a calibration session.
private func recordedSamples() throws -> [CalibrationSample] {
    func pose(_ pose: Pose, _ hand: Handedness) -> CalibrationStep { CalibrationStep(kind: .pose(pose), hand: hand) }

    let counts = try RecordedSession(named: "finger-counts")
    let sides = try RecordedSession(named: "palm-and-back")
    var samples = [
        counts.sample(pose(.one, .right), from: 2.5, to: 5),
        counts.sample(pose(.two, .right), from: 9, to: 11.5),
        counts.sample(pose(.three, .right), from: 15.3, to: 17.8),
        counts.sample(pose(.four, .right), from: 21.3, to: 23.8),
        counts.sample(pose(.openPalm, .right), from: 27, to: 29.5),
        counts.sample(pose(.thumbsUp, .right), from: 32.5, to: 35),
        counts.sample(pose(.fist, .right), from: 37.6, to: 39.7),
        sides.sample(pose(.openPalm, .right), from: 0, to: 2),
        sides.sample(pose(.backOfHand, .right), from: 3, to: 7),
        sides.sample(pose(.openPalm, .left), from: 9, to: 13),
        sides.sample(pose(.backOfHand, .left), from: 14, to: 19),
        try RecordedSession(named: "hand-at-face").sample(CalibrationStep(kind: .handAtFace)),
    ]
    let peaks = SwipeMeasure.peaks(in: try RecordedSession(named: "wrist-flick-swipes").handFrames)
    for group in swipeGroups {
        let made = peaks.filter { $0.direction == group.trigger && $0.time >= group.start && $0.time <= group.end }
        samples.append(CalibrationSample(step: CalibrationStep(kind: .swipe(group.trigger)), swipePeaks: made.map(\.travel)))
    }
    return samples
}

// MARK: - Synthetic people

/// A person drawn with `SyntheticHand`, whose fingers do not go as far as the factory values
/// expect: how straight their extended fingers are and how far their closed ones close.
private struct SyntheticPerson {
    /// Curl (0 straight, 1 closed) of a finger this person holds extended.
    var extendedCurl = 0.0
    /// Curl of a finger this person holds closed.
    var curledCurl = 1.0
    /// Curl of the thumb when it is held out and when it is folded in.
    var thumbOutCurl = 0.0
    var thumbInCurl = 1.0
    /// Landmark noise, in palm sizes.
    var jitter = 0.01

    func shape(for pose: Pose) -> SyntheticHand {
        var shape = SyntheticHand.shape(for: pose)
        for finger in Finger.allCases {
            let closed = (shape.curls[finger] ?? 0) > 0.5
            if finger == .thumb {
                shape.curls[finger] = closed ? thumbInCurl : thumbOutCurl
            } else {
                shape.curls[finger] = closed ? curledCurl : extendedCurl
            }
        }
        return shape
    }

    /// `count` frames of the person holding `pose`, tilted a little differently on each.
    func hands(_ pose: Pose, _ hand: Handedness, count: Int = 24) -> [Hand] {
        (0..<count).map { index in
            var shape = shape(for: pose)
            shape.isLeft = hand == .left
            shape.rotation = Double(index % 5 - 2) * 4
            shape.jitter = jitter
            shape.seed = UInt64(index + 1)
            return shape.hand()
        }
    }

    /// The pose steps of a whole session, or only those of `poses`.
    func samples(poses: [Pose] = Pose.builtIn) -> [CalibrationSample] {
        CalibrationPlan.steps.compactMap { step in
            guard case .pose(let pose) = step.kind, poses.contains(pose), let hand = step.hand else { return nil }
            return CalibrationSample(step: step, hands: hands(pose, hand))
        }
    }
}

private func meanRate(_ rates: [Double]) -> Double {
    rates.reduce(0, +) / Double(rates.count)
}

// MARK: - Plan

@Suite struct CalibrationPlanTests {
    @Test func everyPoseIsAskedWithEachHandThenFaceThenSwipes() {
        let steps = CalibrationPlan.steps
        let poses: [Pose] = [.openPalm, .backOfHand, .fist, .one, .two, .three, .four, .thumbsUp, .ok]
        var expected: [CalibrationStep] = []
        for pose in poses {
            expected.append(CalibrationStep(kind: .pose(pose), hand: .right))
            expected.append(CalibrationStep(kind: .pose(pose), hand: .left))
        }
        expected.append(CalibrationStep(kind: .handAtFace))
        expected += [Trigger.swipeLeft, .swipeRight, .swipeUp].map { CalibrationStep(kind: .swipe($0)) }
        #expect(steps == expected)
        #expect(Set(steps.map(\.id)).count == steps.count)
    }

    @Test func stepsAreNamedAndExplainedInOneSentence() {
        #expect(CalibrationPlan.steps.first?.title == "Open palm, right hand")
        #expect(CalibrationStep(kind: .pose(.ok), hand: .left).title == "OK sign, left hand")
        #expect(CalibrationStep(kind: .swipe(.swipeUp)).title == "Swipe up")
        for step in CalibrationPlan.steps {
            #expect(step.instruction.hasSuffix("."))
            #expect(step.instruction.filter { $0 == "." }.count == 1, "\(step.instruction)")
            if let hand = step.hand { #expect(step.instruction.contains("\(hand.rawValue) hand")) }
        }
    }
}

// MARK: - Calibrator

@Suite struct CalibratorTests {
    // MARK: Recorded sessions

    @Test func recordedHandsFitNearTheFactoryValues() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let (calibration, report) = Calibrator.calibrate(try recordedSamples(), now: now)
        let profile = calibration.profile
        let factory = PoseProfile.factory
        #expect(calibration.createdAt == now)

        for finger in Finger.allCases where finger != .thumb {
            let curled = profile.curledReach[finger.rawValue]
            let extended = profile.extendedReach[finger.rawValue]
            #expect(Calibrator.curledReachRange.contains(curled))
            #expect(Calibrator.extendedReachRange.contains(extended))
            #expect(extended - curled >= Calibrator.minimumBand - 1e-9)
            #expect(abs(curled - factory.curledReach[finger.rawValue]) <= 0.15)
            #expect(abs(extended - factory.extendedReach[finger.rawValue]) <= 0.15)
        }
        #expect(profile.extendedReach[Finger.thumb.rawValue] == factory.extendedReach[Finger.thumb.rawValue])
        #expect(Calibrator.thumbInRange.contains(profile.thumbInOffset))
        #expect(Calibrator.thumbOutRange.contains(profile.thumbOutOffset))
        #expect(abs(profile.thumbInOffset - factory.thumbInOffset) <= 0.1)
        #expect(abs(profile.thumbOutOffset - factory.thumbOutOffset) <= 0.1)

        // No OK sign was recorded, and nothing else of the profile is fitted.
        #expect(profile.pinchDistance == factory.pinchDistance)
        #expect(profile.minStraightness == factory.minStraightness)
        #expect(profile.minThumbStraightness == factory.minThumbStraightness)
        #expect(profile.thumbsUpTilt == factory.thumbsUpTilt)
        #expect(profile.minFacingTurn == factory.minFacingTurn)
        #expect(report.notes.contains { $0.hasPrefix("OK sign") })

        // The recorded hand at the face comes within 0.1 face heights of the hands held out.
        #expect(calibration.presentRatio == nil)
        #expect(calibration.withdrawRatio == nil)
        #expect(report.notes.contains { $0.hasPrefix("Hand at your face") })

        let travel = try #require(calibration.swipeTravel)
        #expect(Calibrator.swipeTravelRange.contains(travel))
        #expect(abs(travel - GestureConfig().swipeTravel) <= 0.1)
    }

    @Test func recordedPosesReadNoWorseAfterCalibration() throws {
        let report = Calibrator.calibrate(try recordedSamples()).report
        // Ten steps: seven poses of the right hand, its back, and the left palm and back.
        #expect(report.lines.count == 10)
        for line in report.lines {
            #expect(line.after >= line.before, "\(line.step.title)")
            #expect(line.after >= 0.8, "\(line.step.title)")
        }
    }

    @Test func referencesAreAFewHandsOfEveryPoseShown() throws {
        let samples = try recordedSamples()
        let references = Calibrator.calibrate(samples).calibration.references
        let shown: [Pose] = [.openPalm, .backOfHand, .fist, .one, .two, .three, .four, .thumbsUp]
        #expect(Set(references.keys) == Set(shown.map { Trigger(pose: $0).key }))
        // Palm and back were captured with both hands, the rest with one.
        #expect(references[Trigger.palm.key]?.count == 2 * Calibrator.referencesPerStep)
        #expect(references[Trigger.palmBack.key]?.count == 2 * Calibrator.referencesPerStep)
        #expect(references[Trigger.fist.key]?.count == Calibrator.referencesPerStep)
        let fists = samples.first { $0.step.kind == .pose(.fist) }?.hands ?? []
        #expect(references[Trigger.fist.key]?.first == fists.first)
        #expect(references[Trigger.fist.key]?.last == fists.last)
    }

    /// The key regression: the person the factory values were set on must lose nothing by
    /// calibrating. Same rule as `GestureEngineTests.recordedGesturesAreRead`.
    @Test(arguments: ["wrist-flick-swipes", "palm-and-back", "hand-at-face", "finger-counts"])
    func recordedGesturesAreStillReadAfterCalibration(name: String) throws {
        let session = try RecordedSession(named: name)
        var engine = GestureEngine()
        engine.library.calibration = Calibrator.calibrate(try recordedSamples()).calibration
        engine.config = engine.library.tuned(GestureConfig())
        var fired: [Trigger] = []
        for frame in session.frames {
            switch frame {
            case .face(let face): engine.ingest(face)
            case .hands(let hands): if let trigger = engine.ingest(hands) { fired.append(trigger) }
            }
        }
        var remaining = session.expected.triggers[...]
        var invented: [Trigger] = []
        for trigger in fired {
            if let index = remaining.firstIndex(of: trigger) {
                remaining = remaining[(index + 1)...]
            } else {
                invented.append(trigger)
            }
        }
        #expect(invented.isEmpty)
        #expect(fired.count >= session.expected.triggers.count - session.expected.mayMiss)
    }

    // MARK: Synthetic people

    @Test func personWhoseFingersGoLessFarGetsAProfileTheirPosesReadWith() {
        // Extended fingers reach 0.42 to 0.59 palm sizes instead of the 0.5 and more the
        // factory asks for, closed ones keep 0.25 to 0.37 instead of at most 0.3.
        let person = SyntheticPerson(extendedCurl: 0.31, curledCurl: 0.41)
        let (calibration, report) = Calibrator.calibrate(person.samples())

        #expect(report.lines.count == 18)
        #expect(meanRate(report.lines.map(\.before)) < 0.5)
        for line in report.lines {
            #expect(line.after >= 0.95, "\(line.step.title): \(line.after)")
        }
        #expect(calibration.profile != .factory)
        #expect(!report.notes.contains { $0.contains("finger") || $0.hasPrefix("Thumb") || $0.hasPrefix("OK sign") })

        // New frames of the same person, not the ones the profile was fitted on.
        var fresh = person
        fresh.jitter = 0.012
        for pose in Pose.builtIn {
            for hand in fresh.hands(pose, .left, count: 40).dropFirst(24) {
                #expect(PoseClassifier.classify(hand, profile: calibration.profile) == pose)
            }
        }
    }

    @Test func factoryHandsKeepReadingAfterCalibration() {
        let (calibration, report) = Calibrator.calibrate(SyntheticPerson().samples())
        for line in report.lines {
            #expect(line.before == 1)
            #expect(line.after == 1)
        }
        #expect(Calibrator.pinchRange.contains(calibration.profile.pinchDistance))
    }

    @Test func overlappingFingerKeepsItsFactoryValueAndSaysSo() {
        let person = SyntheticPerson(extendedCurl: 0.2, curledCurl: 0.8)
        var samples = person.samples()
        // The ring finger never closes: where it should be curled it is as far out as extended.
        for index in samples.indices {
            guard case .pose(let pose) = samples[index].step.kind, let hand = samples[index].step.hand,
                  PoseClassifier.fingers(in: pose)[.ring] == .curled else { continue }
            var stiff = person
            stiff.curledCurl = person.extendedCurl
            let open = stiff.hands(pose, hand)
            samples[index].hands = zip(person.hands(pose, hand), open).map { closed, open in
                var mixed = closed
                for joint in Finger.ring.joints { mixed.points[joint.rawValue] = open[joint] }
                return mixed
            }
        }
        let (calibration, report) = Calibrator.calibrate(samples)
        let factory = PoseProfile.factory
        #expect(report.notes.contains("Ring finger: curled and extended overlap; kept the standard value"))
        #expect(!report.notes.contains { $0.hasPrefix("Index finger") || $0.hasPrefix("Little finger") })
        #expect(calibration.profile.curledReach[Finger.ring.rawValue] == factory.curledReach[Finger.ring.rawValue])
        #expect(calibration.profile.extendedReach[Finger.ring.rawValue] == factory.extendedReach[Finger.ring.rawValue])
    }

    @Test func skippedStepsLeaveTheirValuesAtFactory() {
        let person = SyntheticPerson(extendedCurl: 0.25, curledCurl: 0.5)
        // Palm and fist show every finger both ways, but the thumb never folded in.
        let (calibration, report) = Calibrator.calibrate(person.samples(poses: [.openPalm, .fist]))
        let factory = PoseProfile.factory
        #expect(report.lines.count == 4)
        #expect(calibration.profile.curledReach != factory.curledReach)
        #expect(calibration.profile.extendedReach != factory.extendedReach)
        #expect(calibration.profile.thumbOutOffset == factory.thumbOutOffset)
        #expect(calibration.profile.thumbInOffset == factory.thumbInOffset)
        #expect(calibration.profile.pinchDistance == factory.pinchDistance)
        #expect(calibration.swipeTravel == nil)
        #expect(calibration.presentRatio == nil)
        #expect(report.notes.contains { $0.hasPrefix("Thumb: not captured") })
        #expect(report.notes.contains { $0.hasPrefix("OK sign: not captured") })
        #expect(report.notes.contains { $0.hasPrefix("Hand at your face: not captured") })
        #expect(report.notes.contains { $0.hasPrefix("Swipes: fewer than 4") })
        #expect(Set(calibration.references.keys) == [Trigger.palm.key, Trigger.fist.key])
    }

    @Test func nothingCapturedIsTheFactoryCalibration() {
        let now = Date(timeIntervalSince1970: 5)
        let (calibration, report) = Calibrator.calibrate([], now: now)
        #expect(calibration == PersonalCalibration(createdAt: now))
        #expect(report.lines.isEmpty)
        // Four fingers, thumb, pinch, depth and swipes.
        #expect(report.notes.count == 8)
        #expect(GestureLibrary().tuned(GestureConfig()) == GestureConfig())
    }

    @Test func fittedProfileThatReadsWorseIsNotUsed() {
        // The thumb is held out less than the factory expects but far enough for it, so the
        // fitted threshold comes down to where this person's thumb rests beside a fist: with
        // it the fist would read as a thumbs up.
        let person = SyntheticPerson(thumbOutCurl: 0.28, thumbInCurl: 0.6)
        var samples = person.samples(poses: [.openPalm, .four])
        var resting = person
        resting.thumbInCurl = 0.36
        let fist = CalibrationStep(kind: .pose(.fist), hand: .right)
        samples.append(CalibrationSample(step: fist, hands: resting.hands(.fist, .right)))

        let (calibration, report) = Calibrator.calibrate(samples)
        #expect(calibration.profile == .factory)
        #expect(report.notes.contains { $0.hasPrefix("Your poses read better with the standard values") })
        for line in report.lines {
            #expect(line.before == 1)
            #expect(line.after == line.before)
        }
        // Without the fist to object, the same thumb does get its own thresholds.
        let unguarded = Calibrator.calibrate(person.samples(poses: [.openPalm, .four])).calibration.profile
        #expect(unguarded.thumbOutOffset < PoseProfile.factory.thumbOutOffset)
        #expect(PoseClassifier.classify(resting.hands(.fist, .right)[0], profile: unguarded) == .thumbsUp)
    }

    // MARK: Fitting rules

    @Test func thresholdsLeaveTheMiddleOfTheRoomUnclear() {
        // Curled up to 0.2, extended from 0.6: the room is 0.4 wide.
        let fit = Calibrator.band(
            below: [0.1, 0.2, 0.2, 0.2], above: [0.6, 0.6, 0.6, 0.9],
            lowRange: Calibrator.curledReachRange, highRange: Calibrator.extendedReachRange
        )
        guard case .fitted(let low, let high) = fit else {
            Issue.record("Expected a fit, got \(fit)")
            return
        }
        #expect(abs(low - 0.34) < 0.01)
        #expect(abs(high - 0.46) < 0.01)
    }

    @Test func groupsCloserThanTheMinimumGapAreNotFitted() {
        let ranges = (Calibrator.curledReachRange, Calibrator.extendedReachRange)
        #expect(Calibrator.band(below: [0.3], above: [0.39], lowRange: ranges.0, highRange: ranges.1) == .overlapping)
        #expect(Calibrator.band(below: [0.5], above: [0.2], lowRange: ranges.0, highRange: ranges.1) == .overlapping)
        #expect(Calibrator.band(below: [], above: [0.7], lowRange: ranges.0, highRange: ranges.1) == .missing)
        #expect(Calibrator.band(below: [0.1], above: [], lowRange: ranges.0, highRange: ranges.1) == .missing)
        guard case .fitted = Calibrator.band(below: [0.3], above: [0.4], lowRange: ranges.0, highRange: ranges.1) else {
            Issue.record("A gap of exactly the minimum is separable")
            return
        }
    }

    @Test(arguments: [
        (-0.9, -0.5), (-0.5, 0.0), (-0.3, 1.5), (0.0, 0.1), (0.2, 0.35), (0.4, 0.52), (0.44, 0.56), (0.5, 0.65),
        (0.7, 0.85), (0.9, 2.0), (1.5, 1.7),
    ])
    func clampsHoldWhereverTheGroupsLie(curled: Double, extended: Double) {
        let pairs = [
            (Calibrator.curledReachRange, Calibrator.extendedReachRange),
            (Calibrator.thumbInRange, Calibrator.thumbOutRange),
        ]
        for (lowRange, highRange) in pairs {
            let fit = Calibrator.band(below: [curled], above: [extended], lowRange: lowRange, highRange: highRange)
            guard case .fitted(let low, let high) = fit else {
                Issue.record("Expected a fit, got \(fit)")
                continue
            }
            #expect(low >= lowRange.lowerBound - 1e-9 && low <= lowRange.upperBound + 1e-9)
            #expect(high >= highRange.lowerBound - 1e-9 && high <= highRange.upperBound + 1e-9)
            #expect(high - low >= Calibrator.minimumBand - 1e-9)
        }

        guard case .fitted(let withdraw, let present) = Calibrator.depth(atFace: [curled], heldOut: [extended]) else {
            Issue.record("Expected a depth fit")
            return
        }
        #expect(Calibrator.depthRange.contains(withdraw))
        #expect(Calibrator.depthRange.contains(present))
        #expect(withdraw <= present - Calibrator.minimumDepthBand + 1e-9)
    }

    @Test func pinchDistanceSitsBetweenTouchingAndOpenFingertips() {
        let (calibration, report) = Calibrator.calibrate(SyntheticPerson().samples(poses: [.openPalm, .ok]))
        // Touching tips are 0 apart on the skeleton and an open hand's 1: the distance is set
        // about a third of the way up from touching.
        #expect(abs(calibration.profile.pinchDistance - 0.36) < 0.02)
        #expect(Calibrator.pinchRange.contains(calibration.profile.pinchDistance))
        #expect(!report.notes.contains { $0.hasPrefix("OK sign") })
    }

    // MARK: Depth

    private func depthSamples(atFace: [Double], heldOut: [Double]) -> [CalibrationSample] {
        [
            CalibrationSample(step: CalibrationStep(kind: .pose(.fist), hand: .right), palmToFace: heldOut),
            CalibrationSample(step: CalibrationStep(kind: .handAtFace), palmToFace: atFace),
        ]
    }

    @Test func depthIsSetBetweenTheHandAtTheFaceAndTheHandHeldOut() throws {
        // A person with small hands: held out they look 0.8 to 0.9 face heights large, which
        // the factory values take for a hand by the head.
        let atFace = (0..<50).map { 0.45 + 0.15 * Double($0) / 49 }
        let heldOut = (0..<50).map { 0.8 + 0.1 * Double($0) / 49 }
        let (calibration, report) = Calibrator.calibrate(depthSamples(atFace: atFace, heldOut: heldOut))
        let withdraw = try #require(calibration.withdrawRatio)
        let present = try #require(calibration.presentRatio)
        // The room runs from 0.585 to 0.81.
        #expect(abs(withdraw - 0.641) < 0.005)
        #expect(abs(present - 0.754) < 0.005)
        #expect(!report.notes.contains { $0.hasPrefix("Hand at your face") })

        var library = GestureLibrary()
        library.calibration = calibration
        let tuned = library.tuned(GestureConfig())
        #expect(tuned.withdrawRatio == withdraw)
        #expect(tuned.presentRatio == present)
    }

    @Test func depthStaysAtFactoryWhenTheTwoLookAlike() {
        let (calibration, report) = Calibrator.calibrate(depthSamples(atFace: [0.8, 0.9, 1.0], heldOut: [1.0, 1.1, 1.2]))
        #expect(calibration.withdrawRatio == nil)
        #expect(calibration.presentRatio == nil)
        let note = "Hand at your face: it looks as large as your hand held out; kept the standard distances"
        #expect(report.notes.contains(note))
    }

    // MARK: Swipes

    private func swipeSamples(_ peaks: [Double]) -> [CalibrationSample] {
        // Spread over the three steps, as a session has them.
        [Trigger.swipeLeft, .swipeRight, .swipeUp].enumerated().map { index, trigger in
            let own = peaks.indices.filter { $0 % 3 == index }.map { peaks[$0] }
            return CalibrationSample(step: CalibrationStep(kind: .swipe(trigger)), swipePeaks: own)
        }
    }

    @Test func swipeTravelIsSetBelowThePersonsWeakerSwipes() throws {
        // Nine swipes; the 20th percentile lies between the second and third weakest.
        let peaks = [2.0, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 3.4]
        let (calibration, report) = Calibrator.calibrate(swipeSamples(peaks))
        let travel = try #require(calibration.swipeTravel)
        #expect(abs(travel - Calibrator.swipeTravelShare * 2.26) < 1e-9)
        #expect(!report.notes.contains { $0.hasPrefix("Swipes") })

        var library = GestureLibrary()
        library.calibration = calibration
        #expect(library.tuned(GestureConfig()).swipeTravel == travel)
    }

    @Test func swipeTravelStaysWithinItsRange() {
        #expect(Calibrator.calibrate(swipeSamples(Array(repeating: 1.3, count: 9))).calibration.swipeTravel == 1.6)
        #expect(Calibrator.calibrate(swipeSamples(Array(repeating: 5.0, count: 9))).calibration.swipeTravel == 2.8)
    }

    @Test func tooFewSwipesLeaveTheTravelAtFactory() {
        let (calibration, report) = Calibrator.calibrate(swipeSamples([2.5, 2.6, 2.7]))
        #expect(calibration.swipeTravel == nil)
        #expect(report.notes.contains("Swipes: fewer than 4 captured; kept the standard value"))
        #expect(Calibrator.calibrate(swipeSamples([2.5, 2.6, 2.7, 2.8])).calibration.swipeTravel != nil)
    }

    @Test func percentilesAreReadBetweenNeighbours() {
        #expect(Calibrator.percentile([3], 0.2) == 3)
        #expect(Calibrator.percentile([4, 1, 3, 2], 0) == 1)
        #expect(Calibrator.percentile([4, 1, 3, 2], 1) == 4)
        #expect(abs(Calibrator.percentile([4, 1, 3, 2], 0.5) - 2.5) < 1e-12)
        #expect(abs(Calibrator.percentile([0, 10], 0.05) - 0.5) < 1e-12)
    }
}

// MARK: - Swipe measure

private let frameRates = [10.0, 30.0]

/// An open hand of palm size 0.15 turned about its wrist, which stays where it is: 0 is
/// upright, positive leans towards the user's right.
private func leaning(_ degrees: Double, wrist: Point2 = Point2(x: 0.8, y: 0.4)) -> Hand {
    var shape = SyntheticHand.openPalm
    // The skeleton turns counter-clockwise, which in the mirror view is towards the left.
    shape.rotation = -degrees
    shape.center = .zero
    shape.center = wrist - shape.hand()[.wrist]
    return shape.hand()
}

@Suite struct SwipeMeasureTests {
    @Test func recordedSwipesAreFoundWithTheirTravel() throws {
        let session = try RecordedSession(named: "wrist-flick-swipes")
        let peaks = SwipeMeasure.peaks(in: session.handFrames)
        #expect(peaks.map(\.time) == peaks.map(\.time).sorted())

        // What the engine would call a swipe: far enough, sideways or up.
        let factoryTravel = GestureConfig().swipeTravel
        let swipes = peaks.filter { $0.direction != nil && $0.travel >= factoryTravel }
        let listed = session.expected.triggers
        // The recording also has four brisk flicks back that are not listed as swipes.
        let flicksBack = 4
        #expect(swipes.count >= listed.count - session.expected.mayMiss)
        #expect(swipes.count <= listed.count + flicksBack)
        for trigger in [Trigger.swipeLeft, .swipeRight, .swipeUp] {
            let found = swipes.filter { $0.direction == trigger }.count
            let made = listed.filter { $0 == trigger }.count
            #expect(found >= made - session.expected.mayMiss && found <= made + flicksBack, "\(trigger.key): \(found)")
        }
        // Recorded swipes cover 2.2 to 3.9 palm sizes.
        for swipe in swipes { #expect(swipe.travel <= 3.9) }

        // The rest is the hand going back after nearly every swipe, slower: under 2 palm sizes
        // more often than not, and under 3 even straight down after a swipe up.
        let rest = peaks.filter { !($0.direction != nil && $0.travel >= factoryTravel) }
        #expect(rest.count >= 30)
        let travels = rest.map(\.travel).sorted()
        #expect(travels[travels.count / 2] < 2)
        #expect(travels.allSatisfy { $0 >= SwipeMeasure.candidateTravel && $0 < 3 })
    }

    @Test func everyRecordedGroupGivesItsSwipesToItsStep() throws {
        let peaks = SwipeMeasure.peaks(in: try RecordedSession(named: "wrist-flick-swipes").handFrames)
        for group in swipeGroups {
            let asked = peaks.filter { $0.direction == group.trigger && $0.time >= group.start && $0.time <= group.end }
            #expect((3...5).contains(asked.count), "\(group.trigger.key) at \(group.start): \(asked.count)")
        }
    }

    @Test(arguments: frameRates)
    func flickAndItsSlowWayBackAreMeasuredApart(fps: Double) {
        var frames: [HandFrame] = []
        func add(_ seconds: Double, _ lean: (Double) -> Double) {
            let count = Int((seconds * fps).rounded())
            for step in 0..<count {
                let hand = leaning(lean(Double(step) / Double(count)))
                frames.append(HandFrame(time: Double(frames.count) / fps, hands: [hand]))
            }
        }
        add(0.5) { _ in -40 }
        add(0.1) { -40 + 90 * $0 }
        add(0.3) { _ in 50 }
        add(0.2) { 50 - 90 * $0 }
        add(0.5) { _ in -40 }

        let peaks = SwipeMeasure.peaks(in: frames)
        #expect(peaks.map(\.direction) == [.swipeRight, .swipeLeft])
        guard peaks.count == 2 else { return }
        // The fingertips are about 1.8 palm sizes from the wrist, so a quarter turn carries
        // them about 2.5.
        #expect((2.2...2.8).contains(peaks[0].travel))
        #expect(peaks[1].travel < peaks[0].travel - 0.3)
    }

    @Test func handCarriedAlongOrHeldStillIsNoFlick() {
        var frames: [HandFrame] = []
        for step in 0..<30 {
            frames.append(HandFrame(time: Double(step) / 30, hands: [leaning(0)]))
        }
        // The whole hand moves three palm sizes in 0.1 s: the wrist goes as far as the fingers.
        for step in 0..<4 {
            let wrist = Point2(x: 0.8 + 0.15 * Double(step), y: 0.4)
            frames.append(HandFrame(time: 1 + Double(step) / 30, hands: [leaning(0, wrist: wrist)]))
        }
        #expect(SwipeMeasure.peaks(in: frames).isEmpty)
        #expect(SwipeMeasure.peaks(in: []).isEmpty)
    }
}

// MARK: - Pose capture

/// Shows synthetic hands to a capture at a fixed frame rate.
private struct Showing {
    var capture: PoseCapture
    let fps: Double
    /// Time of the next frame.
    var time = 0.0
    private var frame = 0

    init(_ request: PoseCapture.Request, fps: Double) {
        capture = PoseCapture(request: request)
        self.fps = fps
    }

    /// Feeds frames for `seconds`; `scene` says which hands are visible at a given number of
    /// seconds into it.
    mutating func run(_ seconds: Double, _ scene: (Double) -> [SyntheticHand]) {
        for step in 0..<Int((seconds * fps).rounded()) {
            var hands: [Hand] = []
            for (index, shape) in scene(Double(step) / fps).enumerated() {
                var copy = shape
                copy.jitter = 0.01
                copy.seed = UInt64(frame * 7 + index + 1)
                hands.append(copy.hand())
            }
            capture.ingest(HandFrame(time: time, hands: hands))
            time += 1 / fps
            frame += 1
        }
    }

    mutating func show(_ shape: SyntheticHand, for seconds: Double) {
        run(seconds) { _ in [shape] }
    }

    mutating func nothing(for seconds: Double) {
        run(seconds) { _ in [] }
    }

    mutating func face(size: Double) {
        let center = Point2(x: 0.8, y: 0.6)
        capture.ingest(FaceFrame(time: time, yaw: 0, pitch: 0, roll: 0, center: center, size: size, pupilOffset: nil))
    }
}

@Suite struct PoseCaptureTests {
    private let palm = SyntheticHand.openPalm

    @Test(arguments: frameRates)
    func takesNeedTheHandLoweredInBetween(fps: Double) {
        var showing = Showing(PoseCapture.Request(takes: 3, framesPerTake: 12), fps: fps)
        #expect(showing.capture.phase == .waiting(.noHand))
        #expect(showing.capture.overallProgress == 0)

        showing.show(palm, for: 4)
        #expect(showing.capture.phase == .lowerHand(next: 2))
        #expect(showing.capture.takes.count == 1)
        #expect(abs(showing.capture.overallProgress - 1.0 / 3) < 1e-9)

        // Lowered too briefly, the hand has not been taken away.
        showing.nothing(for: 0.2)
        showing.show(palm, for: 3)
        #expect(showing.capture.phase == .lowerHand(next: 2))
        #expect(showing.capture.takes.count == 1)

        showing.nothing(for: 0.6)
        showing.show(palm, for: 3)
        #expect(showing.capture.phase == .lowerHand(next: 3))
        #expect(showing.capture.takes.count == 2)

        // Moving the hand somewhere else is taking it away too.
        showing.show(palm.at(Point2(x: 0.4, y: 0.5)), for: 3)
        #expect(showing.capture.phase == .done)
        #expect(showing.capture.overallProgress == 1)
        #expect(showing.capture.takes.map(\.count) == [12, 12, 12])

        showing.show(palm, for: 1)
        #expect(showing.capture.takes.count == 3)
    }

    @Test(arguments: frameRates)
    func framesAreCollectedOnceTheHandHasBeenSteady(fps: Double) {
        var showing = Showing(PoseCapture.Request(framesPerTake: 100), fps: fps)
        showing.show(palm, for: 0.2)
        #expect(showing.capture.phase == .waiting(.moving))
        #expect(showing.capture.overallProgress == 0)

        showing.show(palm, for: 0.5)
        guard case .capturing(take: 1, let progress) = showing.capture.phase else {
            Issue.record("Expected capturing, got \(showing.capture.phase)")
            return
        }
        #expect(progress > 0 && progress < 1)
        #expect(showing.capture.overallProgress == progress)
        #expect(showing.capture.takes.isEmpty)
    }

    @Test(arguments: frameRates)
    func slowDriftIsStillSteady(fps: Double) {
        var showing = Showing(PoseCapture.Request(framesPerTake: 12), fps: fps)
        // 0.2 palm sizes a second.
        showing.run(3) { [palm] elapsed in [palm.at(Point2(x: 0.8 + 0.03 * elapsed, y: 0.5))] }
        #expect(showing.capture.phase == .done)
    }

    @Test(arguments: frameRates)
    func movingHandIsNotCollected(fps: Double) {
        var showing = Showing(PoseCapture.Request(framesPerTake: 12), fps: fps)
        // 1.5 palm sizes a second.
        showing.run(3) { [palm] elapsed in [palm.at(Point2(x: 0.4 + 0.225 * elapsed, y: 0.5))] }
        #expect(showing.capture.phase == .waiting(.moving))
        #expect(showing.capture.overallProgress == 0)
        #expect(showing.capture.takes.isEmpty)
    }

    @Test(arguments: frameRates)
    func wrongHandIsNotCollected(fps: Double) {
        var left = palm
        left.isLeft = true
        var showing = Showing(PoseCapture.Request(hand: .right, framesPerTake: 12), fps: fps)
        showing.show(left, for: 2)
        #expect(showing.capture.phase == .waiting(.wrongHand))
        #expect(showing.capture.overallProgress == 0)

        showing.show(palm, for: 2)
        #expect(showing.capture.phase == .done)
        #expect(showing.capture.takes.first?.allSatisfy { $0.handedness == .right } == true)
    }

    @Test func handOfUnknownSideCannotBeTheAskedHand() {
        var unknown = SyntheticHand.openPalm.hand()
        unknown.handedness = nil
        var asked = PoseCapture(request: PoseCapture.Request(hand: .left, framesPerTake: 12))
        var either = PoseCapture(request: PoseCapture.Request(framesPerTake: 12))
        for step in 0..<60 {
            let frame = HandFrame(time: Double(step) / 30, hands: [unknown])
            asked.ingest(frame)
            either.ingest(frame)
        }
        #expect(asked.phase == .waiting(.unclear))
        #expect(asked.overallProgress == 0)
        #expect(either.phase == .done)
    }

    @Test func askedHandIsTakenEvenWhenTheOtherIsLarger() {
        var left = palm.at(Point2(x: 0.3, y: 0.5)).scaled(0.25)
        left.isLeft = true
        var showing = Showing(PoseCapture.Request(hand: .right, framesPerTake: 12), fps: 30)
        showing.run(2) { [palm] _ in [left, palm] }
        #expect(showing.capture.phase == .done)
        #expect(showing.capture.takes.first?.allSatisfy { $0.handedness == .right } == true)
    }

    @Test(arguments: frameRates)
    func farHandIsNotCollected(fps: Double) {
        var showing = Showing(PoseCapture.Request(framesPerTake: 12), fps: fps)
        showing.show(palm.scaled(0.04), for: 2)
        #expect(showing.capture.phase == .waiting(.tooFar))
        #expect(showing.capture.overallProgress == 0)
    }

    @Test(arguments: frameRates)
    func hardlySeenHandIsNotCollected(fps: Double) {
        var faint = palm
        faint.confidence = 0.35
        var showing = Showing(PoseCapture.Request(framesPerTake: 12), fps: fps)
        showing.show(faint, for: 2)
        #expect(showing.capture.phase == .waiting(.unclear))
        #expect(showing.capture.overallProgress == 0)

        // Seen well on the whole, but one finger is a guess.
        var guessed = palm
        guessed.doubtfulFingers = [.ring]
        showing.show(guessed, for: 2)
        #expect(showing.capture.phase == .waiting(.unclear))
        #expect(showing.capture.overallProgress == 0)

        showing.nothing(for: 0.2)
        #expect(showing.capture.phase == .waiting(.noHand))
    }

    @Test(arguments: frameRates)
    func shortDropoutPausesTheTake(fps: Double) {
        var showing = Showing(PoseCapture.Request(framesPerTake: 60), fps: fps)
        showing.show(palm, for: 1.3)
        let before = showing.capture.overallProgress
        #expect(before > 0 && before < 1)

        showing.nothing(for: 0.3)
        #expect(showing.capture.phase == .waiting(.noHand))
        #expect(showing.capture.overallProgress == before)

        // The hand is back where it was, so collecting goes on at once.
        showing.show(palm, for: 2 / fps)
        #expect(showing.capture.overallProgress > before)
        showing.show(palm, for: 7)
        #expect(showing.capture.phase == .done)
        #expect(showing.capture.takes.map(\.count) == [60])
    }

    @Test(arguments: frameRates)
    func longDropoutStartsTheTakeOver(fps: Double) {
        var showing = Showing(PoseCapture.Request(framesPerTake: 60), fps: fps)
        showing.show(palm, for: 1.3)
        let before = showing.capture.overallProgress
        #expect(before > 0 && before < 1)

        showing.nothing(for: 0.8)
        #expect(showing.capture.overallProgress == 0)

        // A hand that was gone has to be steady again first.
        showing.show(palm, for: 2 / fps)
        #expect(showing.capture.phase == .waiting(.moving))
        showing.show(palm, for: 0.6)
        #expect(showing.capture.overallProgress > 0)
        #expect(showing.capture.overallProgress < before)
    }

    @Test(arguments: frameRates)
    func movingMidTakePausesWithoutLosingIt(fps: Double) {
        var showing = Showing(PoseCapture.Request(framesPerTake: 60), fps: fps)
        showing.show(palm, for: 1.3)
        let before = showing.capture.overallProgress
        // Two palm sizes a second. The hand has to leave the steady radius to count as moving,
        // which at this speed takes up to 0.075 s.
        showing.run(0.2) { [palm] elapsed in [palm.at(Point2(x: 0.8 + 0.3 * elapsed, y: 0.5))] }
        let paused = showing.capture.overallProgress
        #expect(showing.capture.phase == .waiting(.moving))
        #expect(paused >= before && paused <= before + 3.0 / 60)

        showing.run(0.4) { [palm] elapsed in [palm.at(Point2(x: 0.86 + 0.3 * elapsed, y: 0.5))] }
        #expect(showing.capture.phase == .waiting(.moving))
        #expect(showing.capture.overallProgress == paused)
    }

    @Test(arguments: frameRates)
    func handByTheHeadIsRejectedOnlyWhenItMustBeHeldOut(fps: Double) {
        // A face 0.25 image heights tall; the palm is 0.8 of that, as against a cheek.
        let atFace = palm.scaled(0.2)
        var heldOut = Showing(PoseCapture.Request(framesPerTake: 12, heldOut: true), fps: fps)
        var anywhere = Showing(PoseCapture.Request(framesPerTake: 12, heldOut: false), fps: fps)
        for _ in 0..<20 {
            heldOut.face(size: 0.25)
            heldOut.show(atFace, for: 0.1)
            anywhere.face(size: 0.25)
            anywhere.show(atFace, for: 0.1)
        }
        #expect(heldOut.capture.phase == .waiting(.byTheHead))
        #expect(heldOut.capture.overallProgress == 0)
        #expect(anywhere.capture.phase == .done)
        #expect(anywhere.capture.palmToFace.count == 12)
        #expect(anywhere.capture.palmToFace.allSatisfy { abs($0 - 0.8) < 0.05 })

        // Held out, the same hand is nearer the camera and looks larger than the face.
        for _ in 0..<20 {
            heldOut.face(size: 0.25)
            heldOut.show(palm.scaled(0.3), for: 0.1)
        }
        #expect(heldOut.capture.phase == .done)
        #expect(heldOut.capture.palmToFace.allSatisfy { abs($0 - 1.2) < 0.05 })
    }

    @Test func withoutAFaceNoHandIsByTheHead() {
        var showing = Showing(PoseCapture.Request(framesPerTake: 12, heldOut: true), fps: 30)
        showing.show(palm.scaled(0.2), for: 2)
        #expect(showing.capture.phase == .done)
        #expect(showing.capture.palmToFace.isEmpty)

        // A face seen too long ago says nothing about now either.
        var later = Showing(PoseCapture.Request(framesPerTake: 12, heldOut: true), fps: 30)
        later.face(size: 0.25)
        later.nothing(for: GestureConfig().faceMemory + 0.5)
        later.show(palm.scaled(0.2), for: 2)
        #expect(later.capture.phase == .done)
    }

    @Test(arguments: frameRates)
    func clockThatRestartsKeepsWhatWasCollected(fps: Double) {
        var showing = Showing(PoseCapture.Request(takes: 2, framesPerTake: 60), fps: fps)
        showing.time = 500
        showing.show(palm, for: 1.3)
        let before = showing.capture.overallProgress
        #expect(before > 0 && before < 0.5)

        showing.time = 0
        showing.show(palm, for: 7)
        #expect(showing.capture.phase == .lowerHand(next: 2))
        #expect(showing.capture.takes.map(\.count) == [60])

        showing.time = 0
        showing.nothing(for: 0.6)
        showing.show(palm, for: 8)
        #expect(showing.capture.phase == .done)
    }

    @Test func requestAsksForAtLeastOneFrameOfOneTake() {
        let request = PoseCapture.Request(takes: 0, framesPerTake: -3)
        #expect(request.takes == 1)
        #expect(request.framesPerTake == 1)
        #expect(request.heldOut)
        #expect(request.hand == nil)
    }
}
