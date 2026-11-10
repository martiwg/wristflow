import Foundation
import Testing
@testable import WristFlowCore

// MARK: - Recordings

/// The hand frames of a recording in Fixtures.
private func handFrames(_ name: String) throws -> [HandFrame] {
    let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    return try Recording.load(folder.appendingPathComponent("\(name).jsonl")).compactMap { frame in
        if case .hands(let hands) = frame { return hands }
        return nil
    }
}

private let fingerCounts = Result { try handFrames("finger-counts") }
private let palmAndBack = Result { try handFrames("palm-and-back") }

/// The largest hand of each frame in a stretch of a recording, given in seconds.
private func hands(in frames: [HandFrame], _ seconds: ClosedRange<Double>) -> [Hand] {
    frames.filter { seconds.contains($0.time) }.compactMap { frame in
        frame.hands.max { $0.palmSize < $1.palmSize }
    }
}

/// A stretch of Fixtures/finger-counts.jsonl in which one right hand holds a shape.
private struct Segment {
    let id: String
    /// What the built-in classifier calls the shape.
    let pose: Pose
    let seconds: ClosedRange<Double>
}

/// One finger is taken from 3 s on: the hand is held from 2.5 s, but the detector loses it at
/// 2.75 s and finds it again for two frames with the index finger down, which are not the shape
/// (see `framesOfAnotherShapeInARecordingAreLeftOut`). Two, three and four show the back of the hand.
private let segments = [
    Segment(id: "one", pose: .one, seconds: 3...5),
    Segment(id: "two", pose: .two, seconds: 9...11.5),
    Segment(id: "three", pose: .three, seconds: 15.3...17.8),
    Segment(id: "four", pose: .four, seconds: 21.3...23.8),
    Segment(id: "palm", pose: .openPalm, seconds: 27...29.5),
    Segment(id: "thumbsUp", pose: .thumbsUp, seconds: 32.5...35),
    Segment(id: "fist", pose: .fist, seconds: 37.6...39.7),
]

/// A shape learned from the first part of a segment, and the rest of the segment to try it on.
private struct Enrolled {
    let id: String
    let pose: Pose
    let template: ShapeTemplate
    /// The first three fifths of the segment, cut into three as if they were separate takes.
    let takes: [[Hand]]
    /// The frames the template has not seen.
    let rest: [Hand]

    init(_ segment: Segment) throws {
        let all = hands(in: try fingerCounts.get(), segment.seconds)
        let enrolment = all.count * 3 / 5
        let third = enrolment / 3
        id = segment.id
        pose = segment.pose
        takes = [Array(all[..<third]), Array(all[third..<(2 * third)]), Array(all[(2 * third)..<enrolment])]
        rest = Array(all[enrolment...])
        template = try #require(ShapeTemplate(hands: takes))
    }

    static func all() throws -> [Enrolled] { try segments.map(Enrolled.init) }
}

