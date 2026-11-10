import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Vision
import WristFlowCore
import os

/// Runs Apple Vision on the camera and reports hand and face landmarks in the core's
/// coordinate system. Frames are analysed in memory and released; nothing is stored or sent.
///
/// Threading: camera frames arrive on the camera's capture queue, where a frame is either
/// dropped or handed to one detached task. `onHands` and `onFace` are called from that task (a
/// Swift concurrency pool thread), in frame order and never concurrently, because a new frame
/// is only accepted once the previous task has finished. A frame that was already being
/// analysed when `stop()` was called can still be reported just after it returns.
///
/// All mutable state is guarded by `lock`, which is what makes the type safe to share.
final class VisionLandmarker: LandmarkSource, @unchecked Sendable {
    /// With no hand in view only the face is being followed, which needs no more than this.
    private static let idleFrameRate = 10.0
    /// Gestures are judged on speed and timing, so they get the camera's full rate.
    private static let activeFrameRate = 30.0
    /// How long the hand must be gone before dropping back to the idle rate; long enough to
    /// ride out a hand that leaves the frame for a moment mid-gesture.
    private static let idleDelay = 2.0
    /// Head pose changes slowly, so the face is measured less often than hands.
    private static let faceRate = 10.0
    /// With nobody using the face and no hand in view, it is still looked for now and then,
    /// so that when a hand does appear it is already known whether it is at the face.
    private static let backgroundFaceRate = 2.0
    /// A frame counts as due this fraction of a period after the previous one, so timing
    /// jitter at the nominal rate does not make every other frame look early.
    private static let dueTolerance = 0.75

    private let camera: CameraSource
    private let handRequest: DetectHumanHandPoseRequest
    private let faceRequest = DetectFaceLandmarksRequest()
    private let log = Logger(subsystem: "WristFlow", category: "vision")

    private let lock = NSLock()
    private var handsCallback: (@Sendable (HandFrame) -> Void)?
    private var faceCallback: (@Sendable (FaceFrame) -> Void)?
    private var faceWanted = true
    private var running = false
    private var busy = false
    private var targetFrameRate = VisionLandmarker.idleFrameRate
    private var lastProcessedTime = -Double.infinity
    private var lastFaceTime = -Double.infinity
    private var lastHandTime = -Double.infinity
    private var lastErrorLogTime = -Double.infinity
    private var counters = Statistics()

    /// Running totals since `start()`, for the development tools.
    struct Statistics {
        var framesReceived = 0
        var framesAnalysed = 0
        var faceRuns = 0
        /// Seconds spent inside Vision.
        var handSeconds = 0.0
        var faceSeconds = 0.0
    }

    var statistics: Statistics { lock.withLock { counters } }

    /// - Parameter cameraID: a `CameraDevice.id`, or nil for the default camera.
    init(cameraID: String?) {
        camera = CameraSource(deviceID: cameraID)
        var request = DetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        handRequest = request
        camera.onFrame = { [weak self] pixelBuffer, time in
            self?.receive(pixelBuffer, time: time)
        }
    }

    var onHands: (@Sendable (HandFrame) -> Void)? {
        get { lock.withLock { handsCallback } }
        set { lock.withLock { handsCallback = newValue } }
    }

    var onFace: (@Sendable (FaceFrame) -> Void)? {
        get { lock.withLock { faceCallback } }
        set { lock.withLock { faceCallback = newValue } }
    }

    /// When false the face is measured only as often as it takes to tell a hand at the face
    /// from a gesture: at the full rate while a hand is in view, rarely otherwise. May be
    /// changed while running.
    var faceEnabled: Bool {
        get { lock.withLock { faceWanted } }
        set { lock.withLock { faceWanted = newValue } }
    }

    /// The camera session, for a preview layer.
    var session: AVCaptureSession { camera.session }

    func start() throws {
        lock.withLock {
            running = true
            counters = Statistics()
            targetFrameRate = Self.idleFrameRate
            lastProcessedTime = -.infinity
            lastFaceTime = -.infinity
            lastHandTime = -.infinity
        }
        camera.setFrameRate(Self.idleFrameRate)
        do {
            try camera.start()
        } catch {
            lock.withLock { running = false }
            throw error
        }
    }

    func stop() {
        lock.withLock { running = false }
        camera.stop()
    }

    // MARK: Frames

    /// Capture queue. Decides whether this frame is analysed; never blocks on Vision.
    private func receive(_ pixelBuffer: CVPixelBuffer, time: Double) {
        let wantsFace: Bool? = lock.withLock {
            counters.framesReceived += 1
            // Dropping while busy keeps latency flat: a queue of frames would only deliver
            // old news later.
            guard running, !busy else { return nil }
            // The camera may not support the rate asked for (many webcams only do 30 fps),
            // so the saving is enforced here as well.
            guard time - lastProcessedTime >= Self.dueTolerance / targetFrameRate else { return nil }
            busy = true
            counters.framesAnalysed += 1
            lastProcessedTime = time
            let handAround = time - lastHandTime < Self.idleDelay
            let faceRate = faceWanted || handAround ? Self.faceRate : Self.backgroundFaceRate
            let faceDue = time - lastFaceTime >= Self.dueTolerance / faceRate
            if faceDue { lastFaceTime = time }
            return faceDue
        }
        guard let wantsFace else { return }

        Task.detached(priority: .userInitiated) { [self] in
            await analyse(pixelBuffer, time: time, wantsFace: wantsFace)
            lock.withLock { busy = false }
        }
    }

