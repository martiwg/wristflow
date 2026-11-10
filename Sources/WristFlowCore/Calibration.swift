import Foundation

/// What a calibration run measured on one person. Values left nil keep their factory setting.
public struct PersonalCalibration: Codable, Equatable, Sendable {
    /// Thresholds for reading hand shapes, fitted to this person's fingers.
    public var profile: PoseProfile
    /// Palm size, in face heights, from which this person's hand counts as held out.
    public var presentRatio: Double?
    /// Palm size, in face heights, below which this person's hand counts as back by the head.
    public var withdrawRatio: Double?
    /// How far this person's fingertips must travel for a swipe, in palm sizes.
    public var swipeTravel: Double?
    public var createdAt: Date
    /// A few of this person's own hands for each built-in pose, by `Trigger.key`, to compare
    /// newly recorded shapes with.
    public var references: [String: [Hand]]

    public init(
        profile: PoseProfile = .factory, presentRatio: Double? = nil, withdrawRatio: Double? = nil,
        swipeTravel: Double? = nil, createdAt: Date = Date(), references: [String: [Hand]] = [:]
    ) {
        self.profile = profile
        self.presentRatio = presentRatio
        self.withdrawRatio = withdrawRatio
        self.swipeTravel = swipeTravel
        self.createdAt = createdAt
        self.references = references
    }
}

/// One thing the calibration asks the user to do.
public struct CalibrationStep: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Hold a built-in pose out towards the camera.
        case pose(Pose)
        /// Rest a hand against the face, which is where a hand must not be read as a pose.
        case handAtFace
        /// Make one of the swipes a few times.
        case swipe(Trigger)
    }

    public var kind: Kind
    /// Which hand is asked for; nil when either will do.
    public var hand: Handedness?

    public init(kind: Kind, hand: Handedness? = nil) {
        self.kind = kind
        self.hand = hand
    }

    public var id: String {
        let name = switch kind {
        case .pose(let pose): "pose." + Trigger(pose: pose).key
        case .handAtFace: "handAtFace"
        case .swipe(let trigger): "swipe." + trigger.key
        }
        return hand.map { "\(name).\($0.rawValue)" } ?? name
    }

    /// What to call the step, e.g. "Open palm, right hand".
    public var title: String {
        let name = switch kind {
        case .pose(let pose): Trigger(pose: pose).title
        case .handAtFace: "Hand at your face"
        case .swipe(let trigger): trigger.title
        }
        return hand.map { "\(name), \($0.rawValue) hand" } ?? name
    }

    /// One sentence telling the user what to do.
    public var instruction: String {
        let hand = hand.map { "\($0.rawValue) hand" } ?? "hand"
        switch kind {
        case .pose(let pose):
            switch pose {
            case .openPalm: return "Hold your open \(hand) out towards the camera, palm first, and keep it still."
            case .backOfHand: return "Hold your open \(hand) out towards the camera, back first, and keep it still."
            case .fist: return "Close your \(hand) into a fist, hold it out towards the camera and keep it still."
            case .ok:
                return "Touch the tips of the thumb and index finger of your \(hand), the other fingers up, "
                    + "and keep it still."
            case .one: return "Hold up the index finger of your \(hand), the other fingers closed, and keep it still."
            case .two:
                return "Hold up the index and middle fingers of your \(hand), the other fingers closed, and keep it still."
            case .three:
                return "Hold up the index, middle and ring fingers of your \(hand), the little finger closed, "
                    + "and keep it still."
            case .four: return "Hold up four fingers of your \(hand) with the thumb folded in, and keep it still."
            case .thumbsUp: return "Make a fist with your \(hand), point the thumb straight up and keep it still."
            case .custom: return "Make the gesture the way you recorded it with your \(hand) and keep it still."
            }
        case .handAtFace:
            return "Rest your chin on your \(hand) or touch your cheek with it, the way you do without thinking, "
                + "and stay like that."
        case .swipe(let trigger):
            let way = switch trigger {
            case .swipeLeft: "to your left"
            case .swipeRight: "to your right"
            default: "upwards"
            }
            let times = CalibrationPlan.swipesPerStep
            return "With your \(hand) open, flick it \(way) from the wrist \(times) times, "
                + "bringing it back slowly each time."
        }
    }
}

