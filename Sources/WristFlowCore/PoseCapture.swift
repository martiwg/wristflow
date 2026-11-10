import Foundation

/// Collects steady takes of a hand from the camera's frames.
///
/// Three guided flows use it: calibrating a built-in pose, recording a new shape in several
/// takes, and capturing a hand resting at the face. A take is a run of frames on which the
/// asked hand is clearly seen and held still; between takes the hand has to be taken away, so
/// that each take is a separate showing and the takes differ the way the same pose differs
/// from one day to the next.
///
/// All timing comes from `HandFrame.time`, so the frame rate may vary and frames may be missing.
public struct PoseCapture: Sendable {
    public struct Request: Equatable, Sendable {
        /// The hand that must be shown; nil when either will do.
        public var hand: Handedness?
        /// How many separate showings are wanted; at least 1.
        public var takes: Int
        /// How many steady frames one take collects; at least 1.
        public var framesPerTake: Int
        /// Whether the hand must be held out towards the camera: above the engine's
        /// `withdrawRatio` next to the face, when a face is known. False for the hand-at-face
        /// step, which asks for the opposite.
        public var heldOut: Bool

        public init(hand: Handedness? = nil, takes: Int = 1, framesPerTake: Int = 24, heldOut: Bool = true) {
            self.hand = hand
            self.takes = max(1, takes)
            self.framesPerTake = max(1, framesPerTake)
            self.heldOut = heldOut
        }
    }

    /// What stops frames from being collected right now, for a live hint.
    public enum Problem: Equatable, Sendable {
        case noHand
        /// The other hand than the one asked for is shown.
        case wrongHand
        /// The hand is too small in the image to be measured.
        case tooFar
        /// The hand, one of its joints or which hand it is was not seen well enough.
        case unclear
        case moving
        /// The hand is back at the face's distance instead of held out towards the camera.
        case byTheHead
    }

    public enum Phase: Equatable, Sendable {
        /// No frame is being collected, because of the problem given. A take that was under
        /// way is kept meanwhile, unless the hand stays away.
        case waiting(Problem)
        /// Frames are being collected for take number `take` (from 1); `progress` is 0...1
        /// within it.
        case capturing(take: Int, progress: Double)
        /// A take is done: the hand has to be taken away before take number `next` (from 1).
        case lowerHand(next: Int)
        case done
    }

    /// Seconds the palm centre must have stayed within `steadyRadius` for a frame to be
    /// collected. Looking back only this far allows the slow drift of a hand held up in the air.
    static let steadyTime = 0.25
    /// How far the palm centre may be from where it is now over the last `steadyTime`, in palm sizes.
    static let steadyRadius = 0.15
    /// Seconds without a usable hand after which a take under way starts over; shorter
    /// dropouts only pause it.
    static let restartAfter = 0.5
    /// Seconds the hand must have been away between two takes.
    static let lowerTime = 0.4
    /// How far the palm centre must be from where the last take ended, in palm sizes of that
    /// take, for a hand still in view to count as taken away.
    static let awayDistance = 1.0

    public let request: Request
    public private(set) var phase = Phase.waiting(.noHand)
    /// The frames of each completed take.
    public private(set) var takes: [[Hand]] = []
    /// Palm size over face height on the frames of the completed takes, for the ones on which
    /// a face was known.
    public private(set) var palmToFace: [Double] = []

    private let config: GestureConfig
    /// The face as last reported.
    private var face: FaceFrame?
    /// The frames of the take under way and their palm-to-face ratios.
    private var pending: [Hand] = []
    private var pendingRatios: [Double] = []
    /// Time of the latest frame, to notice a clock that starts over.
    private var latestFrame: Double?
    /// When a usable hand was last in view.
    private var lastSeen: Double?
    /// Recent palm centres of the hand, oldest first, reaching back just past `steadyTime`.
    private var path: [(time: Double, center: Point2)] = []
    /// Where the last completed take ended.
    private var lastTake: (center: Point2, palmSize: Double)?
    /// Since when the hand has been away after the last completed take.
    private var awaySince: Double?

    public init(request: Request, config: GestureConfig = GestureConfig()) {
        self.request = request
        self.config = config
    }

    /// 0...1 over all takes, counting the frames of the take under way.
    public var overallProgress: Double {
        if phase == .done { return 1 }
        let wanted = request.takes * request.framesPerTake
        return min(1, Double(takes.count * request.framesPerTake + pending.count) / Double(wanted))
    }

    /// Tells the capture where the user's face is. Without it no hand counts as by the head.
    public mutating func ingest(_ face: FaceFrame) {
        self.face = face
    }

