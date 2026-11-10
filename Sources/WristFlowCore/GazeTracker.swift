import Foundation

public struct GazeConfig: Codable, Equatable, Sendable {
    /// Seconds the user has to keep looking at another display before it becomes the settled one.
    public var dwellTime = 0.5
    /// Share of the classifier's vote, 0...1, a frame needs to count towards a display other
    /// than the settled one. This is the hysteresis: staying takes no confidence at all, the
    /// settled display is kept until another one wins this share of the vote.
    public var switchConfidence = 0.75
    /// Seconds a dwell survives frames that do not back the candidate (another display, low
    /// confidence, looking away). The default forgives one such frame at 10 Hz.
    public var lapseTolerance = 0.15
    /// Seconds without any frame a dwell survives. Has to stay above the camera's frame
    /// interval; the default forgives one or two missing frames at 10 Hz.
    public var maxFrameGap = 0.35

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GazeConfig()
        dwellTime = try values.decodeIfPresent(Double.self, forKey: .dwellTime) ?? defaults.dwellTime
        switchConfidence = try values.decodeIfPresent(Double.self, forKey: .switchConfidence) ?? defaults.switchConfidence
        lapseTolerance = try values.decodeIfPresent(Double.self, forKey: .lapseTolerance) ?? defaults.lapseTolerance
        maxFrameGap = try values.decodeIfPresent(Double.self, forKey: .maxFrameGap) ?? defaults.maxFrameGap
    }
}

/// Follows the classifier frame by frame and decides when the user has really moved to
/// another display, as opposed to glancing at it or passing over it.
public struct GazeTracker: Sendable {
    public var config: GazeConfig
    /// Display the user is considered to be looking at. Only ever replaced by another
    /// display: looking away or losing the face leaves it as it is.
    public private(set) var settled: String?
    /// Display they may be moving to.
    public private(set) var candidate: String?
    /// 0...1 of the dwell towards `candidate`; 0 when there is none.
    public private(set) var progress = 0.0
    /// What the classifier made of the latest frame; nil when it was rejected.
    public private(set) var estimate: GazeEstimate?

    private let classifier: GazeClassifier
    /// Time of the first frame of the current dwell.
    private var dwellStart = 0.0
    /// Time of the latest frame that backed `candidate`.
    private var lastSupport = 0.0

    public init(classifier: GazeClassifier, config: GazeConfig = GazeConfig()) {
        self.classifier = classifier
        self.config = config
    }

    /// Returns a display id only at the moment `settled` changes, including the first time.
    public mutating func ingest(_ face: FaceFrame) -> String? {
        let time = face.time
        guard time.isFinite else { return nil }
        estimate = classifier.classify(GazeFeatures.vector(face))
        // A clock that jumps back (a new camera session, a replayed recording) says nothing
        // about how long the user has been looking.
        if candidate != nil, time < lastSupport { dropCandidate() }

        guard let estimate, estimate.display != settled, estimate.confidence >= config.switchConfidence else {
            if candidate != nil, time - lastSupport > config.lapseTolerance { dropCandidate() }
            return nil
        }

        if candidate != estimate.display {
            // A single frame for a third display is as forgivable as one for the settled display.
            if candidate != nil, time - lastSupport <= config.lapseTolerance { return nil }
            candidate = estimate.display
            dwellStart = time
        } else if time - lastSupport > config.maxFrameGap {
            // The face was gone in between; what it did meanwhile is unknown.
            dwellStart = time
        }
        lastSupport = time

        let elapsed = time - dwellStart
        guard elapsed >= config.dwellTime else {
            progress = elapsed / config.dwellTime
            return nil
        }
        settled = estimate.display
        dropCandidate()
        return settled
    }

    /// Forgets everything, the settled display included. For when the displays, the camera
    /// or the calibration change.
    public mutating func reset() {
        settled = nil
        estimate = nil
        dropCandidate()
    }

    private mutating func dropCandidate() {
        candidate = nil
        progress = 0
    }
}
