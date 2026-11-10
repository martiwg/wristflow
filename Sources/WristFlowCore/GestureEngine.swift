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
    /// Seconds the open palm must stay within `restRadius` before a swipe can start from there.
    public var restTime = 0.12
    /// Seconds of rest needed, instead of `restTime`, once the palm has already moved off after being armed.
    public var rearmRestTime = 0.35
    /// How far the palm centre may drift, in palm sizes, and still count as resting.
    public var restRadius = 0.1
    /// Straight-line distance from the resting point, in palm sizes, that makes a swipe.
    public var swipeDistance = 1.2
    /// Seconds, counted from leaving rest, within which `swipeDistance` must be covered.
    public var swipeWindow = 0.45
    /// How many times larger the travel along the swipe axis must be than across it (ratio).
    public var swipeDominance = 2.0
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
        rearmRestTime = try value(.rearmRestTime, defaults.rearmRestTime)
        restRadius = try value(.restRadius, defaults.restRadius)
        swipeDistance = try value(.swipeDistance, defaults.swipeDistance)
        swipeWindow = try value(.swipeWindow, defaults.swipeWindow)
        swipeDominance = try value(.swipeDominance, defaults.swipeDominance)
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
    /// The open palm has come to rest, so moving it now can become a swipe.
    public var armedForSwipe: Bool

    public init(handVisible: Bool = false, pose: Pose? = nil, holdProgress: Double = 0, armedForSwipe: Bool = false) {
        self.handVisible = handVisible
        self.pose = pose
        self.holdProgress = holdProgress
        self.armedForSwipe = armedForSwipe
    }
}

/// Turns a stream of hand frames into triggers: poses held still, and swipes of the open palm.
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
            if seen == nil, now - followed.lastSeen > followed.patience(config) { track = nil }
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
        guard let seen else {
            // A short dropout leaves everything as it was. A longer wait is only granted in
            // the middle of a swipe; nobody saw what the hand did meanwhile, so it does not
            // count as holding, and the preview should not show a hand that is not there.
            if now - followed.lastSeen > config.glitchTolerance {
                followed.restartHold(at: now)
                track = followed
                state = GestureState()
            }
            return nil
        }

        let hand = usable[seen]
        let elapsed = now - followed.lastSeen
        followed.observe(hand, at: now, config: config)
        let reading = PoseClassifier.classify(hand)
        let rested = followed.restDuration(radius: config.restRadius * followed.palmSize)

        followed.followPose(
            reading, trusted: reached(rested, config.restTime), at: now, elapsed: elapsed, config: config
        )
        var trigger = followed.completeHold(reading, at: now, config: config).map(Trigger.init(pose:))
        let swipe = followed.followSwipe(rested: rested, at: now, config: config)
        trigger = trigger ?? swipe

        state = GestureState(
            handVisible: true,
            pose: reading,
            holdProgress: followed.holdProgress(at: now, holdTime: config.holdTime),
            armedForSwipe: followed.swipe.isLive
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
        /// A swipe was made from it, which replaces its trigger.
        var swiped = false
    }

    /// Where a swipe would start from.
    struct Origin: Sendable {
        var center: Point2
        var time: Double
        /// Palm size while at rest; the frames of the swipe itself are too blurred to measure it.
        var palmSize: Double
    }

    enum SwipeStage: Sendable {
        /// The palm has to come to rest before anything can happen.
        case waiting
        /// Resting with an open palm; the origin follows the palm.
        case armed(Origin)
        /// Left the resting point; watching how far and which way it goes.
        case moving(Origin)

        var isLive: Bool {
            if case .waiting = self { return false }
            return true
        }
    }

    var center: Point2
    var palmSize: Double
    var lastSeen: Double
    /// Recent palm centres, oldest first, reaching back just past the longest rest that is asked for.
    var path: [Sample] = []
    var hold: Hold?
    /// A different pose that has started to show while `hold` is still being forgiven.
    var challenger: (pose: Pose, since: Double)?
    var swipe = SwipeStage.waiting
    /// The palm has moved off after being armed, so the next arming needs the longer rest.
    var hasLeftRest = false

    init(hand: Hand, time: Double) {
        center = hand.palmCenter
        palmSize = hand.palmSize
        lastSeen = time
    }

    /// Seconds the hand may go unseen before this appearance is over.
    func patience(_ config: GestureConfig) -> Double {
        // The fast part of a swipe can blur the hand out of detection altogether. Giving up
        // then would lose the swipe and take the hand for a new one where it stops, whose
        // way back would fire the opposite swipe.
        swipe.isLive ? max(config.glitchTolerance, config.swipeWindow) : config.glitchTolerance
    }

    mutating func observe(_ hand: Hand, at now: Double, config: GestureConfig) {
        let blend = config.palmSizeSmoothing > 0 ? min(1, (now - lastSeen) / config.palmSizeSmoothing) : 1
        palmSize += (hand.palmSize - palmSize) * blend
        center = hand.palmCenter
        lastSeen = now
        path.append(Sample(time: now, center: center))
        // Keep one sample at or beyond the horizon, so a rest of exactly that length can be seen.
        let horizon = now - max(config.restTime, config.rearmRestTime)
        while path.count > 1, path[1].time <= horizon { path.removeFirst() }
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
            // already been used, or the same pose would fire again where the hand stops, nor
            // one a swipe is being made from.
            let shielded = !trusted && (current.fired || current.swiped || swipe.isLive)
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
        guard var current = hold, !current.fired, !current.swiped, reading == current.pose,
              reached(now - current.since, config.holdTime) else { return nil }
        current.fired = true
        hold = current
        return current.pose
    }

    func holdProgress(at now: Double, holdTime: Double) -> Double {
        guard let hold, !hold.swiped else { return 0 }
        if hold.fired || holdTime <= 0 { return 1 }
        return min(1, max(0, (now - hold.since) / holdTime))
    }

    /// Advances the swipe stage; `rested` is how long the palm has been at rest, in seconds.
    mutating func followSwipe(rested: Double, at now: Double, config: GestureConfig) -> Trigger? {
        let resting = reached(rested, config.restTime)
        // Once the palm hold has fired, the palm has been used; a swipe would be a second action.
        let palmReady = hold.map { $0.pose == .openPalm && !$0.fired } ?? false
        let here = Origin(center: center, time: now, palmSize: palmSize)

        switch swipe {
        case .waiting:
            let needed = hasLeftRest ? config.rearmRestTime : config.restTime
            if palmReady, reached(rested, needed) { swipe = .armed(here) }
            return nil
        case .armed(let origin):
            guard palmReady else {
                swipe = .waiting
                return nil
            }
            if resting {
                swipe = .armed(here)
                return nil
            }
            // From here on the hand is in motion and its pose cannot be trusted, so only the
            // palm centre is followed. The turning point of a return stroke is slow for about
            // as long as the first rest takes, hence the longer rest from now on.
            hasLeftRest = true
            swipe = .moving(origin)
        case .moving:
            break
        }

        guard case .moving(let origin) = swipe else { return nil }
        if resting || hold?.fired == true || now - origin.time > config.swipeWindow + 1e-9 {
            swipe = .waiting
            return nil
        }
        let travel = (center - origin.center) * (1 / origin.palmSize)
        guard travel.length >= config.swipeDistance,
              let trigger = Self.direction(of: travel, dominance: config.swipeDominance) else { return nil }
        swipe = .waiting
        hold?.swiped = true
        return trigger
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
