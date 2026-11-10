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
    /// How far the fingertips must travel within `swipeWindow`, in palm sizes, to make a swipe.
    public var swipeTravel = 1.8
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
    /// Seconds after a swipe during which no other swipe is read.
    public var swipeGap = 0.25
    /// Seconds after a swipe during which a movement the opposite way is taken for the hand going back.
    public var returnWindow = 0.5
    /// Seconds over which the measured palm size is averaged, so a blurred frame cannot change the yardstick.
    public var palmSizeSmoothing = 0.25

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
        palmSizeSmoothing = try value(.palmSizeSmoothing, defaults.palmSizeSmoothing)
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

    public init(handVisible: Bool = false, pose: Pose? = nil, holdProgress: Double = 0, armedForSwipe: Bool = false) {
        self.handVisible = handVisible
        self.pose = pose
        self.holdProgress = holdProgress
        self.armedForSwipe = armedForSwipe
    }
}

/// Turns a stream of hand frames into triggers: poses held still, and swipes of the open hand.
///
/// A swipe is a flick: the fingertips sweeping sideways or upwards in about a tenth of a second
/// while the wrist stays roughly where it is. That is how people swipe at a screen in practice,
/// and its speed is what tells it from the slower way back and from a hand merely moving.
///
/// All timing comes from `HandFrame.time`, so the frame rate may vary and frames may be missing.
public struct GestureEngine: Sendable {
    public var config: GestureConfig
    public private(set) var state = GestureState()

    private var track: Track?
    /// Where the usable hands that are not being followed were in the latest frame.
    private var bystanders: [Point2] = []

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    /// Forgets the hand being followed, as if the camera had just started.
    public mutating func reset() {
        track = nil
        bystanders = []
        state = GestureState()
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
            state = GestureState()
            return nil
        }
        // A dropout short enough to keep the appearance leaves everything as it was.
        guard let seen else { return nil }

        let hand = usable[seen]
        let elapsed = now - followed.lastSeen
        followed.observe(hand, at: now, config: config)
        let reading = PoseClassifier.classify(hand)
        let rested = followed.restDuration(radius: config.restRadius * followed.palmSize)

        followed.followPose(
            reading, trusted: reached(rested, config.restTime), at: now, elapsed: elapsed, config: config
        )
        var trigger = followed.completeHold(reading, at: now, config: config).map(Trigger.init(pose:))
        let swipe = followed.followSwipe(at: now, config: config)
        trigger = trigger ?? swipe

        state = GestureState(
            handVisible: true,
            pose: reading,
            holdProgress: followed.holdProgress(at: now, holdTime: config.holdTime),
            armedForSwipe: followed.canSwipe(at: now, config: config)
        )
        track = followed
        return trigger
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
        /// Its trigger has been emitted.
        var fired = false
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
    /// Recent palm centres, oldest first, reaching back just past the longest rest that is asked for.
    var path: [Sample] = []
    var hold: Hold?
    /// A different pose that has started to show while `hold` is still being forgiven.
    var challenger: (pose: Pose, since: Double)?
    /// When this appearance began.
    let appeared: Double
    /// Recent fingertip and wrist positions, oldest first, reaching back `swipeWindow`.
    var reaches: [Reach] = []
    var lastSwipe: (time: Double, trigger: Trigger)?
    /// A swipe was made in this appearance, which uses up its open palm: the hand that swiped
    /// is still open afterwards, and must not also count as a palm being shown.
    var palmSpent = false

    init(hand: Hand, time: Double) {
        center = hand.palmCenter
        palmSize = hand.palmSize
        lastSeen = time
        appeared = time
    }

    mutating func observe(_ hand: Hand, at now: Double, config: GestureConfig) {
        let blend = config.palmSizeSmoothing > 0 ? min(1, (now - lastSeen) / config.palmSizeSmoothing) : 1
        palmSize += (hand.palmSize - palmSize) * blend
        center = hand.palmCenter
        lastSeen = now
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

    /// The pose whose hold completes on this frame, if any.
    mutating func completeHold(_ reading: Pose?, at now: Double, config: GestureConfig) -> Pose? {
        guard var current = hold, !current.fired, reading == current.pose,
              !(current.pose == .openPalm && palmSpent),
              reached(now - current.since, config.holdTime) else { return nil }
        current.fired = true
        hold = current
        // Deliberately showing another pose ends the swiping; the palm means palm again.
        palmSpent = false
        return current.pose
    }

    func holdProgress(at now: Double, holdTime: Double) -> Double {
        guard let hold, !(hold.pose == .openPalm && palmSpent) else { return 0 }
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
        guard let latest = reaches.last, latest.time == now, let earliest = reaches.first, earliest.time < now else { return nil }
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
        if let lastSwipe {
            let since = now - lastSwipe.time
            if since < config.swipeGap { return nil }
            // The first fast movement is the swipe. What comes straight back is the hand
            // returning, however briskly.
            if since < config.returnWindow, trigger == Self.opposite(of: lastSwipe.trigger) { return nil }
        }
        lastSwipe = (now, trigger)
        palmSpent = true
        return trigger
    }

    private static func opposite(of trigger: Trigger) -> Trigger? {
        switch trigger {
        case .swipeLeft: .swipeRight
        case .swipeRight: .swipeLeft
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
