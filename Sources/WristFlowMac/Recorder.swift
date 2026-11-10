import AVFoundation
import Foundation
import WristFlowCore

/// Development tool: records what the landmarker sees to a file, to use as a test fixture.
/// Only landmarks are written, never images.
///
///     WristFlow --record-landmarks <file> [seconds]
enum Recorder {
    private static let flag = "--record-landmarks"
    private static let defaultDuration = 10.0
    /// A Continuity or USB camera can take several seconds to deliver its first frame.
    private static let cameraStartTimeout = 10.0

    /// Runs the recording and returns the process exit code. Call it on the main thread: it
    /// keeps the main run loop turning until the recording ends.
    static func run(arguments: [String]) -> Int32 {
        guard let options = parse(arguments) else {
            printError("Usage: WristFlow \(flag) <file> [seconds]   (default \(Int(defaultDuration)) s)")
            return 2
        }
        guard ensureCameraAccess() else { return 1 }

        let sink: Sink
        do {
            sink = try Sink(url: options.url)
        } catch {
            printError("Cannot write to \(options.url.path): \(error.localizedDescription)")
            return 1
        }

        let landmarker = VisionLandmarker(cameraID: nil)
        // Both run on the landmarker's analysis task, one frame at a time.
        landmarker.onHands = { sink.record(.hands($0)) }
        landmarker.onFace = { sink.record(.face($0)) }
        do {
            try landmarker.start()
        } catch {
            sink.finish()
            printError(error.localizedDescription)
            return 1
        }

        print("Waiting for the camera...")
        let startDeadline = now() + cameraStartTimeout
        while sink.snapshot().frames == 0 {
            guard now() < startDeadline else {
                landmarker.stop()
                sink.finish()
                printError("The camera delivered no frames within \(Int(cameraStartTimeout)) s.")
                return 1
            }
            pump(0.05)
        }

        print("Recording landmarks for \(format(options.duration)) s to \(options.url.path) (landmarks only, no images).")
        // Timed from the first frame so camera start-up does not eat into the recording.
        let begin = now()
        var nextReport = 1.0
        while now() - begin < options.duration {
            pump(0.05)
            let elapsed = now() - begin
            if elapsed >= nextReport {
                let stats = sink.snapshot()
                print("  \(Int(nextReport)) s: frames \(stats.frames), with hands \(stats.framesWithHands), faces \(stats.faces)")
                nextReport += 1
            }
        }

        landmarker.stop()
        let stats = sink.finish()
        if let failure = stats.writeFailure {
            printError("Writing the recording failed: \(failure)")
            return 1
        }

        print("Done: \(stats.frames) frames (\(stats.framesWithHands) with hands, \(stats.handsSeen) hands in total), \(stats.faces) faces.")
        print("Measured rate: \(rate(count: stats.frames, first: stats.firstFrameTime, last: stats.lastFrameTime)) frames/s, \(rate(count: stats.faces, first: stats.firstFaceTime, last: stats.lastFaceTime)) faces/s.")
        let vision = landmarker.statistics
        let handMs = vision.framesAnalysed > 0 ? vision.handSeconds / Double(vision.framesAnalysed) * 1000 : 0
        let faceMs = vision.faceRuns > 0 ? vision.faceSeconds / Double(vision.faceRuns) * 1000 : 0
        print("Camera delivered \(vision.framesReceived) frames, \(vision.framesAnalysed) analysed. Vision took \(format(handMs)) ms per hand pass and \(format(faceMs)) ms per face pass.")
        print("Saved \(options.url.path)")
        return 0
    }

    // MARK: Arguments

    private struct Options {
        var url: URL
        var duration: Double
    }