/// The guided session: every built-in pose with each hand, a hand at the face, then the swipes.
public enum CalibrationPlan {
    /// How many times each swipe is asked for. Three of each gives nine swipes to fit the travel on.
    public static let swipesPerStep = 3

    /// The poses in the order they are asked for: the open hand first, because it is what
    /// every finger's extended reach is measured on.
    private static let poses: [Pose] = [.openPalm, .backOfHand, .fist, .one, .two, .three, .four, .thumbsUp, .ok]

    public static let steps: [CalibrationStep] =
        poses.flatMap { pose in
            [Handedness.right, .left].map { CalibrationStep(kind: .pose(pose), hand: $0) }
        }
        + [CalibrationStep(kind: .handAtFace)]
        + [Trigger.swipeLeft, .swipeRight, .swipeUp].map { CalibrationStep(kind: .swipe($0)) }
}

/// What was captured for one step. Several samples of the same step are pooled.
public struct CalibrationSample: Sendable {
    public var step: CalibrationStep
    /// Steady frames of the hand (pose and hand-at-face steps).
    public var hands: [Hand]
    /// Palm size over face height on those frames, for the ones on which a face was known.
    public var palmToFace: [Double]
    /// Swipe steps: the peak fingertip travel of each swipe made, in palm sizes
    /// (see `SwipeMeasure`).
    public var swipePeaks: [Double]

    public init(step: CalibrationStep, hands: [Hand] = [], palmToFace: [Double] = [], swipePeaks: [Double] = []) {
        self.step = step
        self.hands = hands
        self.palmToFace = palmToFace
        self.swipePeaks = swipePeaks
    }
}

/// What a calibration changed, to show the user at the end of the session.
public struct CalibrationReport: Equatable, Sendable {
    /// How well one pose step is read.
    public struct Line: Equatable, Sendable {
        public var step: CalibrationStep
        /// Share (0...1) of the step's frames read as the asked pose with the factory values.
        public var before: Double
        /// The same share with the values the calibration ends up with.
        public var after: Double

        public init(step: CalibrationStep, before: Double, after: Double) {
            self.step = step
            self.before = before
            self.after = after
        }
    }

    /// One line per pose step that was captured, in the order the steps were given.
    public var lines: [Line]
    /// Plain sentences about what could not be fitted and stayed at its factory value.
    public var notes: [String]

    public init(lines: [Line] = [], notes: [String] = []) {
        self.lines = lines
        self.notes = notes
    }
}