    public mutating func ingest(_ frame: HandFrame) {
        let now = frame.time
        // A clock that runs backwards means a new camera session; stored times mean nothing.
        // What was collected is still good.
        if let latestFrame, now < latestFrame {
            lastSeen = nil
            path = []
            awaySince = nil
            face = nil
        }
        latestFrame = now
        guard phase != .done else { return }

        let usable = frame.hands.filter {
            Double($0.confidence) >= config.minConfidence && $0.palmSize >= config.minPalmSize
        }
        if let lastSeen, now - lastSeen > Self.restartAfter {
            pending = []
            pendingRatios = []
            path = []
        }
        let hand = chosen(among: usable)
        if let hand {
            lastSeen = now
            follow(hand, at: now)
        }

        if case .lowerHand = phase {
            guard hasBeenTakenAway(usable, at: now) else { return }
        }

        if let problem = problem(with: hand, in: frame, at: now) {
            phase = .waiting(problem)
        } else if let hand {
            collect(hand, at: now)
        }
    }

    /// The hand to capture: the largest usable one, of the asked hand when one of those is in view.
    private func chosen(among usable: [Hand]) -> Hand? {
        let asked = usable.filter { request.hand == nil || $0.handedness == request.hand }
        return (asked.isEmpty ? usable : asked).max { $0.palmSize < $1.palmSize }
    }

    private mutating func follow(_ hand: Hand, at now: Double) {
        path.append((now, hand.palmCenter))
        // Keep one sample at or beyond the horizon, so a rest of exactly that length can be seen.
        let horizon = now - Self.steadyTime
        while path.count > 1, path[1].time <= horizon { path.removeFirst() }
    }

    /// Seconds the palm centre has stayed within `radius` (image heights) of where it is now.
    private func restDuration(radius: Double) -> Double {
        guard let newest = path.last else { return 0 }
        var since = newest.time
        for sample in path.reversed() {
            guard sample.center.distance(to: newest.center) <= radius else { break }
            since = sample.time
        }
        return newest.time - since
    }

    /// Palm size over face height, when a face was seen recently enough to go by.
    private func ratioToFace(_ hand: Hand, at now: Double) -> Double? {
        guard let face, face.size > 0, abs(now - face.time) <= config.faceMemory else { return nil }
        return hand.palmSize / face.size
    }

    /// Why this frame cannot be collected, or nil when it can.
    private func problem(with hand: Hand?, in frame: HandFrame, at now: Double) -> Problem? {
        guard let hand else {
            guard let largest = frame.hands.max(by: { $0.palmSize < $1.palmSize }) else { return .noHand }
            return largest.palmSize < config.minPalmSize ? .tooFar : .unclear
        }
        if let asked = request.hand, hand.handedness != asked {
            return hand.handedness == nil ? .unclear : .wrongHand
        }
        // Every measurement of a shape needs its joints; a take must not contain frames that
        // can only be measured in part.
        guard hand.confidences.allSatisfy({ $0 >= PoseClassifier.minJointConfidence }) else { return .unclear }
        if request.heldOut, let ratio = ratioToFace(hand, at: now), ratio <= config.withdrawRatio { return .byTheHead }
        // Frame times are sums of floating-point intervals, hence the allowance.
        guard restDuration(radius: Self.steadyRadius * hand.palmSize) >= Self.steadyTime - 1e-9 else { return .moving }
        return nil
    }

    private mutating func collect(_ hand: Hand, at now: Double) {
        pending.append(hand)
        if let ratio = ratioToFace(hand, at: now) { pendingRatios.append(ratio) }
        guard pending.count >= request.framesPerTake else {
            phase = .capturing(take: takes.count + 1, progress: Double(pending.count) / Double(request.framesPerTake))
            return
        }
        takes.append(pending)
        palmToFace += pendingRatios
        pending = []
        pendingRatios = []
        lastTake = (hand.palmCenter, hand.palmSize)
        awaySince = nil
        phase = takes.count >= request.takes ? .done : .lowerHand(next: takes.count + 1)
    }

    /// Whether the hand of the last take has been out of view, or somewhere else, for
    /// `lowerTime`; called on every frame after a take.
    private mutating func hasBeenTakenAway(_ usable: [Hand], at now: Double) -> Bool {
        let stillThere = usable.contains { hand in
            guard let lastTake else { return false }
            // The other hand coming into view is not the hand of the take staying.
            if let asked = request.hand, let shown = hand.handedness, shown != asked { return false }
            return hand.palmCenter.distance(to: lastTake.center) <= Self.awayDistance * lastTake.palmSize
        }
        guard !stillThere else {
            awaySince = nil
            return false
        }
        let since = awaySince ?? now
        awaySince = since
        return now - since >= Self.lowerTime - 1e-9
    }
}
