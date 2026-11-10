import AppKit
import SwiftUI

struct WristFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("WristFlow Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultLaunchBehavior(Self.launchBehavior(for: "settings"))
        .windowResizability(.contentSize)

        Window("WristFlow Camera Preview", id: "preview") {
            PreviewView(model: model)
        }
        .defaultLaunchBehavior(Self.launchBehavior(for: "preview"))
        .windowResizability(.contentSize)
    }

    /// `--show settings` or `--show preview` opens that window at launch (for development).
    private static func launchBehavior(for id: String) -> SceneLaunchBehavior {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--show"), arguments.count > flag + 1, arguments[flag + 1] == id {
            return .presented
        }
        return .suppressed
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies (a build and the installed app) would both react to every gesture.
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !bundleID.isEmpty, !others.isEmpty {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        if let folder = Snapshot.folder {
            // Snapshots show the views as they are; they must not turn the camera on.
            Task { await Snapshot.run(model: AppModel.shared, into: folder) }
        } else {
            AppModel.shared.start()
        }
    }
}