/// Fits the thresholds hand shapes, depth and swipes are judged by to what one person showed
/// in a guided session.
///
/// Every threshold separates two things the person did on request: a finger curled and the
/// same finger extended, a hand held out and a hand at the face. Each is put in the room
/// between the two groups of measurements, nearer to neither than it has to be, and only when
/// there is clear room; where the groups touch, the factory value stays and a note says so.
public enum Calibrator {
    /// Share of a group's measurements (0...1) left out at the end that faces the other group
    /// when fitting fingers, thumb and pinch: the odd blurred frame must not set a threshold.
    static let shapeTail = 0.05
    /// The same share for palm-to-face ratios, which are noisier: the face box changes size
    /// as the hand covers part of the face.
    static let depthTail = 0.10
    /// Smallest room between two groups for them to count as separable. In palm sizes for
    /// fingers, thumb and pinch, in face heights for depth.
    static let minimumGap = 0.1
    /// Share of the room (0...1) left between a group and its threshold for fingers, thumb and
    /// pinch. The middle 30 % of the room stays "unclear", as a half-bent finger should.
    static let shapeMargin = 0.35
    /// Share of the room (0...1) left between a group of palm-to-face ratios and its threshold.
    static let depthMargin = 0.25
    /// Reach, in palm sizes, a fitted `curledReach` may take.
    static let curledReachRange = 0.15...0.45
    /// Reach, in palm sizes, a fitted `extendedReach` may take.
    static let extendedReachRange = 0.35...0.8
    /// Offset along the knuckle line, in palm sizes, a fitted `thumbInOffset` may take.
    static let thumbInRange = -0.1...0.2
    /// Offset along the knuckle line, in palm sizes, a fitted `thumbOutOffset` may take.
    static let thumbOutRange = 0.15...0.5
    /// Smallest distance, in palm sizes, kept between a fitted curled and extended threshold.
    static let minimumBand = 0.1
    /// Distance between thumb and index tips, in palm sizes, a fitted `pinchDistance` may take.
    static let pinchRange = 0.2...0.5
    /// Palm size, in face heights, a fitted `presentRatio` or `withdrawRatio` may take.
    static let depthRange = 0.5...1.5
    /// Smallest difference, in face heights, kept between `withdrawRatio` and `presentRatio`,
    /// so a hand near the boundary does not flicker between the two.
    static let minimumDepthBand = 0.05
    /// Fewest swipes the travel is fitted on.
    static let minimumSwipes = 4
    /// Share of the person's swipes (0...1) that may be weaker than the reference swipe the
    /// travel is set from.
    static let swipeReferenceShare = 0.2
    /// The travel asked for, as a share of the reference swipe (ratio), so a swipe a little
    /// weaker than those made in the session still counts. Not lower: a brisk way back comes
    /// close to a swipe. On the recorded swipes (reference 2.56 palm sizes, ways back up to
    /// 2.17) a share of 0.8 gives 2.05, at which one way back of that recording is read as a
    /// swipe; the recording is read right from 2.08 to 2.3.
    static let swipeTravelShare = 0.85
    /// Fingertip travel, in palm sizes, a fitted `swipeTravel` may take. Below it a hand merely
    /// turning would swipe; above it a swipe takes an effort.
    static let swipeTravelRange = 1.6...2.8
    /// How many hands of one pose step are kept as references.
    static let referencesPerStep = 6