    private func analyse(_ pixelBuffer: CVPixelBuffer, time: Double, wantsFace: Bool) async {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        // `.up` because CameraSource guarantees upright, unmirrored buffers.
        let handler = ImageRequestHandler(pixelBuffer, orientation: .up)

        // Hands first and reported straight away: gestures are the latency-sensitive part.
        let handStart = ProcessInfo.processInfo.systemUptime
        do {
            let observations = try await handler.perform(handRequest)
            let elapsed = ProcessInfo.processInfo.systemUptime - handStart
            lock.withLock { counters.handSeconds += elapsed }
            let aspect = imageSize.width / imageSize.height
            let hands = observations.compactMap { Self.hand(from: $0, aspect: aspect) }
            adaptFrameRate(handVisible: !hands.isEmpty, time: time)
            if let callback = lock.withLock({ running ? handsCallback : nil }) {
                callback(HandFrame(time: time, hands: hands))
            }
        } catch {
            // Not reported as an empty frame: that would read as "the hand left".
            logFailure("Hand detection", error, time: time)
        }

        guard wantsFace else { return }
        let faceStart = ProcessInfo.processInfo.systemUptime
        do {
            let faces = try await handler.perform(faceRequest)
            let elapsed = ProcessInfo.processInfo.systemUptime - faceStart
            lock.withLock {
                counters.faceRuns += 1
                counters.faceSeconds += elapsed
            }
            let largest = faces.max { Self.area($0) < Self.area($1) }
            guard let largest, let callback = lock.withLock({ running ? faceCallback : nil }) else { return }
            callback(Self.faceFrame(from: largest, time: time, imageSize: imageSize))
        } catch {
            logFailure("Face detection", error, time: time)
        }
    }

    private func adaptFrameRate(handVisible: Bool, time: Double) {
        let newRate: Double? = lock.withLock {
            if handVisible {
                lastHandTime = time
                guard targetFrameRate != Self.activeFrameRate else { return nil }
                targetFrameRate = Self.activeFrameRate
            } else {
                guard targetFrameRate != Self.idleFrameRate, time - lastHandTime >= Self.idleDelay else { return nil }
                targetFrameRate = Self.idleFrameRate
            }
            return targetFrameRate
        }
        if let newRate { camera.setFrameRate(newRate) }
    }

