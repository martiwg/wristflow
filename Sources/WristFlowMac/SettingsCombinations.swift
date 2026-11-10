import SwiftUI
import WristFlowCore

/// Where the user sets up combinations: one pose on each hand, held at the same time.
struct CombinationsTab: View {
    let model: AppModel
    /// Id of the combination whose last change was refused because another one already uses
    /// the same two poses.
    @State private var refused: String?

    var body: some View {
        Form {
            Section {
                Text("A combination is one pose on each hand, held still at the same time. Add the ones you want and choose what each does.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.library.combinations.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Text("🙌")
                            .font(.system(size: 34))
                            .accessibilityHidden(true)
                        Text("No combinations yet")
                            .font(.headline)
                        Text("For example: a fist on one hand and one finger on the other.")
                            .foregroundStyle(.secondary)
                        Button("Add Combination") { add() }
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
            } else {
                ForEach(model.library.combinations) { combination in
                    Section {
                        row(for: combination)
                    }
                }
                Section {
                    Button("Add Combination") { add() }
                        .disabled(freePair() == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: One combination

    @ViewBuilder
    private func row(for combination: Combination) -> some View {
        HStack {
            handPicker(combination.eitherWay ? "One hand" : "Left hand", selection: combination.left) { pose in
                var changed = combination
                changed.left = pose
                save(changed)
            }
            Text("+")
                .foregroundStyle(.secondary)
            handPicker(combination.eitherWay ? "Other hand" : "Right hand", selection: combination.right) { pose in
                var changed = combination
                changed.right = pose
                save(changed)
            }
            Spacer(minLength: 4)
            Button {
                model.deleteCombination(id: combination.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this combination")
            .accessibilityLabel("Delete combination")
        }

        Toggle("Either hand may show either pose", isOn: Binding(
            get: { combination.eitherWay },
            set: { value in
                var changed = combination
                changed.eitherWay = value
                save(changed)
            }
        ))

        HStack {
            Text("Does")
                .foregroundStyle(.secondary)
            ActionEditor(model: model, trigger: combination.trigger)
        }

        if refused == combination.id {
            Label("Another combination already uses these two poses.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if let note = soloNote(for: combination) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handPicker(_ label: String, selection: Trigger, onChange: @escaping (Trigger) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(label, selection: Binding(get: { selection }, set: onChange)) {
                ForEach(model.library.poseTriggers) { pose in
                    Text("\(pose.glyph)  \(model.title(for: pose))").tag(pose)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Says which of the two poses also do something alone, because those now wait a moment
    /// longer before they fire by themselves.
    private func soloNote(for combination: Combination) -> String? {
        let poses = combination.left == combination.right ? [combination.left] : [combination.left, combination.right]
        let acting = poses.filter { model.config.binding(for: $0).kind != .none }.map { model.title(for: $0) }
        guard !acting.isEmpty else { return nil }
        let names = acting.joined(separator: " and ")
        let verb = acting.count == 1 ? "also does something" : "also do something"
        return "\(names) \(verb) alone. Shown alone, hold a moment longer; with both hands up, only the combination fires."
    }

    // MARK: Changes

    private func save(_ combination: Combination) {
        refused = model.saveCombination(combination) ? nil : combination.id
    }

    private func add() {
        guard let pair = freePair() else { return }
        refused = nil
        model.saveCombination(Combination(left: pair.left, right: pair.right))
    }

    /// The first two poses no combination uses yet, starting with two fists.
    private func freePair() -> (left: Trigger, right: Trigger)? {
        let poses = model.library.poseTriggers
        let ordered = [Trigger.fist] + poses.filter { $0 != .fist }
        for left in ordered {
            for right in ordered where model.library.clash(for: Combination(id: "", left: left, right: right)) == nil {
                return (left, right)
            }
        }
        return nil
    }
}