    /// Fits what there is: steps that were skipped leave their values at factory, with a note.
    public static func calibrate(
        _ samples: [CalibrationSample], now: Date = Date()
    ) -> (calibration: PersonalCalibration, report: CalibrationReport) {
        let captures = poseCaptures(in: samples)
        var notes: [String] = []
        var fitted = PoseProfile.factory

        for finger in Finger.allCases where finger != .thumb {
            let curled = captures.flatMap { $0.values(for: finger, in: .curled) { $0.reach[finger.rawValue] } }
            let extended = captures.flatMap { $0.values(for: finger, in: .extended) { $0.reach[finger.rawValue] } }
            switch band(below: curled, above: extended, lowRange: curledReachRange, highRange: extendedReachRange) {
            case .fitted(let low, let high):
                fitted.curledReach[finger.rawValue] = low
                fitted.extendedReach[finger.rawValue] = high
            case .overlapping:
                notes.append("\(name(of: finger)): curled and extended overlap; kept the standard value")
            case .missing:
                notes.append("\(name(of: finger)): not captured both curled and extended; kept the standard value")
            }
        }

        let thumbIn = captures.flatMap { $0.values(for: .thumb, in: .curled, \.thumbOutwards) }
        let thumbOut = captures.flatMap { $0.values(for: .thumb, in: .extended, \.thumbOutwards) }
        switch band(below: thumbIn, above: thumbOut, lowRange: thumbInRange, highRange: thumbOutRange) {
        case .fitted(let low, let high):
            fitted.thumbInOffset = low
            fitted.thumbOutOffset = high
        case .overlapping:
            notes.append("\(name(of: .thumb)): folded in and held out overlap; kept the standard value")
        case .missing:
            notes.append("\(name(of: .thumb)): not captured both folded in and held out; kept the standard value")
        }

        // The back of the hand is an open palm to the pinch rule, so it counts as apart too.
        let touching = captures.filter { $0.pose == .ok }.flatMap { $0.measured.compactMap(\.pinch) }
        let apart = captures.filter { $0.pose == .openPalm || $0.pose == .backOfHand }
            .flatMap { $0.measured.compactMap(\.pinch) }
        switch room(above: touching, below: apart, tail: shapeTail) {
        case .clear(let from, let to):
            fitted.pinchDistance = clamp(from + shapeMargin * (to - from), to: pinchRange)
        case .overlapping:
            notes.append("OK sign: touching and open fingertips overlap; kept the standard value")
        case .missing:
            notes.append("OK sign: not captured together with an open hand; kept the standard value")
        }

        // The guard: thresholds that sit between the groups can still read whole poses worse,
        // because a pose needs every finger right at once.
        let factoryRates = captures.map { $0.readRate(with: .factory) }
        var rates = captures.map { $0.readRate(with: fitted) }
        if mean(rates) < mean(factoryRates) {
            fitted = .factory
            rates = factoryRates
            notes.append(
                "Your poses read better with the standard values than with the fitted ones; kept the standard values"
            )
        }
        let lines = captures.indices.map {
            CalibrationReport.Line(step: captures[$0].step, before: factoryRates[$0], after: rates[$0])
        }

        var calibration = PersonalCalibration(profile: fitted, createdAt: now)
        for capture in captures {
            let key = Trigger(pose: capture.pose).key
            calibration.references[key, default: []] += evenlySpaced(capture.hands, count: referencesPerStep)
        }

        let heldOut = samples.filter { $0.step.kind.isPose }.flatMap(\.palmToFace)
        let atFace = samples.filter { $0.step.kind == .handAtFace }.flatMap(\.palmToFace)
        switch depth(atFace: atFace, heldOut: heldOut) {
        case .fitted(let withdraw, let present):
            calibration.withdrawRatio = withdraw
            calibration.presentRatio = present
        case .overlapping:
            notes.append("Hand at your face: it looks as large as your hand held out; kept the standard distances")
        case .missing:
            notes.append("Hand at your face: not captured with your face in view; kept the standard distances")
        }

        let peaks = samples.filter { $0.step.kind.isSwipe }.flatMap(\.swipePeaks)
        if let travel = swipeTravel(peaks: peaks) {
            calibration.swipeTravel = travel
        } else {
            notes.append("Swipes: fewer than \(minimumSwipes) captured; kept the standard value")
        }

        return (calibration, CalibrationReport(lines: lines, notes: notes))
    }

    // MARK: Fitting

    /// How two groups of measurements of the same thing lie to each other.
    enum Room: Equatable {
        /// The lower group ends at `from` and the upper one begins at `to`, at least
        /// `minimumGap` farther up.
        case clear(from: Double, to: Double)
        case overlapping
        /// One of the groups is empty.
        case missing
    }

    /// A pair of thresholds fitted between two groups of measurements.
    enum Band: Equatable {
        case fitted(low: Double, high: Double)
        case overlapping
        case missing
    }

    /// Where the room between a lower and an upper group of measurements is, leaving out
    /// `tail` (0...1) of each group at the end that faces the other.
    static func room(above lower: [Double], below upper: [Double], tail: Double) -> Room {
        guard !lower.isEmpty, !upper.isEmpty else { return .missing }
        let from = percentile(lower, 1 - tail)
        let to = percentile(upper, tail)
        // The same allowance the engine makes for sums of floating-point numbers.
        return to - from >= minimumGap - 1e-9 ? .clear(from: from, to: to) : .overlapping
    }

