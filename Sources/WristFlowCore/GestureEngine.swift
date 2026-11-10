import Foundation

/// Every number the gesture engine decides with. Distances are in palm sizes unless stated,
/// so they hold at any distance from the camera.
public struct GestureConfig: Codable, Equatable, Sendable {
    /// Seconds a pose has to be held still before it fires.
    public var holdTime = 0.4
    /// How far the palm centre may wander during a hold, in palm sizes, before the hold starts over.
    public var holdTravel = 0.2
    /// Seconds a wrong pose reading or a lost hand is forgiven; also the most a hold may contain of them in total.
    public var glitchTolerance = 0.15
    /// Mean joint confidence (0...1) a hand needs to be used at all.
    public var minConfidence = 0.5
    /// Smallest palm size, in image heights, that is used; smaller hands are too far away.
    public var minPalmSize = 0.06
    /// Fastest a hand is expected to move, in palm sizes per second; a hand seen farther than this allows is another hand.
    public var maxHandSpeed = 40.0
    /// Seconds the palm must stay within `restRadius` for the hand to count as at rest, which is when its pose can be trusted.
    public var restTime = 0.12
    /// How far the palm centre may drift, in palm sizes, and still count as resting.
    public var restRadius = 0.1
    /// How far the fingertips must travel within `swipeWindow`, in palm sizes, to make a swipe. Recorded swipes cover 2.2 to 3.9, the unhurried way back under 2.
    public var swipeTravel = 2.2
    /// Seconds within which `swipeTravel` must be covered: a swipe is a flick, not a turn.
    public var swipeWindow = 0.12
    /// How many times larger the travel along the swipe axis must be than across it (ratio).
    public var swipeDominance = 1.5
    /// How many times farther the fingertips must travel than the wrist (ratio): the hand has to pivot, not just be carried along.
    public var swipePivot = 1.4
    /// How far the fingertips must be from the wrist, in palm sizes, for the hand to count as open enough to swipe.
    public var swipeOpenness = 1.4
    /// Seconds a hand must have been in view before a movement of it can be a swipe.
    public var swipeSettle = 0.25
    /// Seconds after a swipe, or after the hand has gone back, during which no other swipe is read.
    public var swipeGap = 0.25
    /// Seconds after a swipe during which a flick the opposite way is taken for the hand going back, unless the hand has gone back before that.
    public var returnWindow = 3.0
    /// How near the fingertips must come to where they were before the swipe, in palm sizes, for the hand to count as having gone back.
    public var returnReach = 0.7
    /// Seconds over which the measured palm size is averaged, so a blurred frame cannot change the yardstick.
    public var palmSizeSmoothing = 0.25
    /// Palm size, in face heights, from which a hand counts as held out towards the camera. A hand held out is nearer the camera than the face, so it looks large next to it.
    public var presentRatio = 1.0
    /// Palm size, in face heights, below which a hand counts as back by the head: touching the face, propping up the chin, resting beside it.
    public var withdrawRatio = 0.9
    /// Seconds the last seen face is remembered; a hand at the face can hide it from the detector.
    public var faceMemory = 3.0
    /// Extra seconds a pose that is also half of a combination has to be held before it fires
    /// on its own, so the other hand has time to come up.
    public var comboGrace = 0.25
    /// Seconds after a second hand comes into view during which a pose that is half of a
    /// combination does not fire on its own: the second hand is still getting into its pose.
    public var comboSettle = 0.6

    public init() {}

