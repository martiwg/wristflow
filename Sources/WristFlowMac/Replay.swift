import Foundation
import WristFlowCore

/// `WristFlow --replay <file> [--set name=value ...]`: runs a landmark recording through the
/// gesture engine and prints what it reads and fires. `--set` overrides a `GestureConfig`
/// field for the run. A development tool for tuning thresholds on real gestures.
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

    static func run(arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--replay"), arguments.count > flag + 1 else {
            print("usage: WristFlow --replay <file>")
            return 2
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

        var engine = GestureEngine(config: config(from: arguments))
        var lastPose: Pose?
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
                print("\(clock)  pose \(state.pose?.rawValue ?? "none")")
                lastPose = state.pose
            }
            if let trigger {
                print("\(clock)  >>> \(trigger.rawValue)")
                triggers.append(trigger)
            }
        }

        let duration = (frames.last?.time ?? start) - start
        print("")
        print("\(handFrames) frames in \(String(format: "%.1f", duration)) s, a hand in \(framesWithHand) of them")
        print("triggers: \(triggers.isEmpty ? "none" : triggers.map(\.rawValue).joined(separator: ", "))")
        return 0
    }
}
