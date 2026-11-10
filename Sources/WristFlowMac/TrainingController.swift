import AppKit
import SwiftUI
import WristFlowCore

/// Opens the window of a guided flow and gives the camera back when it closes.
@MainActor
final class TrainingController: NSObject, NSWindowDelegate {
    static let shared = TrainingController()

    private var window: NSWindow?
    private var session: TrainingSession?

    /// Starts a flow, or brings the one in progress to the front: there is one camera, so
    /// one flow at a time.
    func begin(_ flow: TrainingSession.Flow, model: AppModel) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let session = TrainingSession(flow: flow, model: model)
        let view = TrainingView(session: session, model: model) { [weak self] in self?.end() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = TrainingView.title(of: flow)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.session = session

        session.attach()
        // An app without a Dock icon does not come forward by itself.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func end() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        session?.detach()
        session = nil
        window?.delegate = nil
        let closing = window
        window = nil
        // The click that closed the window is still being handled by a view inside it.
        DispatchQueue.main.async { _ = closing }
    }
}