    // Decoded by hand so a file written before a tunable existed still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try values.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        let defaults = GestureConfig()
        holdTime = try value(.holdTime, defaults.holdTime)
        holdTravel = try value(.holdTravel, defaults.holdTravel)
        glitchTolerance = try value(.glitchTolerance, defaults.glitchTolerance)
        minConfidence = try value(.minConfidence, defaults.minConfidence)
        minPalmSize = try value(.minPalmSize, defaults.minPalmSize)
        maxHandSpeed = try value(.maxHandSpeed, defaults.maxHandSpeed)
        restTime = try value(.restTime, defaults.restTime)
        restRadius = try value(.restRadius, defaults.restRadius)
        swipeTravel = try value(.swipeTravel, defaults.swipeTravel)
        swipeWindow = try value(.swipeWindow, defaults.swipeWindow)
        swipeDominance = try value(.swipeDominance, defaults.swipeDominance)
        swipePivot = try value(.swipePivot, defaults.swipePivot)
        swipeOpenness = try value(.swipeOpenness, defaults.swipeOpenness)
        swipeSettle = try value(.swipeSettle, defaults.swipeSettle)
        swipeGap = try value(.swipeGap, defaults.swipeGap)
        returnWindow = try value(.returnWindow, defaults.returnWindow)
        returnReach = try value(.returnReach, defaults.returnReach)
        palmSizeSmoothing = try value(.palmSizeSmoothing, defaults.palmSizeSmoothing)
        presentRatio = try value(.presentRatio, defaults.presentRatio)
        withdrawRatio = try value(.withdrawRatio, defaults.withdrawRatio)
        faceMemory = try value(.faceMemory, defaults.faceMemory)
        comboGrace = try value(.comboGrace, defaults.comboGrace)
        comboSettle = try value(.comboSettle, defaults.comboSettle)
    }
}

/// What the engine currently makes of the camera, for the live preview.
public struct GestureState: Equatable, Sendable {
    /// A usable hand is being tracked.
    public var handVisible: Bool
    /// Pose read on it in the latest frame.
    public var pose: Pose?
    /// 0...1 towards firing the pose; stays at 1 once it fired, and at 0 when a swipe took its place.
    public var holdProgress: Double
    /// The hand is open and has been in view long enough, so a flick of it now is a swipe.
    public var armedForSwipe: Bool
    /// The hand is back by the head rather than held out towards the camera, so its shape is
    /// not read as a pose.
    public var withdrawn: Bool
    /// A second usable hand is in view. Only its pose is read, for combinations.
    public var otherHandVisible: Bool
    /// Pose read on the second hand in the latest frame.
    public var otherPose: Pose?
    /// Id of the combination the two hands are showing; `holdProgress` then counts towards it.
    public var combination: String?

    public init(
        handVisible: Bool = false, pose: Pose? = nil, holdProgress: Double = 0, armedForSwipe: Bool = false,
        withdrawn: Bool = false, otherHandVisible: Bool = false, otherPose: Pose? = nil, combination: String? = nil
    ) {
        self.handVisible = handVisible
        self.pose = pose
        self.holdProgress = holdProgress
        self.armedForSwipe = armedForSwipe
        self.withdrawn = withdrawn
        self.otherHandVisible = otherHandVisible
        self.otherPose = otherPose
        self.combination = combination
    }
}

/// Turns a stream of hand frames into triggers: poses held still, swipes of the open hand,
/// and two hands each holding a pose at the same time.
///
/// One hand is followed for gestures of its own. A second hand in view is followed only for
/// its pose, which matters when the two together make a combination the user set up.
///
/// A swipe is a flick: the fingertips sweeping sideways or upwards in about a tenth of a second
/// while the wrist stays roughly where it is. That is how people swipe at a screen in practice,
/// and its speed is what tells it from the slower way back and from a hand merely moving.
///
/// All timing comes from `HandFrame.time`, so the frame rate may vary and frames may be missing.
public struct GestureEngine: Sendable {
    public var config: GestureConfig
    /// What the user taught: recorded gestures, combinations and their calibration.
    public var library = GestureLibrary()
    public private(set) var state = GestureState()

    private var track: Track?
    /// The other hand in view, whose pose can complete a combination.
    private var second: Track?
    /// Where the usable hands other than the main one were in the latest frame.
    private var bystanders: [Point2] = []
    /// The face as last reported, to tell a hand back by the head from one held out in a pose.
    private var face: FaceFrame?

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    /// Forgets the hand being followed, as if the camera had just started.
    public mutating func reset() {
        track = nil
        second = nil
        bystanders = []
        face = nil
        state = GestureState()
    }