    /// The thresholds for "curled" (`low`: up to it) and "extended" (`high`: from it) between
    /// the measurements of fingers shown curled and shown extended, each kept within its range
    /// and at least `minimumBand` apart.
    static func band(
        below curled: [Double], above extended: [Double], lowRange: ClosedRange<Double>, highRange: ClosedRange<Double>
    ) -> Band {
        switch room(above: curled, below: extended, tail: shapeTail) {
        case .missing: return .missing
        case .overlapping: return .overlapping
        case .clear(let from, let to):
            var low = clamp(from + shapeMargin * (to - from), to: lowRange)
            var high = clamp(to - shapeMargin * (to - from), to: highRange)
            if high - low < minimumBand {
                // Both ranges contain the stretch this lands in, so no clamp is undone.
                let middle = (low + high) / 2
                low = middle - minimumBand / 2
                high = middle + minimumBand / 2
            }
            return .fitted(low: low, high: high)
        }
    }

    /// `withdrawRatio` (`low`) and `presentRatio` (`high`) between the palm-to-face ratios of a
    /// hand at the face and of hands held out.
    static func depth(atFace: [Double], heldOut: [Double]) -> Band {
        switch room(above: atFace, below: heldOut, tail: depthTail) {
        case .missing: return .missing
        case .overlapping: return .overlapping
        case .clear(let from, let to):
            var withdraw = clamp(from + depthMargin * (to - from), to: depthRange)
            var present = clamp(to - depthMargin * (to - from), to: depthRange)
            if withdraw > present - minimumDepthBand {
                if present - minimumDepthBand >= depthRange.lowerBound {
                    withdraw = present - minimumDepthBand
                } else {
                    present = withdraw + minimumDepthBand
                }
            }
            return .fitted(low: withdraw, high: present)
        }
    }

    /// The fingertip travel to ask of a swipe, in palm sizes, from the peaks of the swipes a
    /// person made; nil when there are too few to go by.
    static func swipeTravel(peaks: [Double]) -> Double? {
        guard peaks.count >= minimumSwipes else { return nil }
        return clamp(swipeTravelShare * percentile(peaks, swipeReferenceShare), to: swipeTravelRange)
    }

