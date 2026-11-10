import Foundation
import WristFlowCore

/// `WristFlow --replay <file>`: runs a landmark recording through the gesture engine and prints
/// what it reads and fires. A development tool for tuning thresholds on real gestures.
enum Replay {
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

        var engine = GestureEngine()
        var lastPose: Pose?
        var wasVisible = false
        var handFrames = 0
        var framesWithHand = 0
        var triggers: [Trigger] = []

        var wasAtFace = false
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
            if state.atFace != wasAtFace {
                print("\(clock)  hand \(state.atFace ? "at the face" : "away from the face")")
                wasAtFace = state.atFace
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