    /// Tells the engine where the user's face is. Without it every hand is read as a gesture.
    public mutating func ingest(_ face: FaceFrame) {
        self.face = face
    }

    public mutating func ingest(_ frame: HandFrame) -> Trigger? {
        let now = frame.time
        // A clock that runs backwards means a new camera session; stored times mean nothing.
        if let track, now < track.lastSeen { reset() }

        let usable = frame.hands.filter(isUsable)
        var seen: Int?
        if let followed = track {
            seen = index(of: followed, among: usable, at: now)
            if seen == nil, now - followed.lastSeen > config.glitchTolerance { track = nil }
        }
        if track == nil, let largest = usable.indices.max(by: { usable[$0].palmSize < usable[$1].palmSize }) {
            track = Track(hand: usable[largest], time: now)
            seen = largest
        }
        bystanders = usable.indices.filter { $0 != seen }.map { usable[$0].palmCenter }

        guard var followed = track else {
            second = nil
            state = GestureState()
            return nil
        }
        let otherReading = followSecond(among: usable, apart: seen, at: now)
        // A dropout short enough to keep the appearance leaves everything as it was.
        guard let seen else { return nil }

        let reading = observe(&followed, as: usable[seen], at: now)
        let pairing = pairing(of: followed, with: second, at: now)

        var trigger: Trigger?
        if let pairing, reading == followed.hold?.pose, otherReading == second?.hold?.pose,
           // Holding one hand and showing the other again makes the combination again.
           !(followed.hold?.combined == true && second?.hold?.combined == true),
           reached(now - pairing.since, config.holdTime) {
            followed.completeCombination()
            second?.completeCombination()
            trigger = pairing.combination.trigger
        }
        // A pose that is also half of a combination gives the other hand time to come up.
        let combined = followed.hold.map { library.isCombined($0.pose) } ?? false
        let needed = config.holdTime + (combined ? config.comboGrace : 0)
        if trigger == nil, !(combined && (pairing != nil || isSecondArriving(at: now))) {
            trigger = followed.completeHold(reading, at: now, holdTime: needed).map(Trigger.init(pose:))
        }
        let swipe = followed.followSwipe(at: now, config: config)
        trigger = trigger ?? swipe

        var progress = followed.holdProgress(at: now, holdTime: needed)
        if let pairing {
            let done = (followed.hold?.combined == true && second?.hold?.combined == true) || config.holdTime <= 0
            progress = done ? 1 : min(1, max(0, (now - pairing.since) / config.holdTime))
        }
        state = GestureState(
            handVisible: true,
            pose: reading,
            holdProgress: progress,
            armedForSwipe: followed.canSwipe(at: now, config: config),
            withdrawn: followed.withdrawn,
            otherHandVisible: second?.lastSeen == now,
            otherPose: otherReading,
            combination: pairing?.combination.id
        )
        track = followed
        return trigger
    }

    /// Takes in one frame of a followed hand and returns the pose read on it.
    private func observe(_ followed: inout Track, as hand: Hand, at now: Double) -> Pose? {
        let elapsed = now - followed.lastSeen
        followed.observe(hand, at: now, config: config)
        // A hand back by the head is biting a nail, propping up a chin or scratching, and
        // takes the shape of a fist or an open palm while doing it. Swipes are left alone:
        // nothing done there looks like a flick.
        followed.withdrawn = isWithdrawn(palmSize: followed.palmSize, was: followed.withdrawn, at: now)
        let reading = followed.withdrawn ? nil : read(hand)
        let rested = followed.restDuration(radius: config.restRadius * followed.palmSize)
        followed.followPose(
            reading, trusted: reached(rested, config.restTime), at: now, elapsed: elapsed, config: config
        )
        return reading
    }

