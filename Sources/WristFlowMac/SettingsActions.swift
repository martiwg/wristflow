import SwiftUI
import WristFlowCore

/// Actions the user puts together: a name and one or more steps done in order. Once made,
/// an action can be chosen for any gesture, recorded gesture or combination.
struct ActionsTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Text("Put together actions of your own: one key combination, or several things done one after the other. They then appear in the list of every gesture, next to the built-in actions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.config.customActions.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Text("⚡️")
                            .font(.system(size: 34))
                            .accessibilityHidden(true)
                        Text("No actions of your own yet")
                            .font(.headline)
                        Text("For example: Control-Tab to go to the next pane of an app.")
                            .foregroundStyle(.secondary)
                        Button("New Action") { add() }
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
            } else {
                ForEach(model.config.customActions) { action in
                    Section {
                        rows(for: action)
                    }
                }
                Section {
                    Button("New Action") { add() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func rows(for action: CustomAction) -> some View {
        HStack {
            NameField(name: action.name) { name in
                var changed = action
                changed.name = name
                model.saveAction(changed)
            }
            Spacer(minLength: 4)
            TestButton(disabled: model.config.steps(of: action.binding).isEmpty) { model.run(action.binding) }
            Button {
                model.deleteAction(id: action.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this action. Gestures set to it go back to doing nothing.")
            .accessibilityLabel("Delete action")
        }

        ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
            HStack {
                Text("\(index + 1).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .leading)
                BindingEditor(model: model, binding: step, offersCustomActions: false) { binding in
                    var changed = action
                    changed.steps[index] = binding
                    model.saveAction(changed)
                }
                Spacer(minLength: 4)
                Button {
                    var changed = action
                    changed.steps.remove(at: index)
                    model.saveAction(changed)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(action.steps.count <= 1)
                .help("Remove this step")
                .accessibilityLabel("Remove step \(index + 1)")
            }
        }

        Button("Add Step") {
            var changed = action
            changed.steps.append(ActionBinding(kind: .shortcut))
            model.saveAction(changed)
        }
        .buttonStyle(.borderless)
    }

    private func add() {
        let taken = Set(model.config.customActions.map(\.name))
        var number = model.config.customActions.count + 1
        while taken.contains("My action \(number)") { number += 1 }
        model.saveAction(CustomAction(name: "My action \(number)", steps: [ActionBinding(kind: .shortcut)]))
    }
}
