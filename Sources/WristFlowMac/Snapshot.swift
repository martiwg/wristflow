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
        write(SettingsView(model: model), named: "settings", in: folder)
        write(PreviewView(model: model), named: "preview", in: folder)
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