    /// Keeps up with the hand that is not the main one, and returns the pose read on it.
    private mutating func followSecond(among hands: [Hand], apart main: Int?, at now: Double) -> Pose? {
        let others = hands.indices.filter { $0 != main }
        var seen: Int?
        if let other = second {
            let reach = max(0.5, config.maxHandSpeed * (now - other.lastSeen)) * other.palmSize
            seen = others
                .filter { hands[$0].palmCenter.distance(to: other.center) <= reach }
                .min { hands[$0].palmCenter.distance(to: other.center) < hands[$1].palmCenter.distance(to: other.center) }
            if seen == nil, now - other.lastSeen > config.glitchTolerance { second = nil }
        }
        if second == nil, let largest = others.max(by: { hands[$0].palmSize < hands[$1].palmSize }) {
            second = Track(hand: hands[largest], time: now)
            seen = largest
        }
        guard let seen, var other = second else { return nil }
        let reading = observe(&other, as: hands[seen], at: now)
        second = other
        return reading
    }

    /// The combination the two hands are holding, and since when both have held their part
    /// of it still.
    private func pairing(of main: Track, with other: Track?, at now: Double) -> (combination: Combination, since: Double)? {
        guard !library.combinations.isEmpty, let other, other.lastSeen == now,
              let mine = main.hold, let theirs = other.hold else { return nil }
        // The detector says which hand is which. When it gives both the same name, or none,
        // their places do: the user's left hand is the one on their left.
        let mainIsLeft: Bool
        if let side = main.handedness, let otherSide = other.handedness, side != otherSide {
            mainIsLeft = side == .left
        } else {
            mainIsLeft = main.center.x < other.center.x
        }
        let left = mainIsLeft ? mine.pose : theirs.pose
        let right = mainIsLeft ? theirs.pose : mine.pose
        guard let combination = library.combination(left: left, right: right) else { return nil }
        return (combination, max(mine.since, theirs.since))
    }

    /// Whether a second hand has only just come into view and may still be getting into a pose.
    private func isSecondArriving(at now: Double) -> Bool {
        guard let other = second, other.lastSeen == now, !other.withdrawn else { return false }
        return now - other.appeared < config.comboSettle
    }

    /// Whether the hand is back at about the face's distance from the camera instead of held
    /// out in front of it.
    ///
    /// Gestures are made towards the camera, which puts the hand nearer to it than the face,
    /// so the palm looks large next to the face: 1.0 to 1.3 face heights in recordings, against
    /// 0.6 to 0.95 for a hand touching the face. Where the hand is in the image says less:
    /// people hold gestures up right in front of their face. The two thresholds keep a hand
    /// near the boundary from flickering between the two.
    private func isWithdrawn(palmSize: Double, was: Bool, at now: Double) -> Bool {
        guard let face, face.size > 0, abs(now - face.time) <= config.faceMemory else { return false }
        let ratio = palmSize / face.size
        if ratio >= config.presentRatio { return false }
        if ratio <= config.withdrawRatio { return true }
        return was
    }

    /// The pose a hand shows: a shape the user recorded when it looks like one, otherwise
    /// one of the built-in poses.
    private func read(_ hand: Hand) -> Pose? {
        PoseClassifier.classify(hand, profile: library.profile)
    }

    private func isUsable(_ hand: Hand) -> Bool {
        Double(hand.confidence) >= config.minConfidence && hand.palmSize >= config.minPalmSize
    }

