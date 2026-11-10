import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import WristFlowCore

/// One line of a gesture list: what the gesture is, what it does, and a button to try it.
struct TriggerRow: View {
    let model: AppModel
    let trigger: Trigger
    /// Width kept for the icon and name, so the action lists line up down a section.
    var nameWidth: CGFloat = 132

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                GestureIcon(trigger: trigger, library: model.library)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(model.title(for: trigger))
                    .lineLimit(1)
            }
            .frame(width: nameWidth, alignment: .leading)
            .help(trigger.hint)
            ActionEditor(model: model, trigger: trigger)
        }
    }
}

/// Chooses what a trigger does, with a way to try it.
struct ActionEditor: View {
    let model: AppModel
    let trigger: Trigger

    var body: some View {
        let binding = model.config.binding(for: trigger)
        HStack {
            BindingEditor(model: model, binding: binding) { model.setBinding($0, for: trigger) }
            Spacer(minLength: 4)
            TestButton(disabled: binding.kind == .none) { model.perform(trigger) }
        }
    }
}

/// Does something two seconds after it is clicked, which is time to switch to the app the
/// action is meant for.
struct TestButton: View {
    let disabled: Bool
    let action: () -> Void
    @State private var testing = false

    var body: some View {
        Button(testing ? "Firing…" : "Test") {
            testing = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                action()
                testing = false
            }
        }
        .disabled(testing || disabled)
        .help("Waits two seconds, then does it.")
    }
}

/// Chooses an action and whatever that action needs: the keys, the thing to open, the
/// Shortcut. The user's own actions are listed with the built-in ones unless this is a step
/// of one of them.
struct BindingEditor: View {
    let model: AppModel
    let binding: ActionBinding
    var offersCustomActions = true
    let onChange: (ActionBinding) -> Void

    private static let customPrefix = "custom:"

    /// What the list has selected: a kind by its name, or one of the user's actions by id.
    private var selection: String {
        binding.kind == .custom ? Self.customPrefix + (binding.target ?? "") : binding.kind.rawValue
    }

    private func choose(_ choice: String) {
        if choice.hasPrefix(Self.customPrefix) {
            onChange(ActionBinding(kind: .custom, target: String(choice.dropFirst(Self.customPrefix.count))))
        } else if let kind = ActionKind(rawValue: choice) {
            onChange(binding.with(kind: kind))
        }
    }

    var body: some View {
        // The selected kind stays in the list even when it cannot run here (Wispr Flow not
        // installed), otherwise the picker would show nothing for it.
        let kinds = ActionKind.allCases.filter { $0 != .custom && (model.isAvailable($0) || $0 == binding.kind) }
        let actions = offersCustomActions ? model.config.customActions : []
        HStack {
            Picker("Action", selection: Binding(get: { selection }, set: choose)) {
                ForEach(kinds) { kind in
                    Text(kind.title).tag(kind.rawValue)
                }
                if !actions.isEmpty {
                    Divider()
                    ForEach(actions) { action in
                        Text(action.name).tag(Self.customPrefix + action.id)
                    }
                }
                if binding.kind == .custom, !actions.contains(where: { $0.id == binding.target }) {
                    Text("Deleted action").tag(selection)
                }
            }
            .labelsHidden()
            .fixedSize()

            switch binding.kind {
            case .shortcut:
                ShortcutRecorder(combo: binding.combo) { onChange(ActionBinding(kind: .shortcut, combo: $0)) }
            case .open:
                OpenTargetButton(target: binding.target) {
                    onChange(ActionBinding(kind: .open, combo: binding.combo, target: $0))
                }
            case .runShortcut:
                ShortcutNamePicker(name: binding.target) {
                    onChange(ActionBinding(kind: .runShortcut, combo: binding.combo, target: $0))
                }
            default:
                EmptyView()
            }
        }
    }
}

/// Button that captures the next key combination pressed.
struct ShortcutRecorder: View {
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
        // Read from the key, not the character: with Shift held, the character of the 1 key
        // is "!", and with Control it may be none at all.
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        if let digit = digits.firstIndex(of: Int(event.keyCode)) { return String(digit) }
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

/// Chooses what an "open" action opens: an app or file picked from disk, or a link typed in.
private struct OpenTargetButton: View {
    let target: String?
    let onChoose: (String) -> Void
    @State private var enteringLink = false
    @State private var link = ""

    var body: some View {
        Menu(label) {
            Button("Choose an App or File…") { chooseFile() }
            Button("Enter a Link…") {
                link = isLink ? (target ?? "") : "https://"
                enteringLink = true
            }
        }
        .fixedSize()
        .help(target ?? "Nothing chosen yet")
        .alert("Link to open", isPresented: $enteringLink) {
            TextField("https://example.com", text: $link)
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { onChoose(trimmed) }
            }
        } message: {
            Text("A web address, or any link another app understands.")
        }
    }

    private var isLink: Bool {
        guard let target else { return false }
        return !target.hasPrefix("/") && !target.hasPrefix("~")
    }

    private var label: String {
        guard let target, !target.isEmpty else { return "Choose…" }
        if isLink { return target.count > 28 ? String(target.prefix(27)) + "…" : target }
        return FileManager.default.displayName(atPath: target)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        // The settings window belongs to an app without a Dock icon, which does not come
        // forward by itself.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { onChoose(url.path) }
    }
}

/// Chooses one of the user's Shortcuts by name.
private struct ShortcutNamePicker: View {
    let name: String?
    let onChoose: (String) -> Void
    @State private var names: [String]?

    var body: some View {
        Group {
            if let names {
                if names.isEmpty, name == nil {
                    Text("No Shortcuts found")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Shortcut", selection: Binding(get: { name ?? "" }, set: { onChoose($0) })) {
                        if name == nil { Text("Choose…").tag("") }
                        // A Shortcut that was renamed or deleted stays listed, so the row
                        // still says what it was set to.
                        if let name, !names.contains(name) { Text("\(name) (missing)").tag(name) }
                        ForEach(names, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { names = await MacActionPerformer.shortcutNames() }
    }
}
