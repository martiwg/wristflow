import SwiftUI
import WristFlowCore

/// The gestures the user recorded: what each does, and the way to record more.
struct MyGesturesTab: View {
    let model: AppModel
    /// The gesture the user asked to delete, until they confirm.
    @State private var deleting: CustomGesture?

    var body: some View {
        Form {
            Section {
                Text("Teach WristFlow gestures of your own: a hand shape you hold, or a movement you make. They are recorded with your hands and kept with your account on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.library.customGestures.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Text("🤘")
                            .font(.system(size: 34))
                            .accessibilityHidden(true)
                        Text("No gestures of your own yet")
                            .font(.headline)
                        Text("Recording one takes about a minute.")
                            .foregroundStyle(.secondary)
                        Button("New Gesture…") { TrainingController.shared.begin(.newGesture, model: model) }
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
            } else {
                ForEach(model.library.customGestures) { gesture in
                    Section {
                        row(for: gesture)
                    }
                }
                Section {
                    Button("New Gesture…") { TrainingController.shared.begin(.newGesture, model: model) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { gesture in
            Button("Delete", role: .destructive) { model.deleteGesture(id: gesture.id) }
        } message: { gesture in
            Text(deletionWarning(for: gesture))
        }
    }

    @ViewBuilder
    private func row(for gesture: CustomGesture) -> some View {
        HStack(spacing: 12) {
            GestureIcon(trigger: gesture.trigger, library: model.library, size: 38)
                .frame(width: 46, height: 46)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                NameField(name: gesture.name) { model.renameGesture(id: gesture.id, to: $0) }
                Text(kind(of: gesture))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Record Again…") { TrainingController.shared.begin(.rerecord(gesture), model: model) }
            Button {
                deleting = gesture
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this gesture")
            .accessibilityLabel("Delete gesture")
        }

        HStack {
            Text("Does")
                .foregroundStyle(.secondary)
            ActionEditor(model: model, trigger: gesture.trigger)
        }
    }

    private func kind(of gesture: CustomGesture) -> String {
        guard let movement = gesture.movement else { return "Hand shape, held still" }
        guard let key = movement.startPose, let start = Trigger(key: key) else { return "Movement" }
        return "Movement, starting from \(model.title(for: start).lowercased())"
    }

    private func deletionWarning(for gesture: CustomGesture) -> String {
        let used = model.library.combinations.filter { $0.left == gesture.trigger || $0.right == gesture.trigger }
        if used.isEmpty { return "Its recording is deleted. This cannot be undone." }
        let count = used.count == 1 ? "The combination" : "The \(used.count) combinations"
        return "Its recording is deleted. \(count) that use it go with it. This cannot be undone."
    }
}

/// A name that is saved when the user is done typing, not on every key.
private struct NameField: View {
    let name: String
    let onRename: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.body.weight(.medium))
            .focused($focused)
            .onAppear { text = name }
            .onChange(of: name) { _, value in text = value }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .accessibilityLabel("Gesture name")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text = name
        } else if trimmed != name {
            onRename(trimmed)
        }
    }
}

/// Fitting the built-in gestures to the user's hands, and going back.
struct CalibrationTab: View {
    let model: AppModel
    @State private var resetting = false

    var body: some View {
        Form {
            Section {
                Text("The built-in gestures were tuned on one person's hands. A calibration fits them to yours: how far your fingers reach when they are up or folded, how large your hand looks next to your face, how fast you swipe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button(model.library.calibration == nil ? "Calibrate…" : "Calibrate Again…") {
                        TrainingController.shared.begin(.calibration, model: model)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status)
                        Text("About two minutes with each hand in front of the camera.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.library.calibration != nil {
                    LabeledContent("Standard settings") {
                        Button("Go Back…") { resetting = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Go back to the standard settings?", isPresented: $resetting) {
            Button("Go Back", role: .destructive) { model.setCalibration(nil) }
        } message: {
            Text("Your calibration is deleted. Your own gestures and combinations stay.")
        }
    }

    private var status: String {
        guard let calibration = model.library.calibration else { return "Using the standard settings" }
        return "Calibrated to your hands on \(calibration.createdAt.formatted(date: .abbreviated, time: .omitted))"
    }
}