    /// The hand in `hands` that is the one being followed, if it is there.
    private func index(of followed: Track, among hands: [Hand], at now: Double) -> Int? {
        // The floor covers detector jitter and frames that share a time stamp.
        let reach = max(0.5, config.maxHandSpeed * (now - followed.lastSeen)) * followed.palmSize
        var best: (index: Int, distance: Double)?
        for (index, hand) in hands.enumerated() {
            let center = hand.palmCenter
            let distance = center.distance(to: followed.center)
            guard distance <= reach else { continue }
            // A hand that sits where another hand was a frame ago is that other hand. Without
            // this, losing the followed hand while a second one is in view would read as the
            // followed hand jumping across the frame, which looks exactly like a swipe.
            if bystanders.contains(where: { $0.distance(to: center) < distance }) { continue }
            if let nearest = best, nearest.distance <= distance { continue }
            best = (index, distance)
        }
        return best?.index
    }
}

private extension Pose {
    /// The poses a swiping hand passes through and ends in.
    var isOpenHand: Bool { self == .openPalm || self == .backOfHand || self == .four }
}

/// Frame times are sums of floating-point intervals, so "0.4 s later" can arrive as 0.3999….
private func reached(_ elapsed: Double, _ needed: Double) -> Bool {
    elapsed >= needed - 1e-9
}

/// One appearance of a hand, from the first usable frame until it is lost for too long.
private struct Track: Sendable {
    struct Sample: Sendable {
        var time: Double
        var center: Point2
    }

    /// A pose being held, from its first reading until the hand shows something else.
    struct Hold: Sendable {
        var pose: Pose
        /// When the current still stretch of this pose began.
        var since: Double
        /// Last time a reading did not contradict the pose.
        var lastAgreed: Double
        /// Corners of the box the palm centre has stayed in since `since`.
        var low: Point2
        var high: Point2
        /// Seconds since `since` on which the reading was something else.
        var doubted = 0.0
        /// Its trigger has been emitted, or it was used up as half of a combination.
        var fired = false
        /// It was half of a combination that fired.
        var combined = false
    }

    /// Where the hand's ends were on one frame; a swipe is read from how these move.
    struct Reach: Sendable {
        var time: Double
        /// Middle of the four fingertips.
        var tips: Point2
        var wrist: Point2
    }

    var center: Point2
    var palmSize: Double
    var lastSeen: Double
    /// Which of the user's hands this is, as last reported by the detector.
    var handedness: Handedness?
    /// Recent palm centres, oldest first, reaching back just past the longest rest that is asked for.
    var path: [Sample] = []
    var hold: Hold?
    /// A different pose that has started to show while `hold` is still being forgiven.
    var challenger: (pose: Pose, since: Double)?
    /// When this appearance began.
    let appeared: Double
    /// Recent fingertip and wrist positions, oldest first, reaching back `swipeWindow`.
    var reaches: [Reach] = []
    /// A swipe whose way back has not been seen yet.
    struct PendingReturn: Sendable {
        var trigger: Trigger
        /// Where the fingertips were from the wrist before the swipe, in palm sizes.
        var origin: Point2
        var since: Double
        /// When the fingertips came back to `origin`.
        var backAt: Double?
    }

    var pendingReturn: PendingReturn?
    /// No swipe is read before this time: the movement just judged is still going on.
    var quietUntil = -Double.infinity
    /// A swipe was made in this appearance, which uses up its open hand: the hand that swiped
    /// is still open afterwards, whichever side it ends up showing, and must not also count as
    /// a palm or a back being shown.
    var palmSpent = false
    /// The hand is back by the head; see `GestureEngine.isWithdrawn`.
    var withdrawn = false

    init(hand: Hand, time: Double) {
        center = hand.palmCenter
        palmSize = hand.palmSize
        lastSeen = time
        appeared = time
        handedness = hand.handedness
    }

    mutating func observe(_ hand: Hand, at now: Double, config: GestureConfig) {
        let blend = config.palmSizeSmoothing > 0 ? min(1, (now - lastSeen) / config.palmSizeSmoothing) : 1
        palmSize += (hand.palmSize - palmSize) * blend
        center = hand.palmCenter
        lastSeen = now
        handedness = hand.handedness ?? handedness
        path.append(Sample(time: now, center: center))
        // Keep one sample at or beyond the horizon, so a rest of exactly that length can be seen.
        let horizon = now - config.restTime
        while path.count > 1, path[1].time <= horizon { path.removeFirst() }

        // The small allowance keeps a frame that is nominally `swipeWindow` old.
        reaches.removeAll { now - $0.time > config.swipeWindow + 0.005 }
        if let tips = Self.fingertips(of: hand) {
            reaches.append(Reach(time: now, tips: tips, wrist: hand[.wrist]))
        }
    }