    /// Accepts the arguments with or without the program name in front.
    private static func parse(_ arguments: [String]) -> Options? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let values = arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }
        guard let path = values.first, values.count <= 2 else { return nil }
        var duration = defaultDuration
        if values.count == 2 {
            guard let seconds = Double(values[values.startIndex + 1]), seconds.isFinite, seconds > 0 else { return nil }
            duration = seconds
        }
        return Options(url: URL(fileURLWithPath: path), duration: duration)
    }

    // MARK: Camera access

    private static func ensureCameraAccess() -> Bool {
        switch CameraSource.authorization {
        case .authorized:
            return true
        case .notDetermined:
            print("Asking for camera access...")
            let answer = Answer()
            Task.detached { answer.set(await CameraSource.requestAccess()) }
            // The run loop keeps turning while the system prompt is on screen.
            while answer.value == nil { pump(0.05) }
            if answer.value == true { return true }
            printError("Camera access was not granted, so nothing can be recorded.")
            return false
        case .restricted:
            printError(CameraError.accessRestricted.localizedDescription)
            return false
        case .denied:
            printError(CameraError.accessDenied.localizedDescription)
            return false
        @unknown default:
            printError(CameraError.accessDenied.localizedDescription)
            return false
        }
    }

    /// The reply to the access prompt, handed from the task that awaits it to the main thread.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var granted: Bool?

        var value: Bool? { lock.withLock { granted } }
        func set(_ newValue: Bool) { lock.withLock { granted = newValue } }
    }

    // MARK: Output file

    private struct Stats {
        var frames = 0
        var framesWithHands = 0
        var handsSeen = 0
        var faces = 0
        var firstFrameTime: Double?
        var lastFrameTime: Double?
        var firstFaceTime: Double?
        var lastFaceTime: Double?
        var writeFailure: String?
    }

    /// Appends frames to the file and counts them. Written to from the landmarker's task and
    /// read from the main thread, hence the lock.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private let file: FileHandle
        private var stats = Stats()
        private var closed = false

        init(url: URL) throws {
            try Data().write(to: url)
            file = try FileHandle(forWritingTo: url)
        }

        func record(_ frame: RecordedFrame) {
            lock.withLock {
                // A frame still in flight when the recording ends is dropped, and after a
                // failed write the file is left as it is rather than given a gap.
                guard !closed, stats.writeFailure == nil else { return }
                do {
                    let line = try Recording.encodeLine(frame)
                    try file.write(contentsOf: Data((line + "\n").utf8))
                } catch {
                    stats.writeFailure = error.localizedDescription
                    return
                }
                switch frame {
                case .hands(let hands):
                    stats.frames += 1
                    stats.handsSeen += hands.hands.count
                    if !hands.hands.isEmpty { stats.framesWithHands += 1 }
                    if stats.firstFrameTime == nil { stats.firstFrameTime = hands.time }
                    stats.lastFrameTime = hands.time
                case .face(let face):
                    stats.faces += 1
                    if stats.firstFaceTime == nil { stats.firstFaceTime = face.time }
                    stats.lastFaceTime = face.time
                }
            }
        }

        func snapshot() -> Stats {
            lock.withLock { stats }
        }

        @discardableResult
        func finish() -> Stats {
            lock.withLock {
                if !closed {
                    closed = true
                    do {
                        try file.close()
                    } catch {
                        // The first failure is the one worth reporting.
                        if stats.writeFailure == nil { stats.writeFailure = error.localizedDescription }
                    }
                }
                return stats
            }
        }
    }

    // MARK: Helpers

    private static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    /// Turns the main run loop for a moment. A run loop with nothing attached returns at once,
    /// so the remainder is slept to avoid spinning a core.
    private static func pump(_ seconds: Double) {
        let until = Date(timeIntervalSinceNow: seconds)
        if !RunLoop.current.run(mode: .default, before: until) {
            Thread.sleep(until: until)
        }
    }

    /// Events per second over the span between the first and the last one.
    private static func rate(count: Int, first: Double?, last: Double?) -> String {
        guard count > 1, let first, let last, last > first else { return "0.0" }
        return format(Double(count - 1) / (last - first))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
