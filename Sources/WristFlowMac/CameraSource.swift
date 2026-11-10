import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import os

/// A camera the user can pick.
struct CameraDevice: Identifiable, Hashable {
    /// `AVCaptureDevice.uniqueID`, stable across restarts.
    let id: String
    let name: String
    let isBuiltIn: Bool
    /// An iPhone used through Continuity Camera.
    let isContinuity: Bool
}

enum CameraError: LocalizedError {
    case accessNotRequested
    case accessDenied
    case accessRestricted
    case noCamera
    case deviceNotFound(String)
    case cannotOpen(name: String, reason: String)
    case cannotConfigure(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .accessNotRequested:
            "Camera access has not been requested yet. Ask for it before starting the camera."
        case .accessDenied:
            "Camera access is denied. Allow WristFlow in System Settings > Privacy & Security > Camera."
        case .accessRestricted:
            "Camera access is restricted on this Mac (parental controls or a device management profile)."
        case .noCamera:
            "No camera was found. Connect a camera, or open the lid if the built-in one is covered."
        case .deviceNotFound(let id):
            "The selected camera is not connected (id \(id))."
        case .cannotOpen(let name, let reason):
            "The camera \"\(name)\" could not be opened: \(reason)"
        case .cannotConfigure(let name, let reason):
            "The camera \"\(name)\" could not be configured: \(reason)"
        }
    }
}

/// Delivers camera frames at a low resolution and an adjustable frame rate.
///
/// Threading: `start`, `stop` and `setFrameRate` may be called from any thread; the session is
/// only ever touched on a private serial queue. `onFrame` runs on a second private serial queue
/// (the capture queue) and must return quickly, because frames that arrive while it is busy
/// are dropped.
final class CameraSource: NSObject {
    /// Exposed so a preview layer can show it. Do not reconfigure it from outside.
    let session = AVCaptureSession()

    /// Pixel buffer and its capture time in seconds on the host clock, the timebase of
    /// `CACurrentMediaTime()` and `ProcessInfo.systemUptime`. Called on the capture queue.
    /// Set it before `start()`.
    ///
    /// Orientation contract: the buffer is upright (its first row is the top of the scene)
    /// and NOT mirrored, so it shows the user the way a person facing them would see them:
    /// the user's right hand is on the left of the image. The connection is forced to 0° and
    /// unmirrored below to keep that true whatever the device's defaults are.
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    private let deviceID: String?
    private let sessionQueue = DispatchQueue(label: "wristflow.camera.session")
    private let captureQueue = DispatchQueue(label: "wristflow.camera.frames", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let log = Logger(subsystem: "WristFlow", category: "camera")

    // Session queue only.
    private var device: AVCaptureDevice?
    private var requestedFrameRate: Double = 30

    private let stateLock = NSLock()
    private var started = false

    /// - Parameter deviceID: a `CameraDevice.id`, or nil for `defaultDevice()`.
    init(deviceID: String?) {
        self.deviceID = deviceID
        super.init()
    }

    deinit {
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
    }

    // MARK: Devices and permission

    /// Connected cameras, best default first.
    static func devices() -> [CameraDevice] {
        captureDevices().map { device in
            CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isBuiltIn: device.deviceType == .builtInWideAngleCamera,
                isContinuity: isContinuity(device)
            )
        }
    }

    /// The built-in camera when there is one, then any other camera fixed to the desk. An
    /// iPhone is last because macOS offers it whenever it is nearby, and picking it would wake
    /// the phone and point a camera somewhere the user does not expect.
    static func defaultDevice() -> CameraDevice? {
        devices().first
    }

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Shows the system prompt the first time; afterwards returns the stored answer.
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    private static func isContinuity(_ device: AVCaptureDevice) -> Bool {
        device.isContinuityCamera || device.deviceType == .continuityCamera
    }

    private static func captureDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        var seen = Set<String>()
        let unique = discovery.devices.filter { seen.insert($0.uniqueID).inserted }

        // A suspended camera (lid closed, privacy shutter) is listed but delivers nothing, so
        // it only wins over an iPhone.
        func rank(_ device: AVCaptureDevice) -> Int {
            if isContinuity(device) { return 3 }
            if device.isSuspended { return 2 }
            return device.deviceType == .builtInWideAngleCamera ? 0 : 1
        }
        return unique.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    // MARK: Running

    /// True between a successful `start()` and `stop()`. The session itself comes up a moment
    /// after `start()` returns, because starting it blocks for a few hundred milliseconds.
    var isRunning: Bool {
        stateLock.withLock { started }
    }

    /// Opens the camera. Throws a `CameraError` when access was not granted, no camera is
    /// connected or the camera cannot be opened.
    func start() throws {
        switch Self.authorization {
        case .authorized: break
        case .notDetermined: throw CameraError.accessNotRequested
        case .restricted: throw CameraError.accessRestricted
        case .denied: throw CameraError.accessDenied
        @unknown default: throw CameraError.accessDenied
        }

        // Configuration is synchronous so its errors reach the caller.
        try sessionQueue.sync {
            if device == nil { try configure() }
        }
        stateLock.withLock { started = true }

        sessionQueue.async { [self] in
            // A stop() that arrived in between wins.
            guard isRunning else { return }
            if !session.isRunning { session.startRunning() }
            // Applied once the session runs, when the active format is final: frame durations
            // belong to the format, and the session picks the format for its preset as it starts.
            applyFrameRate()
        }
    }