    /// Middle of the four fingertips, or nil when too few of them are known. Fingertips are
    /// what a flick moves most, far more than the palm.
    private static func fingertips(of hand: Hand) -> Point2? {
        let known = [Joint.indexTip, .middleTip, .ringTip, .littleTip].filter { hand.confidence(of: $0) > 0 }
        // With fewer, the middle would jump whenever a finger comes or goes.
        guard known.count >= 3 else { return nil }
        return known.reduce(Point2.zero) { $0 + hand[$1] } * (1 / Double(known.count))
    }

    /// Seconds the palm centre has stayed within `radius` (image heights) of where it is now.
    func restDuration(radius: Double) -> Double {
        guard let newest = path.last else { return 0 }
        var since = newest.time
        for sample in path.reversed() {
            guard sample.center.distance(to: newest.center) <= radius else { break }
            since = sample.time
        }
        return newest.time - since
    }

    /// Starts the still stretch of the current hold over, keeping whether it was used.
    mutating func restartHold(at now: Double) {
        guard var current = hold else { return }
        current.since = now
        current.low = center
        current.high = center
        current.doubted = 0
        hold = current
    }

    /// Keeps `hold` in step with the pose read on this frame, `elapsed` seconds after the last one.
    mutating func followPose(_ reading: Pose?, trusted: Bool, at now: Double, elapsed: Double, config: GestureConfig) {
        if var current = hold {
            // Motion blur garbles the pose of a moving hand. That must not end a hold that has
            // already been used, or the same pose would fire again where the hand stops.
            let shielded = !trusted && current.fired
            if reading == current.pose {
                current.lastAgreed = now
                challenger = nil
            } else if shielded {
                current.lastAgreed = now
            } else {
                current.doubted += elapsed
                if let reading, challenger?.pose != reading { challenger = (reading, now) }
            }
            hold = now - current.lastAgreed > config.glitchTolerance ? nil : current
        }

        guard var current = hold else {
            if let reading {
                // The new pose has been showing since it first challenged the old one.
                let since = challenger?.pose == reading ? challenger?.since : nil
                hold = Hold(pose: reading, since: since ?? now, lastAgreed: now, low: center, high: center)
            }
            challenger = nil
            return
        }
        current.low = Point2(x: min(current.low.x, center.x), y: min(current.low.y, center.y))
        current.high = Point2(x: max(current.high.x, center.x), y: max(current.high.y, center.y))
        hold = current
        // The box, not the distance from the start: a hand shaking around one spot never gets
        // far from it, yet is not being held still. Nor is a pose that keeps flickering, even
        // if each flicker on its own is short enough to forgive.
        let wandered = (current.high - current.low).length > config.holdTravel * palmSize
        if wandered || current.doubted > config.glitchTolerance + 1e-9 { restartHold(at: now) }
    }

    /// Marks the pose being held as used up by a combination, so it does not also fire alone.
    mutating func completeCombination() {
        hold?.fired = true
        hold?.combined = true
        palmSpent = false
    }

    /// The pose whose hold completes on this frame, if any.
    mutating func completeHold(_ reading: Pose?, at now: Double, holdTime: Double) -> Pose? {
        guard var current = hold, !current.fired, reading == current.pose,
              !(current.pose.isOpenHand && palmSpent),
              reached(now - current.since, holdTime) else { return nil }
        current.fired = true
        hold = current
        // Deliberately showing another pose ends the swiping; the palm means palm again.
        palmSpent = false
        return current.pose
    }