private func enrolled(_ id: String) throws -> Enrolled {
    try Enrolled(try #require(segments.first { $0.id == id }))
}

// MARK: - Synthetic hands

/// A shape that is none of the built-in poses: index and little finger up.
private let horns = SyntheticHand(curls: [.thumb: 1, .middle: 1, .ring: 1])

/// A synthetic shape shown three times as a user would record it: landmark noise in every
/// frame, and the hand a little differently tilted and sized each time.
private func takes(of shape: SyntheticHand, tilts: [Double] = [-5, 0, 5], frames: Int = 10) -> [[Hand]] {
    tilts.enumerated().map { take, tilt in
        (0..<frames).map { frame in
            var copy = shape
            copy.rotation += tilt
            copy.scale = 0.12 + 0.02 * Double(take)
            copy.jitter = 0.015
            copy.seed = UInt64(take * 100 + frame + 1)
            return copy.hand()
        }
    }
}

/// One take of `horns` for each bend of the index finger (0 straight, 1 closed).
private func takes(ofHornsWithIndexBentBy bends: [Double]) -> [[Hand]] {
    bends.map { bend in
        var shape = horns
        shape.curls[.index] = bend
        return takes(of: shape, tilts: [0])[0]
    }
}

private func example(_ shape: SyntheticHand) throws -> ShapeExample {
    try #require(ShapeExample(shape.hand()))
}

// MARK: - One hand

@Suite struct ShapeExampleTests {
    @Test func shapeDoesNotDependOnPlaceSizeTiltOrHand() throws {
        for shape in [SyntheticHand.openPalm, .thumbsUp, .peace, horns] {
            let reference = try example(shape)
            for isLeft in [false, true] {
                for (scale, rotation) in [(0.07, -160.0), (0.15, 35.0), (0.3, 90.0)] {
                    var copy = shape.at(Point2(x: 0.3, y: 0.7)).scaled(scale)
                    copy.rotation = rotation
                    copy.isLeft = isLeft
                    // Only the rounding to 4 decimals is left.
                    #expect(try example(copy).distance(to: reference) < 0.001)
                }
            }
        }
    }

    @Test func frameHasTheWristAtTheOriginAndTheMiddleKnuckleStraightUp() throws {
        var tilted = SyntheticHand.peace
        tilted.rotation = 70
        let shown = try example(tilted)
        #expect(shown.points.count == Joint.allCases.count)
        #expect(shown.points[Joint.wrist.rawValue] == .zero)
        #expect(shown.points[Joint.middleMCP.rawValue] == Point2(x: 0, y: 1))
    }

    @Test func tiltLeansOutwardsOnBothHands() throws {
        // `rotation` is counter-clockwise, so a negative one leans to the user's right, which
        // is outwards for a right hand; a left hand leans outwards the other way.
        var right = SyntheticHand.openPalm
        right.rotation = -30
        var left = SyntheticHand.openPalm
        left.isLeft = true
        left.rotation = 30
        #expect(abs(try example(right).tilt - 30) < 0.1)
        #expect(abs(try example(left).tilt - 30) < 0.1)

        right.rotation = 30
        #expect(abs(try example(right).tilt + 30) < 0.1)
        right.rotation = 180
        #expect(abs(abs(try example(right).tilt) - 180) < 0.1)
    }

    @Test func sideShownFollowsTheClassifier() throws {
        var leftBack = SyntheticHand.backOfHand
        leftBack.isLeft = true
        #expect(try example(.openPalm).palmFacing == true)
        #expect(try example(.backOfHand).palmFacing == false)
        #expect(try example(leftBack).palmFacing == false)

        var unknown = SyntheticHand.openPalm.hand()
        unknown.handedness = nil
        #expect(try #require(ShapeExample(unknown)).palmFacing == nil)
    }

    @Test func oneFingerDecidesTheDistance() throws {
        // Three and four fingers differ in the little finger alone.
        let three = try example(.threeFingers)
        let four = try example(.fourFingers)
        let little = Finger.little.joints.map { three.points[$0.rawValue].distance(to: four.points[$0.rawValue]) }
        let overall = zip(three.points, four.points).map { $0.distance(to: $1) }
        #expect(abs(three.distance(to: four) - little.reduce(0, +) / 4) < 1e-9)
        #expect(three.distance(to: four) > ShapeTemplate.thresholdRange.upperBound)
        // Averaged over the whole hand the same difference would pass for the same shape.
        #expect(overall.reduce(0, +) / Double(overall.count) < ShapeTemplate.thresholdRange.lowerBound)
        #expect(three.distance(to: three) == 0)
    }

    @Test func handsThatCannotBeTrustedGiveNoExample() {
        var doubtful = SyntheticHand.openPalm
        doubtful.doubtfulFingers = [.ring]
        #expect(ShapeExample(doubtful.hand()) == nil)

        let point = Point2(x: 0.5, y: 0.5)
        let collapsed = Hand(
            handedness: .right, points: Array(repeating: point, count: Joint.allCases.count),
            confidences: Array(repeating: 0.9, count: Joint.allCases.count)
        )
        #expect(ShapeExample(collapsed) == nil)
    }
}

// MARK: - Templates

@Suite struct ShapeTemplateTests {
    @Test func tooLittleGivesNoTemplate() {
        #expect(ShapeTemplate(takes: []) == nil)
        #expect(ShapeTemplate(takes: [[], []]) == nil)
        #expect(ShapeTemplate(hands: takes(of: horns, tilts: [0], frames: ShapeTemplate.minFrames - 1)) == nil)
        #expect(ShapeTemplate(hands: takes(of: horns, tilts: [0], frames: ShapeTemplate.minFrames)) != nil)

        // Frames the detector was unsure of do not count.
        var doubtful = horns
        doubtful.doubtfulFingers = [.index]
        #expect(ShapeTemplate(hands: takes(of: doubtful)) == nil)
    }

    @Test func takesOfDifferentShapesGiveNoTemplate() {
        let mixed = takes(of: .openPalm, tilts: [0]) + takes(of: .fist, tilts: [0])
        #expect(ShapeTemplate(hands: mixed) == nil)
    }

    @Test func examplesAreFewAndCoverTheTakes() throws {
        for shape in try Enrolled.all() {
            #expect(shape.template.examples.count <= ShapeTemplate.maxExamples)
            #expect(!shape.template.examples.isEmpty)
            let recorded = shape.takes.joined().compactMap(ShapeExample.init)
            let uncovered = recorded.filter { !shape.template.matches($0) }
            #expect(uncovered.isEmpty, "\(shape.id): \(uncovered.count) of \(recorded.count) recorded frames")
        }
    }

    @Test func identicalFramesAreStoredOnce() throws {
        let frame = try example(horns)
        let take = Array(repeating: frame, count: 10)
        let template = try #require(ShapeTemplate(takes: [take, take, take]))
        #expect(template.examples == [frame])
    }

    @Test func strayFramesDoNotBecomeExamples() throws {
        // A hand that is still closed in the first frames of a take and already closing in
        // the last one.
        let closing = SyntheticHand(curls: [.thumb: 0.6, .index: 0.6, .middle: 0.6, .ring: 0.6, .little: 0.6])
        var recorded = takes(of: .openPalm)
        recorded[0].insert(SyntheticHand.fist.hand(), at: 0)
        recorded[0].insert(closing.hand(), at: 1)
        recorded[2].append(closing.hand())

        let template = try #require(ShapeTemplate(hands: recorded))
        for stray in [try example(.fist), try example(closing)] {
            #expect(!template.matches(stray))
            #expect(template.examples.allSatisfy { $0.distance(to: stray) > ShapeTemplate.maxSameShapeDistance })
        }
        // They leave no trace at all: not in the threshold, the tilt or the side either.
        #expect(template == ShapeTemplate(hands: takes(of: .openPalm)))
    }

    @Test func framesOfAnotherShapeInARecordingAreLeftOut() throws {
        // From 2.5 s the recorded hand holds up one finger, except for two frames near 2.9 s
        // in which the index finger is down.
        let recorded = hands(in: try fingerCounts.get(), 2.5...4)
        let third = recorded.count / 3
        let template = try #require(ShapeTemplate(hands: [
            Array(recorded[..<third]), Array(recorded[third..<(2 * third)]), Array(recorded[(2 * third)...]),
        ]))
        let strays = recorded.compactMap(ShapeExample.init).filter { !template.matches($0) }
        #expect(strays.count == 2)
        let fist = try enrolled("fist")
        #expect(fist.rest.compactMap(ShapeExample.init).allSatisfy { !template.matches($0) })
        #expect(try enrolled("one").rest.compactMap(ShapeExample.init).allSatisfy(template.matches))
    }

    @Test func thresholdFollowsTheSpreadBetweenTakesWithinItsRange() throws {
        // Takes that are alike: the spread is landmark noise, and the threshold its lower bound.
        let steady = try #require(ShapeTemplate(hands: takes(of: horns)))
        #expect(steady.threshold == ShapeTemplate.thresholdRange.lowerBound)

        // The index finger a little more bent in each take, far enough apart to lift the
        // threshold off its lower bound.
        let loose = takes(ofHornsWithIndexBentBy: [0, 0.22, 0.44])
        let spread = try #require(ShapeTemplate.spread(between: loose.map { $0.compactMap(ShapeExample.init) }))
        let looseTemplate = try #require(ShapeTemplate(hands: loose))
        #expect(abs(looseTemplate.threshold - spread * ShapeTemplate.spreadFactor) < 1e-9)
        #expect(looseTemplate.threshold > ShapeTemplate.thresholdRange.lowerBound)
        #expect(looseTemplate.threshold < ShapeTemplate.thresholdRange.upperBound)

        // Farther apart than one shape is: the threshold stops at its upper bound.
        let apart = try #require(ShapeTemplate(hands: takes(ofHornsWithIndexBentBy: [0, 0.4, 0.8])))
        #expect(apart.threshold == ShapeTemplate.thresholdRange.upperBound)

        // A single take says nothing about the spread.
        let single = try #require(ShapeTemplate(hands: takes(of: horns, tilts: [0])))
        #expect(single.threshold == ShapeTemplate.singleTakeThreshold)
        #expect(ShapeTemplate.thresholdRange.contains(ShapeTemplate.singleTakeThreshold))
    }

    @Test func thumbsDownIsNotThumbsUp() throws {
        let template = try #require(ShapeTemplate(hands: takes(of: .thumbsUp)))
        var down = SyntheticHand.thumbsUp
        down.rotation = 180
        let shown = try example(down)
        // In the hand's own frame it is the same shape; only the tilt tells them apart.
        #expect(template.examples.contains { $0.distance(to: shown) <= template.threshold })
        #expect(template.distance(to: shown) == nil)
        #expect(!template.matches(shown))
        #expect(ShapeMatcher.match(down.hand(), among: [("thumbsUp", template)]) == nil)

        var sideways = SyntheticHand.thumbsUp
        sideways.rotation = 90
        #expect(!template.matches(try example(sideways)))
    }

    @Test(arguments: [false, true])
    func shapeMatchesTiltedAtAnotherSizeOnEitherHand(isLeft: Bool) throws {
        for shape in [SyntheticHand.thumbsUp, .peace, .openPalm, horns] {
            let template = try #require(ShapeTemplate(hands: takes(of: shape)))
            for rotation in [-20.0, 20.0] {
                for scale in [0.07, 0.3] {
                    var shown = shape.scaled(scale).at(Point2(x: 1.2, y: 0.3))
                    shown.rotation = rotation
                    shown.isLeft = isLeft
                    shown.jitter = 0.015
                    shown.seed = 77
                    #expect(template.matches(try example(shown)), "rotation \(rotation), scale \(scale)")
                }
            }
        }
    }

    @Test func shapeRecordedAtEveryTiltMatchesAtAnyTilt() throws {
        let template = try #require(ShapeTemplate(hands: takes(of: horns, tilts: [0, 90, 180, 270])))
        #expect(template.tiltCentre == nil)
        #expect(template.tiltTolerance == nil)
        var shown = horns
        shown.rotation = 135
        #expect(template.matches(try example(shown)))
    }

    @Test func tiltAllowedIsWhatWasRecordedPlusAMargin() throws {
        let template = try #require(ShapeTemplate(hands: takes(of: horns, tilts: [-30, 0, 30])))
        let centre = try #require(template.tiltCentre)
        let tolerance = try #require(template.tiltTolerance)
        #expect(abs(centre) < 2)
        #expect(abs(tolerance - (30 + ShapeTemplate.tiltMargin)) < 2)
        for (rotation, expected) in [(70.0, true), (-70.0, true), (80.0, false), (-80.0, false)] {
            var shown = horns
            shown.rotation = rotation
            #expect(template.matches(try example(shown)) == expected, "rotation \(rotation)")
        }
    }

    @Test func sideIsRequiredOnlyWhenTheRecordingAgreedOnIt() throws {
        #expect(try enrolled("palm").template.palmFacing == true)
        #expect(try enrolled("two").template.palmFacing == false)
        // The knuckles of the recorded fist are too close to edge-on to call a side in every frame.
        #expect(try enrolled("fist").template.palmFacing == nil)

        // A hand whose side cannot be told is judged by its shape alone.
        let palm = try #require(ShapeTemplate(hands: takes(of: .openPalm)))
        var edgeOn = try example(.openPalm)
        edgeOn.palmFacing = nil
        #expect(palm.matches(edgeOn))
        edgeOn.palmFacing = false
        #expect(!palm.matches(edgeOn))
    }

    @Test func templateSurvivesAFileRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for shape in try Enrolled.all() {
            let data = try encoder.encode(shape.template)
            let decoded = try JSONDecoder().decode(ShapeTemplate.self, from: data)
            #expect(decoded == shape.template)
            #expect(try encoder.encode(decoded) == data)
            // 42 coordinates of at most 7 characters and a comma each, plus tilt and side.
            #expect(data.count <= 400 * shape.template.examples.count + 200, "\(shape.id): \(data.count) bytes")
        }
    }

    @Test func recordedShapeIsReadBackFromTheLibrary() throws {
        let gesture = CustomGesture(name: "Horns", shape: try #require(ShapeTemplate(hands: takes(of: horns))))
        var library = GestureLibrary()
        library.customGestures = [gesture]
        let decoded = try JSONDecoder().decode(GestureLibrary.self, from: JSONEncoder().encode(library))
        #expect(decoded == library)
        #expect(ShapeMatcher.match(horns.hand(), among: decoded.shapes) == gesture.id)
        #expect(ShapeMatcher.match(SyntheticHand.peace.hand(), among: decoded.shapes) == nil)
    }

    @Test func exampleWithMissingCoordinatesIsNotDecoded() {
        let short = Data(#"{"points":[0,0,0,1],"tilt":0}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ShapeExample.self, from: short) }
    }
}

// MARK: - Recorded hands

@Suite struct ShapeMatcherTests {
    @Test func recordedShapeMatchesTheRestOfItsHoldAndNoOtherShape() throws {
        let shapes = try Enrolled.all()
        for shape in shapes {
            let own = shape.rest.compactMap(ShapeExample.init)
            // The detector doubts a joint in a few frames of the three-finger hold.
            #expect(own.count * 10 >= shape.rest.count * 8, "\(shape.id): \(own.count) of \(shape.rest.count) readable")
            let missed = own.filter { !shape.template.matches($0) }
            #expect(missed.isEmpty, "\(shape.id) missed \(missed.count) of \(own.count) of its own frames")

            for other in shapes where other.id != shape.id {
                let frames = (other.takes.joined() + other.rest).compactMap(ShapeExample.init)
                let taken = frames.filter(shape.template.matches)
                #expect(taken.isEmpty, "\(shape.id) matched \(taken.count) of \(frames.count) frames of \(other.id)")
            }
        }
    }

    @Test func differentShapesStayFartherApartThanAnyThreshold() throws {
        let shapes = try Enrolled.all()
        for shape in shapes {
            for other in shapes where other.id != shape.id {
                let frames = (other.takes.joined() + other.rest).compactMap(ShapeExample.init)
                // Three and four fingers are the closest pair, at 0.40.
                let nearest = frames.compactMap(shape.template.distance(to:)).min() ?? .infinity
                #expect(nearest > 0.39, "\(shape.id) to \(other.id): \(nearest)")
            }
        }
    }

    @Test func palmRecordedWithOneHandMatchesBothHandsAndNeitherBack() throws {
        let palm = try enrolled("palm").template
        let recording = try palmAndBack.get()
        // The steady part of each hold. These palms are from another session than the template,
        // 0.13 to 0.22 palm sizes from it, which a threshold at its lower bound only just covers:
        // all 45 right-hand frames and 94 of the 95 left-hand ones when this was written.
        for seconds in [0.5...2, 9.6...12.9] {
            let shown = hands(in: recording, seconds).compactMap(ShapeExample.init)
            let matched = shown.count(where: palm.matches)
            #expect(shown.count >= 45)
            #expect(matched * 100 >= shown.count * 95, "\(matched) of \(shown.count) from \(seconds.lowerBound) s")
        }

        for seconds in [3...7.0, 14...19.0] {
            let back = hands(in: recording, seconds).compactMap(ShapeExample.init)
            #expect(back.count > 100)
            #expect(!back.contains(where: palm.matches))
            // The side shown rules a back out, and so would its shape alone: the thumb is on
            // the other side of the hand.
            var eitherSide = palm
            eitherSide.palmFacing = nil
            #expect(back.allSatisfy { palm.distance(to: $0) == nil })
            #expect(!back.contains(where: eitherSide.matches))
            #expect(back.allSatisfy { $0.palmFacing == false })
        }
    }

    @Test func matchNamesTheShapeHeld() throws {
        let shapes = try Enrolled.all()
        let templates = shapes.map { (id: $0.id, template: $0.template) }
        for shape in shapes {
            let readable = shape.rest.filter { ShapeExample($0) != nil }
            let named = readable.filter { ShapeMatcher.match($0, among: templates) == shape.id }
            #expect(named.count == readable.count, "\(shape.id): \(named.count) of \(readable.count)")
        }
        #expect(ShapeMatcher.match(try #require(shapes.first?.rest.first), among: []) == nil)

        var doubtful = SyntheticHand.openPalm
        doubtful.doubtfulFingers = [.thumb]
        #expect(ShapeMatcher.match(doubtful.hand(), among: templates) == nil)
    }

    @Test func closestShapeWinsWhenSeveralMatch() throws {
        var bent = horns
        bent.curls[.index] = 0.2
        let straightTemplate = try #require(ShapeTemplate(hands: takes(of: horns)))
        let bentTemplate = try #require(ShapeTemplate(hands: takes(of: bent)))
        let shapes = [(id: "straight", template: straightTemplate), (id: "bent", template: bentTemplate)]
        #expect(straightTemplate.matches(try example(bent)))
        #expect(ShapeMatcher.match(bent.hand(), among: shapes) == "bent")
        #expect(ShapeMatcher.match(horns.hand(), among: shapes) == "straight")
        #expect(ShapeMatcher.match(horns.hand(), among: shapes.reversed()) == "straight")
    }

    @Test func swipingHandIsNotReadAsARecordedCountThumbOrFist() throws {
        let templates = try Enrolled.all().map { (id: $0.id, template: $0.template) }
        // The swipes are made with an open hand, seen from the palm, the back and the edge.
        let openPoses: [Pose?] = [.openPalm, .backOfHand, .four]
        var notOpen = 0
        var notOpenMatched = 0
        var wrong: [String] = []
        for frame in try handFrames("wrist-flick-swipes") {
            for hand in frame.hands {
                let id = ShapeMatcher.match(hand, among: templates)
                if let id, id != "palm", id != "four" { wrong.append("\(id) at \(frame.time) s") }
                guard !openPoses.contains(PoseClassifier.classify(hand)) else { continue }
                notOpen += 1
                if id != nil { notOpenMatched += 1 }
            }
        }
        #expect(wrong.isEmpty, "\(wrong)")
        // Of the hands the classifier does not read as open, a few are open enough for the
        // recorded palm or four fingers: 6 of 375 when this was written.
        #expect(notOpen > 300)
        #expect(notOpenMatched * 100 <= notOpen * 3, "\(notOpenMatched) of \(notOpen)")
    }
}

// MARK: - Review

@Suite struct ShapeReviewTests {
    private func review(
        _ takes: [[Hand]], others: [(id: String, template: ShapeTemplate)] = []
    ) throws -> ShapeMatcher.Review {
        let template = try #require(ShapeTemplate(hands: takes))
        return ShapeMatcher.review(takes: takes, template: template, others: others, profile: .factory)
    }

    @Test func shapeThatIsABuiltInPoseIsReported() throws {
        for pose in [Pose.fist, .two, .openPalm, .backOfHand, .ok] {
            let result = try review(takes(of: .shape(for: pose)))
            #expect(result.builtIn == pose)
            #expect(result.builtInShare > 0.9)
        }
        for shape in try Enrolled.all() {
            let result = try review(shape.takes)
            #expect(result.builtIn == shape.pose)
            #expect(result.builtInShare > 0.9, "\(shape.id): \(result.builtInShare)")
        }
    }

    @Test func shapeOfItsOwnIsNoBuiltInPose() throws {
        let result = try review(takes(of: horns))
        #expect(result.builtIn == nil)
        #expect(result.builtInShare == 0)
    }

    @Test func shapeHalfTheTimeABuiltInPoseIsReported() throws {
        let mostlyHorns = takes(of: horns, tilts: [0, 0]) + takes(of: .pointing, tilts: [0], frames: 6)
        let template = try #require(ShapeTemplate(hands: takes(of: horns)))
        let few = ShapeMatcher.review(takes: mostlyHorns, template: template, others: [], profile: .factory)
        #expect(few.builtIn == nil)

        let halfPointing = takes(of: horns, tilts: [0]) + takes(of: .pointing, tilts: [0])
        let half = ShapeMatcher.review(takes: halfPointing, template: template, others: [], profile: .factory)
        #expect(half.builtIn == .one)
        #expect(half.builtInShare == 0.5)
    }

    @Test func sameShapeRecordedTwiceIsReportedAsSimilar() throws {
        // Twice in one sitting.
        var again = horns
        again.seed = 500
        let first = try #require(ShapeTemplate(hands: takes(of: horns)))
        #expect(try review(takes(of: again, tilts: [-8, 3, 9]), others: [("first", first)]).similar == ["first"])

        // In another session, with either hand.
        let palm = try enrolled("palm")
        let recording = try palmAndBack.get()
        let others = [(id: "palm", template: palm.template), (id: "two", template: try enrolled("two").template)]
        for seconds in [0.5...2, 9.6...12.9] {
            let shown = hands(in: recording, seconds)
            let third = shown.count / 3
            let recorded = [Array(shown[..<third]), Array(shown[third..<(2 * third)]), Array(shown[(2 * third)...])]
            #expect(try review(recorded, others: others).similar == ["palm"])
        }
    }

    @Test func distinctShapesAreNotReportedAsSimilar() throws {
        let shapes = try Enrolled.all()
        for shape in shapes {
            let others = shapes.filter { $0.id != shape.id }.map { (id: $0.id, template: $0.template) }
            #expect(try review(shape.takes, others: others).similar.isEmpty, "\(shape.id)")
        }
        // The same shape the other way up is a shape of its own.
        var down = SyntheticHand.thumbsUp
        down.rotation = 180
        let up = try #require(ShapeTemplate(hands: takes(of: .thumbsUp)))
        #expect(try review(takes(of: down), others: [("up", up)]).similar.isEmpty)
    }

    @Test func threeAndFourFingersStayDistinctAtTheLoosestThresholds() throws {
        var three = try enrolled("three").template
        var four = try enrolled("four").template
        three.threshold = ShapeTemplate.thresholdRange.upperBound
        four.threshold = ShapeTemplate.thresholdRange.upperBound
        let result = ShapeMatcher.review(
            takes: try enrolled("three").takes, template: three, others: [("four", four)], profile: .factory
        )
        #expect(result.similar.isEmpty)
    }

    @Test func takesThatAgreeAreConsistent() throws {
        for shape in try Enrolled.all() {
            let result = try review(shape.takes)
            #expect(result.isConsistent, "\(shape.id)")
            #expect(result.spread > 0)
            #expect(result.spread <= ShapeMatcher.maxConsistentSpread, "\(shape.id): \(result.spread)")
        }
        let single = try review(takes(of: horns, tilts: [0]))
        #expect(single.spread == 0)
        #expect(single.isConsistent)
    }

    @Test func takesOfDifferentShapesAreNotConsistent() throws {
        let mixed = takes(of: horns, tilts: [-5, 5]) + takes(of: .peace, tilts: [0])
        let result = try review(mixed)
        #expect(!result.isConsistent)
        #expect(result.spread > ShapeTemplate.thresholdRange.upperBound)
    }
}
