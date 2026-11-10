import AppKit
import Carbon.HIToolbox
import SwiftUI
import WristFlowCore

struct SettingsView: View {
    let model: AppModel
    @State private var testing: Trigger?

    var body: some View {
        Form {
            Section("Gestures") {
                ForEach(Trigger.allCases) { trigger in
                    row(for: trigger)
                }
            }

            Section {
                Text("Test waits two seconds before firing, so you can switch to the app you want to try it in. Poses must be held still for a moment. A swipe is a quick flick of the open hand from the wrist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Detection") {
                LabeledContent("Hold a pose for") {
                    SecondsSlider(value: model.config.holdTime, range: 0.2...1.0) { model.setHoldTime($0) }
                }
                Picker("Camera", selection: Binding(get: { model.config.cameraID }, set: { model.setCamera(id: $0) })) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(String?.some(camera.id))
                    }
                    // Without an entry for it, an unplugged camera would leave the picker blank.
                    if let id = model.config.cameraID, !model.cameras.contains(where: { $0.id == id }) {
                        Text("Chosen camera (not connected)").tag(String?.some(id))
                    }
                }
                Toggle("Show a confirmation on screen", isOn: Binding(get: { model.config.showsHUD }, set: { model.setShowsHUD($0) }))
                Toggle("Play a sound", isOn: Binding(get: { model.config.playsSound }, set: { model.setPlaysSound($0) }))
            }

            Section("Gaze") {
                gazeRows
            }

            Section("Permissions") {
                LabeledContent("Camera") {
                    if model.camera == .denied {
                        Button("Open Camera Settings…") { model.openCameraSettings() }
                    } else {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") { model.requestAccessibility() }
                    }
                }
                if !model.isAvailable(.wisprToggle) {
                    Text("Wispr Flow is not installed. Its action is left out of the lists above, and a gesture already set to it does nothing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
    }

    // MARK: Gestures

    private func row(for trigger: Trigger) -> some View {
        let binding = model.config.binding(for: trigger)
        // The selected kind stays in the list even when it cannot run here (Wispr Flow not
        // installed), otherwise the picker would show nothing for it.
        let kinds = ActionKind.allCases.filter { model.isAvailable($0) || $0 == binding.kind }
        return HStack {
            HStack(spacing: 6) {
                Text(trigger.glyph)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(trigger.title)
            }
            .frame(width: 112, alignment: .leading)
            .help(trigger.hint)
            Picker(trigger.title, selection: Binding(
                get: { binding.kind },
                set: { model.setBinding(ActionBinding(kind: $0, combo: binding.combo), for: trigger) }
            )) {
                ForEach(kinds) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            if binding.kind == .shortcut {
                ShortcutRecorder(combo: binding.combo) { combo in
                    model.setBinding(ActionBinding(kind: .shortcut, combo: combo), for: trigger)
                }
            }
            Spacer(minLength: 4)
            Button(testing == trigger ? "Firing…" : "Test") {
                testing = trigger
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    model.perform(trigger)
                    testing = nil
                }
            }
            .disabled(testing != nil || binding.kind == .none)
        }
    }

    // MARK: Gaze

    @ViewBuilder
    private var gazeRows: some View {
        if model.gazeHealth == .singleDisplay {
            Text("Connect a second display to use gaze focus.")
                .foregroundStyle(.secondary)
        } else {
            Toggle("Follow my gaze between displays", isOn: Binding(
                get: { model.config.gazeFocusEnabled },
                set: { model.setGazeFocusEnabled($0) }
            ))
            LabeledContent("Move focus after looking for") {
                SecondsSlider(value: model.config.gazeDwell, range: 0.3...1.5) { model.setGazeDwell($0) }
            }
            LabeledContent {
                Button(isCalibrated ? "Recalibrate…" : "Calibrate…") {
                    GazeCalibrationController.shared.begin(model: model)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(calibrationStatus)
                    if let advice = calibrationAdvice {
                        Text(advice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var isCalibrated: Bool {
        if case .ready = model.gazeHealth { return true }
        return false
    }

    private var calibrationStatus: String {
        switch model.gazeHealth {
        case .singleDisplay: ""
        case .notCalibrated: "Not calibrated"
        case .displaysChanged: "Displays changed since the last calibration"
        case .ready(let accuracy): "Calibrated · \(Int((accuracy * 100).rounded()))% in self-test"
        }
    }

    private var calibrationAdvice: String? {
        if case .ready(let accuracy) = model.gazeHealth, accuracy < 0.7 {
            return "Try calibrating again, sitting as you normally do."
        }
        return nil
    }
}

/// A slider for a duration, with the value written next to it.
private struct SecondsSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    var body: some View {
        HStack {
            Slider(value: Binding(get: { value }, set: { raw in
                // The model writes the settings file on every change. Snapping to 0.05 s turns
                // a drag into a handful of saves instead of one per pixel.
                let snapped = (raw * 20).rounded() / 20
                if snapped != value { onChange(snapped) }
            }), in: range)
                .frame(width: 180)
            Text("\(value.formatted(.number.precision(.fractionLength(1...2)))) s")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// Button that captures the next key combination pressed.
private struct ShortcutRecorder: View {
    let combo: KeyCombo?
    let onRecord: (KeyCombo) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : (combo?.label ?? "Record…")) {
            recording ? stop() : start()
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            onRecord(Self.combo(from: event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Modifiers are stored as `CGEventFlags` bits because that is what posting the key press
    /// later takes.
    private static func combo(from event: NSEvent) -> KeyCombo {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var flags = CGEventFlags()
        var label = ""
        if modifiers.contains(.control) { flags.insert(.maskControl); label += "⌃" }
        if modifiers.contains(.option) { flags.insert(.maskAlternate); label += "⌥" }
        if modifiers.contains(.shift) { flags.insert(.maskShift); label += "⇧" }
        if modifiers.contains(.command) { flags.insert(.maskCommand); label += "⌘" }
        label += keyName(event)
        return KeyCombo(keyCode: event.keyCode, modifiers: flags.rawValue, label: label)
    }

    private static func keyName(_ event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Space: "Space", kVK_Tab: "⇥", kVK_Return: "↩", kVK_Delete: "⌫",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }
}