    func holdProgress(at now: Double, holdTime: Double) -> Double {
        guard let hold, !(hold.pose.isOpenHand && palmSpent) else { return 0 }
        if hold.fired || holdTime <= 0 { return 1 }
        return min(1, max(0, (now - hold.since) / holdTime))
    }

    /// Whether a flick made now could count: the hand has settled into view, is open, and has
    /// not already been used for a held pose.
    func canSwipe(at now: Double, config: GestureConfig) -> Bool {
        guard hold?.fired != true, reached(now - appeared, config.swipeSettle), let latest = reaches.last else { return false }
        return latest.tips.distance(to: latest.wrist) >= config.swipeOpenness * palmSize
    }

    /// The swipe completed on this frame, if any.
    mutating func followSwipe(at now: Double, config: GestureConfig) -> Trigger? {
        guard let latest = reaches.last, latest.time == now else { return nil }
        updatePendingReturn(latest, at: now, config: config)
        guard let earliest = reaches.first, earliest.time < now, now >= quietUntil else { return nil }

        let travel = (latest.tips - earliest.tips) * (1 / palmSize)
        guard travel.length >= config.swipeTravel else { return nil }
        // A hand coming into view is moving fast too, and so is one being taken away.
        guard reached(earliest.time - appeared, config.swipeSettle) else { return nil }
        // Open at some point of the movement; on its fastest frames the fingers are a blur.
        let open = reaches.contains { $0.tips.distance(to: $0.wrist) >= config.swipeOpenness * palmSize }
        // Reaching for something carries wrist and fingers along together; a swipe pivots.
        let wristTravel = latest.wrist.distance(to: earliest.wrist) / palmSize
        guard open, wristTravel * config.swipePivot <= travel.length,
              let trigger = Self.direction(of: travel, dominance: config.swipeDominance) else { return nil }
        // Once a pose hold has fired, the hand has been used; a swipe would be a second action.
        guard hold?.fired != true else { return nil }

        // A hand that swiped one way has to come back the other way, and often does so just
        // as briskly. That is not a second swipe, however long the hand waited before it.
        if let pendingReturn, trigger == Self.opposite(of: pendingReturn.trigger) { return nil }

        // The flick goes on for a few more frames, and is counted only once.
        quietUntil = now + config.swipeGap
        pendingReturn = PendingReturn(trigger: trigger, origin: (earliest.tips - earliest.wrist) * (1 / palmSize), since: now)
        palmSpent = true
        return trigger
    }

    /// Notices the hand getting back to where it was before its last swipe, which is when a
    /// flick the opposite way can be a swipe of its own again.
    private mutating func updatePendingReturn(_ latest: Reach, at now: Double, config: GestureConfig) {
        guard var pending = pendingReturn else { return }
        let offset = (latest.tips - latest.wrist) * (1 / palmSize)
        if pending.backAt == nil, offset.distance(to: pending.origin) <= config.returnReach { pending.backAt = now }
        // The way back is still under way when the hand first gets near, so it is given a
        // moment to finish before it stops being expected.
        let finished = pending.backAt.map { now - $0 > config.swipeGap } ?? false
        pendingReturn = finished || now - pending.since > config.returnWindow ? nil : pending
    }

    private static func opposite(of trigger: Trigger) -> Trigger? {
        switch trigger {
        case .swipeLeft: .swipeRight
        case .swipeRight: .swipeLeft
        // Up has no counterpart: a hand going down never fires anything.
        default: nil
        }
    }

    /// The swipe a displacement stands for. Sideways or up only: a hand going down is a hand
    /// being lowered, and anything diagonal is not a deliberate swipe.
    private static func direction(of travel: Point2, dominance: Double) -> Trigger? {
        let across = abs(travel.x)
        let along = abs(travel.y)
        if across >= dominance * along { return travel.x > 0 ? .swipeRight : .swipeLeft }
        if travel.y > 0, along >= dominance * across { return .swipeUp }
        return nil
    }
}