    /// The value below which `share` (0...1) of `values` lie, read between the two nearest
    /// ones. `values` must not be empty.
    static func percentile(_ values: [Double], _ share: Double) -> Double {
        precondition(!values.isEmpty, "A percentile needs at least one value")
        let sorted = values.sorted()
        let position = min(1, max(0, share)) * Double(sorted.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Up to `count` of `items`, spread over the whole run so they differ as much as the
    /// capture did.
    private static func evenlySpaced<Item>(_ items: [Item], count: Int) -> [Item] {
        guard items.count > count, count > 1 else { return Array(items.prefix(count)) }
        return (0..<count).map { items[$0 * (items.count - 1) / (count - 1)] }
    }

    private static func name(of finger: Finger) -> String {
        switch finger {
        case .thumb: "Thumb"
        case .index: "Index finger"
        case .middle: "Middle finger"
        case .ring: "Ring finger"
        case .little: "Little finger"
        }
    }

    // MARK: Captured poses

    /// Everything captured for one pose step, measured once.
    private struct CapturedPose {
        let step: CalibrationStep
        let pose: Pose
        var hands: [Hand]
        var measured: [HandMeasurements]

        /// One measurement per frame of `finger`, when this pose asks for it in `state`;
        /// nothing when the pose leaves the finger free or asks for the other state.
        func values(
            for finger: Finger, in state: FingerState, _ value: (HandMeasurements) -> Double?
        ) -> [Double] {
            PoseClassifier.fingers(in: pose)[finger] == state ? measured.compactMap(value) : []
        }

        /// Share (0...1) of the frames read as the asked pose with `profile`.
        func readRate(with profile: PoseProfile) -> Double {
            guard !hands.isEmpty else { return 0 }
            let read = zip(hands, measured).filter { hand, measured in
                PoseClassifier.classify(measured, handedness: hand.handedness, profile: profile) == pose
            }
            return Double(read.count) / Double(hands.count)
        }
    }

    /// The pose steps that have frames, in the order they first appear, samples of the same
    /// step pooled.
    private static func poseCaptures(in samples: [CalibrationSample]) -> [CapturedPose] {
        var captures: [CapturedPose] = []
        for sample in samples {
            guard case .pose(let pose) = sample.step.kind, !sample.hands.isEmpty else { continue }
            let measured = sample.hands.map(PoseClassifier.measure)
            if let known = captures.firstIndex(where: { $0.step == sample.step }) {
                captures[known].hands += sample.hands
                captures[known].measured += measured
            } else {
                captures.append(CapturedPose(step: sample.step, pose: pose, hands: sample.hands, measured: measured))
            }
        }
        return captures
    }
}

private extension CalibrationStep.Kind {
    var isPose: Bool {
        if case .pose = self { return true }
        return false
    }

    var isSwipe: Bool {
        if case .swipe = self { return true }
        return false
    }
}

/// Finds the swipes in a run of frames and how far the fingertips went in each.
///
/// Used while a swipe step of the calibration is being captured. The travel is measured the
/// way `GestureEngine` measures it when it decides on a swipe, so a peak found here is the
/// number `GestureConfig.swipeTravel` is compared with.
public enum SwipeMeasure {
    /// One flick of the hand.
    public struct Peak: Equatable, Sendable {
        /// When the travel was largest, in seconds on the frames' clock.
        public var time: Double
        /// The largest travel of the middle of the four fingertips within
        /// `GestureConfig.swipeWindow` during the flick, in palm sizes.
        public var travel: Double
        /// The swipe a flick this way is read as; nil when it went downwards or diagonally.
        public var direction: Trigger?

        public init(time: Double, travel: Double, direction: Trigger?) {
            self.time = time
            self.travel = travel
            self.direction = direction
        }
    }

    /// Fingertip travel within `swipeWindow`, in palm sizes, from which a movement is looked
    /// at. Well under any swipe (recorded ones start at 2.2), so that a person with a weaker
    /// flick is still measured.
    static let candidateTravel = 1.2
    /// Seconds a frame may be older than `swipeWindow` and still be compared with, so a frame
    /// that is nominally `swipeWindow` old is kept. The engine makes the same allowance.
    static let windowAllowance = 0.005
    /// Smallest distance, in palm sizes, a hand may always be from where it was a frame ago
    /// and still be the same hand; covers detector jitter. The engine uses the same floor.
    static let sameHandReach = 0.5

    /// Every flick in `frames`, in time order: stretches on which the fingertips of the
    /// largest usable hand travel at least `candidateTravel` within `config.swipeWindow` while
    /// the wrist travels `config.swipePivot` times less. Stretches going the same way less
    /// than `config.swipeGap` apart are one flick, as they are to the engine.
    ///
    /// A hand that swiped goes back, and the way back is a flick too: slower, the other way,
    /// and listed here like any other. The caller keeps, for a swipe step, only the peaks
    /// whose `direction` is the swipe that was asked for.
    public static func peaks(in frames: [HandFrame], config: GestureConfig = GestureConfig()) -> [Peak] {
        var stretches: [Stretch] = []
        var followed: Followed?
        for frame in frames {
            let now = frame.time
            let usable = frame.hands.filter {
                Double($0.confidence) >= config.minConfidence && $0.palmSize >= config.minPalmSize
            }
            guard let hand = usable.max(by: { $0.palmSize < $1.palmSize }) else { continue }

            var current = followed.flatMap { $0.isSame(hand, at: now, config: config) ? $0 : nil }
                ?? Followed(hand: hand, time: now)
            current.observe(hand, at: now, config: config)
            followed = current

            guard let latest = current.reaches.last, latest.time == now,
                  let earliest = current.reaches.first, earliest.time < now else { continue }
            let travel = (latest.tips - earliest.tips) * (1 / current.palmSize)
            let wristTravel = latest.wrist.distance(to: earliest.wrist) / current.palmSize
            guard travel.length >= candidateTravel, wristTravel * config.swipePivot <= travel.length else { continue }

            if var last = stretches.last, last.continues(with: travel, at: now, gap: config.swipeGap) {
                last.end = now
                if travel.length > last.travel.length {
                    last.travel = travel
                    last.peakTime = now
                }
                stretches[stretches.count - 1] = last
            } else {
                stretches.append(Stretch(end: now, peakTime: now, travel: travel))
            }
        }
        return stretches.map {
            Peak(
                time: $0.peakTime, travel: $0.travel.length,
                direction: direction(of: $0.travel, dominance: config.swipeDominance)
            )
        }
    }

    /// One flick while it is being followed.
    private struct Stretch {
        /// Time of its latest frame.
        var end: Double
        var peakTime: Double
        /// Fingertip travel at the peak, in palm sizes.
        var travel: Point2

        /// Whether a movement of `travel` at `now` is still this flick: soon enough after it
        /// and not turned back, which is what a way back following closely does.
        func continues(with travel: Point2, at now: Double, gap: Double) -> Bool {
            let sameWay = travel.x * self.travel.x + travel.y * self.travel.y > 0
            return sameWay && now >= end && now - end < gap
        }
    }

    /// The hand being measured, from frame to frame.
    private struct Followed {
        struct Reach {
            var time: Double
            /// Middle of the four fingertips.
            var tips: Point2
            var wrist: Point2
        }

        var center: Point2
        /// Palm size averaged over `palmSizeSmoothing`, as the engine's yardstick is.
        var palmSize: Double
        var lastSeen: Double
        /// Recent fingertip and wrist positions, oldest first, reaching back `swipeWindow`.
        var reaches: [Reach] = []

        init(hand: Hand, time: Double) {
            center = hand.palmCenter
            palmSize = hand.palmSize
            lastSeen = time
        }

        /// Whether `hand` can be this one a moment later, rather than another hand or the same
        /// one after it was lost or the clock restarted.
        func isSame(_ hand: Hand, at now: Double, config: GestureConfig) -> Bool {
            let elapsed = now - lastSeen
            guard elapsed >= 0, elapsed <= config.glitchTolerance else { return false }
            let reach = max(SwipeMeasure.sameHandReach, config.maxHandSpeed * elapsed) * palmSize
            return hand.palmCenter.distance(to: center) <= reach
        }

        mutating func observe(_ hand: Hand, at now: Double, config: GestureConfig) {
            let blend = config.palmSizeSmoothing > 0 ? min(1, (now - lastSeen) / config.palmSizeSmoothing) : 1
            palmSize += (hand.palmSize - palmSize) * blend
            center = hand.palmCenter
            lastSeen = now
            reaches.removeAll { now - $0.time > config.swipeWindow + SwipeMeasure.windowAllowance }
            let known = [Joint.indexTip, .middleTip, .ringTip, .littleTip].filter { hand.confidence(of: $0) > 0 }
            // With fewer, the middle would jump whenever a finger comes or goes.
            guard known.count >= 3 else { return }
            let tips = known.reduce(Point2.zero) { $0 + hand[$1] } * (1 / Double(known.count))
            reaches.append(Reach(time: now, tips: tips, wrist: hand[.wrist]))
        }
    }

    /// The swipe a displacement stands for, by the engine's rule: sideways or up only, and
    /// `dominance` times farther along that axis than across it.
    private static func direction(of travel: Point2, dominance: Double) -> Trigger? {
        let across = abs(travel.x)
        let along = abs(travel.y)
        if across >= dominance * along { return travel.x > 0 ? .swipeRight : .swipeLeft }
        if travel.y > 0, along >= dominance * across { return .swipeUp }
        return nil
    }
}