    private func logFailure(_ what: String, _ error: Error, time: Double) {
        // A persistent failure would otherwise write a line per frame.
        let due = lock.withLock {
            guard time - lastErrorLogTime >= 5 else { return false }
            lastErrorLogTime = time
            return true
        }
        if due { log.error("\(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Conversion to core types

    /// Vision's joint names in the order of `WristFlowCore.Joint.rawValue`. Vision calls the
    /// thumb's middle knuckle MP where the core (following MediaPipe) says MCP.
    private static let visionJointOrder: [HumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    /// Vision's normalised point (origin bottom left of the unmirrored image, each axis in its
    /// own image dimension) as the core's mirror-view point with both axes in image heights.
    private static func mirrored(_ point: NormalizedPoint, aspect: Double) -> Point2 {
        Point2(x: (1 - Double(point.x)) * aspect, y: Double(point.y))
    }

    private static func hand(from observation: HumanHandPoseObservation, aspect: Double) -> Hand? {
        let joints = observation.allJoints()
        var points: [Point2?] = []
        var confidences: [Float] = []
        for name in visionJointOrder {
            // A joint Vision has no confidence in carries no position worth using.
            if let joint = joints[name], joint.confidence > 0 {
                points.append(mirrored(joint.location, aspect: aspect))
                confidences.append(joint.confidence)
            } else {
                points.append(nil)
                confidences.append(0)
            }
        }
        let known = points.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        // An unknown joint sits at the centre of the known ones, with confidence 0, so it
        // cannot stretch the hand's geometry the way a point at the image corner would.
        let centre = known.reduce(Point2.zero, +) * (1 / Double(known.count))

        // Chirality is passed through unchanged. Vision classifies the hand as it appears in
        // the image it is given, and that image is unmirrored (a true view of the scene), so
        // `.right` already means the user's right hand. Only the coordinates are mirrored
        // afterwards, and relabelling them does not change which hand it is. Had the buffers
        // been mirrored before Vision saw them, left and right would need swapping here.
        let handedness: Handedness? = switch observation.chirality {
        case .left: .left
        case .right: .right
        default: nil
        }
        return Hand(handedness: handedness, points: points.map { $0 ?? centre }, confidences: confidences)
    }

    private static func area(_ face: FaceObservation) -> Double {
        Double(face.boundingBox.width * face.boundingBox.height)
    }

    /// Head angles, from Vision's documented conventions (VNFaceObservation in VNObservation.h)
    /// to the core's, which are defined on the user's own body:
    ///
    /// - Yaw. Vision: positive is counterclockwise, i.e. about the vertical axis seen from
    ///   above, which is the head turning towards the person's own left (towards the right
    ///   edge of the unmirrored image). Core: positive turns towards the user's right.
    ///   Sign flipped.
    /// - Pitch. Vision: positive is nodding down. Core: positive looks up. Sign flipped;
    ///   mirroring left and right has no effect on it.
    /// - Roll. Vision: positive is counterclockwise in the image. In the unmirrored image
    ///   that moves the top of the head towards the left edge, which is the user's right, so
    ///   it is already a tilt towards the user's right shoulder. Sign kept. (As a rotation
    ///   drawn in the mirror view it does turn clockwise, but the core defines roll by the
    ///   shoulder, and "towards the right shoulder" is clockwise in a mirror: the two
    ///   reversals cancel.)
    private static let yawSign = -1.0
    private static let pitchSign = -1.0
    private static let rollSign = 1.0

    private static func faceFrame(from face: FaceObservation, time: Double, imageSize: CGSize) -> FaceFrame {
        let aspect = imageSize.width / imageSize.height
        let box = face.boundingBox.cgRect
        return FaceFrame(
            time: time,
            yaw: yawSign * face.yaw.converted(to: .radians).value,
            pitch: pitchSign * face.pitch.converted(to: .radians).value,
            roll: rollSign * face.roll.converted(to: .radians).value,
            center: Point2(x: (1 - box.midX) * aspect, y: box.midY),
            // The box height is normalised by the image height, which is the core's unit.
            size: box.height,
            pupilOffset: pupilOffset(of: face, imageSize: imageSize)
        )
    }

    /// Mean of both eyes' pupil offsets. Nil unless both eyes can be read: one eye alone sits
    /// differently in its socket, so mixing one-eye and two-eye values would add a jump.
    private static func pupilOffset(of face: FaceObservation, imageSize: CGSize) -> Point2? {
        guard let landmarks = face.landmarks,
              let left = pupilOffset(eye: landmarks.leftEye, pupil: landmarks.leftPupil, imageSize: imageSize),
              let right = pupilOffset(eye: landmarks.rightEye, pupil: landmarks.rightPupil, imageSize: imageSize)
        else { return nil }
        return (left + right) * 0.5
    }

    /// An eye whose outline is flatter than this (height / width) is closed or blinking, and
    /// dividing by its height would turn landmark noise into a huge offset.
    private static let minimumEyeOpenness = 0.1

    /// Where the pupil sits in one eye: 0 at the middle, ±1 at the corners (x, positive
    /// towards the user's right) and at the lids (y, positive up).
    ///
    /// Measured along the eye's own axes, found from its outline, so a tilted head does not
    /// leak horizontal movement into the vertical value.
    private static func pupilOffset(
        eye: FaceObservation.Landmarks2D.Region,
        pupil: FaceObservation.Landmarks2D.Region,
        imageSize: CGSize
    ) -> Point2? {
        // Pixels are square, which normalised coordinates are not; mirrored like every point.
        func mirrorViewPixels(_ region: FaceObservation.Landmarks2D.Region) -> [Point2] {
            region.pointsInImageCoordinates(imageSize, origin: .lowerLeft).map {
                Point2(x: Double(imageSize.width - $0.x), y: Double($0.y))
            }
        }
        let outline = mirrorViewPixels(eye)
        let pupilPoints = mirrorViewPixels(pupil)
        guard outline.count >= 3, !pupilPoints.isEmpty else { return nil }
        let pupilCentre = pupilPoints.reduce(Point2.zero, +) * (1 / Double(pupilPoints.count))

        // The two outline points furthest apart are the corners of the eye.
        var corners = (outline[0], outline[0])
        var widest = 0.0
        for (index, a) in outline.enumerated() {
            for b in outline[(index + 1)...] where a.distance(to: b) > widest {
                widest = a.distance(to: b)
                corners = (a, b)
            }
        }
        guard widest > 0 else { return nil }
        var along = (corners.1 - corners.0) * (1 / widest)
        if along.x < 0 { along = along * -1 }
        let across = Point2(x: -along.y, y: along.x)

        func dot(_ a: Point2, _ b: Point2) -> Double { a.x * b.x + a.y * b.y }
        let alongValues = outline.map { dot($0, along) }
        let acrossValues = outline.map { dot($0, across) }
        guard let minAlong = alongValues.min(), let maxAlong = alongValues.max(),
              let minAcross = acrossValues.min(), let maxAcross = acrossValues.max()
        else { return nil }
        let halfWidth = (maxAlong - minAlong) / 2
        let halfHeight = (maxAcross - minAcross) / 2
        guard halfWidth > 0, halfHeight >= halfWidth * minimumEyeOpenness else { return nil }

        return Point2(
            x: (dot(pupilCentre, along) - (minAlong + maxAlong) / 2) / halfWidth,
            y: (dot(pupilCentre, across) - (minAcross + maxAcross) / 2) / halfHeight
        )
    }
}