    func stop() {
        stateLock.withLock { started = false }
        sessionQueue.async { [self] in
            guard !isRunning else { return }
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Asks the camera for a fixed frame rate. The value is clamped to the nearest rate the
    /// active format supports, so a camera that only does 30 fps stays at 30 fps. Takes effect
    /// asynchronously; before `start()` it is remembered and applied when the session starts.
    func setFrameRate(_ fps: Double) {
        sessionQueue.async { [self] in
            requestedFrameRate = fps
            if session.isRunning { applyFrameRate() }
        }
    }

    // MARK: Configuration (session queue)

    private func configure() throws {
        let device: AVCaptureDevice
        if let deviceID {
            guard let found = AVCaptureDevice(uniqueID: deviceID) else {
                throw CameraError.deviceNotFound(deviceID)
            }
            device = found
        } else {
            guard let found = Self.captureDevices().first else { throw CameraError.noCamera }
            device = found
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.cannotOpen(name: device.localizedName, reason: error.localizedDescription)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            throw CameraError.cannotConfigure(name: device.localizedName, reason: "the capture session rejected it as an input.")
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            // Leave the session empty so a later start() can try again from scratch.
            session.removeInput(input)
            throw CameraError.cannotConfigure(name: device.localizedName, reason: "the capture session cannot deliver its video frames.")
        }
        session.addOutput(output)

        // Hand and face landmarks need few pixels, and a small frame is cheaper to capture
        // and to analyse. 320x240 would starve the hand model, so that preset is not a fallback.
        let presets: [AVCaptureSession.Preset] = [.vga640x480, .medium]
        if let preset = presets.first(where: session.canSetSessionPreset) {
            session.sessionPreset = preset
        }

        // Vision reads these formats without a conversion pass.
        let preferredFormats = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA]
        if let format = preferredFormats.first(where: output.availableVideoPixelFormatTypes.contains) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        }
        // Analysing a stale frame is worse than skipping it.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        if let connection = output.connection(with: .video) {
            // See the orientation contract on `onFrame`: the landmark conversion mirrors the
            // coordinates itself, so the buffers must never arrive mirrored or rotated.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }

        self.device = device
    }

    private func applyFrameRate() {
        guard let device else { return }
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard let duration = Self.frameDuration(for: requestedFrameRate, in: ranges) else { return }
        let currentMin = device.activeVideoMinFrameDuration
        let currentMax = device.activeVideoMaxFrameDuration
        guard CMTimeCompare(currentMin, duration) != 0 || CMTimeCompare(currentMax, duration) != 0 else { return }

        do {
            try device.lockForConfiguration()
        } catch {
            log.error("Cannot change the camera frame rate: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { device.unlockForConfiguration() }

        // Minimum and maximum are both set to pin the rate. The order keeps min <= max at
        // every step, since an inverted pair is rejected.
        if CMTimeCompare(duration, currentMax) > 0 {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        } else {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    /// The frame duration of the supported rate nearest to `fps` (the higher one on a tie).
    ///
    /// Range ends reuse the exact durations the device reports: webcams list rates such as
    /// 30000/1001, and AVFoundation raises an Objective-C exception, which Swift cannot catch,
    /// for a duration that is not exactly inside a supported range.
    private static func frameDuration(for fps: Double, in ranges: [AVFrameRateRange]) -> CMTime? {
        var best: (distance: Double, rate: Double, duration: CMTime)?
        for range in ranges {
            let rate: Double
            let duration: CMTime
            if fps >= range.maxFrameRate {
                rate = range.maxFrameRate
                duration = range.minFrameDuration
            } else if fps <= range.minFrameRate {
                rate = range.minFrameRate
                duration = range.maxFrameDuration
            } else {
                rate = fps
                duration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
            }
            let distance = abs(rate - fps)
            if let current = best, (current.distance, -current.rate) <= (distance, -rate) { continue }
            best = (distance, rate, duration)
        }
        return best?.duration
    }
}

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    // Capture queue.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onFrame, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pixelBuffer, hostTime(of: sampleBuffer))
    }

    /// The moment the frame was captured rather than the moment it was delivered, so speeds
    /// measured between frames do not pick up delivery jitter.
    private func hostTime(of sampleBuffer: CMSampleBuffer) -> Double {
        let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard stamp.isNumeric else { return CACurrentMediaTime() }
        // Timestamps are on the session's clock, which is normally the host clock already;
        // converting makes that an invariant instead of an assumption.
        guard let clock = session.synchronizationClock else { return CMTimeGetSeconds(stamp) }
        let converted = CMSyncConvertTime(stamp, from: clock, to: CMClockGetHostTimeClock())
        return converted.isNumeric ? CMTimeGetSeconds(converted) : CACurrentMediaTime()
    }
}
