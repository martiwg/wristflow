import AppKit
import SwiftUI
import WristFlowCore

/// The settings window: one tab per thing the user sets up.
struct SettingsView: View {
    let model: AppModel
    /// The tab to show first; the snapshot tool renders each one.
    var initialTab = Tab.gestures
    @State private var tab: Tab?

    enum Tab: String, CaseIterable, Identifiable {
        case gestures, myGestures, combinations, actions, calibration, general

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gestures: "Gestures"
            case .myGestures: "My Gestures"
            case .combinations: "Combinations"
            case .actions: "Actions"
            case .calibration: "Calibration"
            case .general: "General"
            }
        }
    }

    var body: some View {
        let selected = tab ?? initialTab
        // A plain row of buttons instead of a `TabView`: in a window of this kind the system
        // tab bar is not always drawn, which leaves every tab but the first out of reach.
        VStack(spacing: 0) {
            Picker("Section", selection: Binding(get: { selected }, set: { tab = $0 })) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            content(of: selected)
        }
        .frame(width: 640, height: 660)
    }

    @ViewBuilder
    private func content(of tab: Tab) -> some View {
        switch tab {
        case .gestures: GesturesTab(model: model)
        case .myGestures: MyGesturesTab(model: model)
        case .combinations: CombinationsTab(model: model)
        case .actions: ActionsTab(model: model)
        case .calibration: CalibrationTab(model: model)
        case .general: GeneralTab(model: model)
        }
    }
}

/// The gestures WristFlow knows without being taught, and what each does.
private struct GesturesTab: View {
    let model: AppModel

    private static let swipes: [Trigger] = [.swipeLeft, .swipeRight, .swipeUp]

    var body: some View {
        Form {
            Section("Poses") {
                ForEach(Trigger.builtIn.filter { !Self.swipes.contains($0) }) { trigger in
                    TriggerRow(model: model, trigger: trigger)
                }
            }
            Section("Swipes") {
                ForEach(Self.swipes) { trigger in
                    TriggerRow(model: model, trigger: trigger)
                }
            }
            Section {
                Text("A pose counts when held still for a moment. A swipe is a quick flick of the open hand from the wrist. Test waits two seconds before firing, so you can switch to the app you want to try it in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Detection, gaze, permissions and the rest.
private struct GeneralTab: View {
    let model: AppModel

    var body: some View {
        Form {
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
                    Text("Wispr Flow is not installed. Its actions are left out of the lists, and a gesture already set to one does nothing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
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
