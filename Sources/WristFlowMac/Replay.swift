import Foundation
import WristFlowCore

/// `WristFlow --replay <file> [--library <file>] [--set name=value ...]`: runs a landmark
/// recording through the gesture engine and prints what it reads and fires. `--library` loads
/// recorded gestures, combinations and a calibration (a `gestures.json`); `--set` overrides a
/// `GestureConfig` field for the run. A development tool for tuning thresholds on real gestures.
enum Replay {
    /// The default configuration with every `--set name=value` applied.
    private static func config(from arguments: [String]) -> GestureConfig {
        var fields = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(GestureConfig()))) as? [String: Any] ?? [:]
        for (index, argument) in arguments.enumerated() where argument == "--set" && index + 1 < arguments.count {
            let parts = arguments[index + 1].split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]), fields[String(parts[0])] != nil else {
                print("Ignoring --set \(arguments[index + 1]): not a number, or no such setting.")
                continue
            }
            fields[String(parts[0])] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let config = try? JSONDecoder().decode(GestureConfig.self, from: data) else { return GestureConfig() }
        return config
    }

    /// The library named by `--library`, or an empty one.
    private static func library(from arguments: [String]) -> GestureLibrary? {
        guard let flag = arguments.firstIndex(of: "--library") else { return GestureLibrary() }
        guard arguments.count > flag + 1 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[flag + 1])) else { return nil }
        return try? decoder.decode(GestureLibrary.self, from: data)
    }

    static func run(arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--replay"), arguments.count > flag + 1 else {
            print("usage: WristFlow --replay <file> [--library <file>] [--set name=value ...]")
            return 2
        }
        guard let library = library(from: arguments) else {
            print("Could not read the library.")
            return 1
        }
        let frames: [RecordedFrame]
        do {
            frames = try Recording.load(URL(fileURLWithPath: arguments[flag + 1]))
        } catch {
            print("Could not read the recording: \(error.localizedDescription)")
            return 1
        }
        guard let start = frames.first?.time else {
            print("The recording is empty.")
            return 1
        }

        // Settings given on the command line win over the ones the calibration measured.
        var engine = GestureEngine(config: library.tuned(GestureConfig()))
        engine.library = library
        if arguments.contains("--set") { engine.config = config(from: arguments) }
        func name(_ pose: Pose?) -> String {
            pose.map { library.title(for: Trigger(pose: $0)) } ?? "none"
        }
        var lastPose: Pose?
        var lastOtherPose: Pose?
        var wasVisible = false
        var handFrames = 0
        var framesWithHand = 0
        var triggers: [Trigger] = []

        var wasWithdrawn = false
        for frame in frames {
            if case .face(let face) = frame { engine.ingest(face) }
            guard case .hands(let hands) = frame else { continue }
            handFrames += 1
            if !hands.hands.isEmpty { framesWithHand += 1 }
            let trigger = engine.ingest(hands)
            let clock = String(format: "%6.2f", hands.time - start)
            let state = engine.state
            if state.handVisible != wasVisible {
                print("\(clock)  hand \(state.handVisible ? "appears" : "leaves")")
                wasVisible = state.handVisible
            }
            if state.withdrawn != wasWithdrawn {
                print("\(clock)  hand \(state.withdrawn ? "back by the head" : "held out")")
                wasWithdrawn = state.withdrawn
            }
            if state.pose != lastPose {
                print("\(clock)  pose \(name(state.pose))")
                lastPose = state.pose
            }
            if state.otherPose != lastOtherPose {
                print("\(clock)  other hand \(name(state.otherPose))")
                lastOtherPose = state.otherPose
            }
            if let trigger {
                print("\(clock)  >>> \(library.title(for: trigger))  [\(trigger.key)]")
                triggers.append(trigger)
            }
        }

        let duration = (frames.last?.time ?? start) - start
        print("")
        print("\(handFrames) frames in \(String(format: "%.1f", duration)) s, a hand in \(framesWithHand) of them")
        print("triggers: \(triggers.isEmpty ? "none" : triggers.map(\.key).joined(separator: ", "))")
        return 0
    }
}
