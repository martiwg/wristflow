import AppKit
import SwiftUI
import WristFlowCore

struct MenuContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(model.config.enabled ? Color.accentColor : Color.secondary)
                Text("WristFlow").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { model.config.enabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            statusBlock

            if let report = model.lastTrigger {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("\(report.trigger.glyph) \(report.trigger.title) → \(report.binding.summary) · \(report.date.formatted(.relative(presentation: .numeric)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            VStack(spacing: 2) {
                MenuRow(title: "Camera Preview…", symbol: "video") {
                    open("preview")
                }
                if hasSeveralDisplays {
                    MenuRow(title: "Calibrate Gaze…", symbol: "eye") {
                        GazeCalibrationController.shared.begin(model: model)
                    }
                }
                MenuRow(title: "Settings…", symbol: "gearshape") {
                    open("settings")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if hasSeveralDisplays {
                    Toggle("Follow my gaze between displays", isOn: Binding(
                        get: { model.config.gazeFocusEnabled },
                        set: { model.setGazeFocusEnabled($0) }
                    ))
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 6)

            Divider()

            MenuRow(title: "Quit WristFlow", symbol: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var hasSeveralDisplays: Bool {
        model.gazeHealth != .singleDisplay
    }

    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.config.enabled {
                cameraStatus
            } else {
                Text("Camera is off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.accessibilityGranted {
                StatusLine(
                    color: .orange,
                    title: "Accessibility access needed",
                    detail: "Without it WristFlow cannot press shortcuts or switch windows."
                )
                Button("Grant Accessibility…") { model.requestAccessibility() }
                    .controlSize(.small)
            }

            // Gaze needs the camera: while it is off or failing, a gaze line would only add
            // a second complaint, or a green light for something that is not happening.
            if model.camera == .running {
                gazeStatus
            }
        }
    }

    @ViewBuilder
    private var cameraStatus: some View {
        switch model.camera {
        case .denied:
            StatusLine(color: .red, title: "Camera access needed", detail: "WristFlow sees your gestures through the camera.")
            Button("Open Camera Settings…") { model.openCameraSettings() }
                .controlSize(.small)
        case .failed(let message):
            StatusLine(color: .red, title: "Camera problem", detail: message)
        case .starting:
            StatusLine(color: .secondary, title: "Starting camera…", detail: nil)
        case .running:
            StatusLine(color: .green, title: "Watching for gestures", detail: model.activeCamera?.name)
        case .stopped:
            // Enabled but stopped only happens while the screen is locked or asleep.
            EmptyView()
        }
    }

    @ViewBuilder
    private var gazeStatus: some View {
        if model.gazeHealth == .singleDisplay {
            EmptyView()
        } else if !model.config.gazeFocusEnabled {
            // Switched off on purpose, so a missing calibration is not a problem to report.
            StatusLine(color: .secondary, title: "Gaze focus off", detail: nil)
        } else {
            switch model.gazeHealth {
            case .singleDisplay:
                EmptyView()
            case .notCalibrated:
                StatusLine(color: .orange, title: "Gaze not calibrated", detail: nil)
            case .displaysChanged:
                StatusLine(color: .orange, title: "Displays changed", detail: "Calibrate gaze for this setup.")
            case .ready:
                StatusLine(
                    color: .green,
                    title: "Gaze focus on",
                    detail: model.displayName(model.lookingAt).map { "Looking at \($0)" }
                )
            }
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        // A menu bar app is not the active app, so its new window would open behind the others.
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct StatusLine: View {
    let color: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
