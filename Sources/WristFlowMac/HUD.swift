import AppKit
import SwiftUI
import WristFlowCore

extension Trigger {
    /// A character that pictures the gesture.
    var glyph: String {
        switch self {
        case .palm: "✋"
        case .palmBack: "🤚"
        case .fist: "✊"
        case .ok: "👌"
        case .swipeLeft: "←"
        case .swipeRight: "→"
        case .swipeUp: "↑"
        }
    }
}

/// A brief on-screen confirmation that a gesture was recognised. Without it the user cannot
/// tell a gesture that was not seen from an action that did nothing visible.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hiding: Task<Void, Never>?

    func show(trigger: Trigger, binding: ActionBinding) {
        let content = NSHostingView(rootView: HUDView(glyph: trigger.glyph, text: binding.summary))
        content.frame = CGRect(origin: .zero, size: content.fittingSize)

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = content
        panel.setContentSize(content.frame.size)

        // On the display the pointer is on: with gaze focus that is the one being looked at.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: visible.midX - content.frame.width / 2,
                y: visible.minY + visible.height * 0.14
            ))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    if panel.alphaValue == 0 { panel.orderOut(nil) }
                }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        // Never takes clicks or focus, and shows over full-screen apps too.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct HUDView: View {
    let glyph: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(glyph).font(.system(size: 26, weight: .semibold))
            Text(text).font(.system(size: 15, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
