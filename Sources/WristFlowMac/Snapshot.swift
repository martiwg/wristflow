import AppKit
import SwiftUI

/// `WristFlow --snapshot <folder>`: renders the app's views to PNG files and quits. A
/// development tool for checking layouts without clicking through the app. The camera stays off.
@MainActor
enum Snapshot {
    static var folder: URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    static func run(model: AppModel, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        write(MenuContentView(model: model), named: "menu", in: folder)
        for tab in SettingsView.Tab.allCases {
            write(SettingsView(model: model, initialTab: tab), named: "settings-\(tab.rawValue)", in: folder)
        }
        write(PreviewView(model: model), named: "preview", in: folder)

        let naming = TrainingSession(flow: .newGesture, model: model, live: false)
        write(TrainingView(session: naming, model: model, onClose: {}), named: "training-new-gesture", in: folder)
        let showing = TrainingSession(flow: .newGesture, model: model, live: false)
        showing.show(.shape(.right), hint: "Hold it there", takesDone: 1, progress: 0.6)
        write(TrainingView(session: showing, model: model, onClose: {}), named: "training-shape", in: folder)
        let fitting = TrainingSession(flow: .calibration, model: model, live: false)
        write(TrainingView(session: fitting, model: model, onClose: {}), named: "training-calibration", in: folder)
        let stepping = TrainingSession(flow: .calibration, model: model, live: false)
        stepping.show(.calibrate(4), hint: "Show your right hand to the camera", takesDone: 0, progress: 0)
        write(TrainingView(session: stepping, model: model, onClose: {}), named: "training-calibration-step", in: folder)
        NSApp.terminate(nil)
    }

    private static func write(_ view: some View, named name: String, in folder: URL) {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: folder.appendingPathComponent("\(name).png"))
    }
}
