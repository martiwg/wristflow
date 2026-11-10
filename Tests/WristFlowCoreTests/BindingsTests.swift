import Foundation
import Testing
@testable import WristFlowCore

@Test func configFromAnOlderFileKeepsDefaults() throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"holdTime": 0.6}"#.utf8))
    #expect(config.holdTime == 0.6)
    #expect(config.enabled)
    #expect(config.binding(for: .palm).kind == .wisprToggle)
}

@Test func triggersHaveDefaultsExceptTheFingerCounts() {
    let config = AppConfig()
    // The counts are there to be given a meaning by the user.
    let counts: Set<Trigger> = [.oneFinger, .twoFingers, .threeFingers, .fourFingers]
    for trigger in Trigger.builtIn {
        #expect((config.binding(for: trigger).kind == .none) == counts.contains(trigger))
    }
    #expect(config.binding(for: .thumbsUp).kind == .pressReturn)
}

@Test func aTriggerMissingFromAnOlderFileGetsItsDefault() throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"bindings": {"palm": {"kind": "none"}}}"#.utf8))
    #expect(config.binding(for: .palm).kind == .none)
    #expect(config.binding(for: .palmBack).kind == .wisprCancel)
}

@Test func fingersCoverEveryJointExceptTheWrist() {
    let joints = Finger.allCases.flatMap(\.joints)
    #expect(joints.count == 20)
    #expect(Set(joints).count == 20)
    #expect(!joints.contains(.wrist))
    #expect(Finger.little.tip == .littleTip)
}

// MARK: - Triggers the user makes

@Test func everyTriggerSurvivesItsKey() throws {
    let triggers = Trigger.builtIn + [.custom("A1"), .combination("B2")]
    for trigger in triggers {
        #expect(Trigger(key: trigger.key) == trigger)
    }
    #expect(Set(triggers.map(\.key)).count == triggers.count)
    #expect(Trigger(key: "custom:") == nil)
    #expect(Trigger(key: "nonsense") == nil)

    let data = try JSONEncoder().encode(triggers)
    #expect(try JSONDecoder().decode([Trigger].self, from: data) == triggers)
    // Built-in triggers are written the way they always were.
    #expect(String(decoding: try JSONEncoder().encode([Trigger.palm]), as: UTF8.self) == #"["palm"]"#)
}

@Test func aBindingWrittenBeforeTargetsExistedStillLoads() throws {
    let binding = try JSONDecoder().decode(ActionBinding.self, from: Data(#"{"kind": "shortcut"}"#.utf8))
    #expect(binding.kind == .shortcut)
    #expect(binding.target == nil)
    #expect(ActionBinding(kind: .open, target: "/Applications/Notes.app").summary == "Open Notes")
    #expect(ActionBinding(kind: .runShortcut, target: "Focus").summary == "Shortcut: Focus")
}

@Test func combinationsKnowWhichHandsMakeThem() {
    let strict = Combination(id: "s", left: .fist, right: .oneFinger, eitherWay: false)
    #expect(strict.isMade(left: .fist, right: .one))
    #expect(!strict.isMade(left: .one, right: .fist))
    let lenient = Combination(id: "l", left: .fist, right: .oneFinger, eitherWay: true)
    #expect(lenient.isMade(left: .one, right: .fist))
    #expect(!lenient.isMade(left: .fist, right: .two))

    // The same two poses on the same hands cannot mean two things.
    #expect(strict.overlaps(lenient))
    let mirrored = Combination(id: "m", left: .oneFinger, right: .fist, eitherWay: false)
    #expect(!strict.overlaps(mirrored))
    #expect(lenient.overlaps(mirrored))
    #expect(!strict.overlaps(Combination(id: "o", left: .fist, right: .twoFingers)))
}

@Test func theLibraryRefusesAClashAndCleansUpAfterADeletedGesture() throws {
    var library = GestureLibrary()
    library.combinations = [
        Combination(id: "one", left: .fist, right: .oneFinger),
        Combination(id: "two", left: .custom("G"), right: .palm),
    ]
    #expect(library.clash(for: Combination(id: "new", left: .oneFinger, right: .fist))?.id == "one")
    #expect(library.clash(for: Combination(id: "one", left: .oneFinger, right: .fist)) == nil)
    #expect(library.isCombined(.fist))
    #expect(!library.isCombined(.two))
    #expect(library.title(for: .combination("one")) == "Fist + One finger")

    // Nothing is left pointing at a gesture that is gone.
    let gone = library.removeGesture("G")
    #expect(Set(gone) == [.custom("G"), .combination("two")])
    #expect(library.combinations.map(\.id) == ["one"])
    #expect(!library.contains(.combination("two")))

    let restored = try JSONDecoder().decode(GestureLibrary.self, from: JSONEncoder().encode(library))
    #expect(restored == library)
    #expect(try JSONDecoder().decode(GestureLibrary.self, from: Data("{}".utf8)) == GestureLibrary())
}

@Test func theUsersOwnActionsComeDownToTheirSteps() throws {
    var config = AppConfig()
    let next = ActionBinding(kind: .shortcut, combo: KeyCombo(keyCode: 48, modifiers: 1 << 18, label: "⌃⇥"))
    let action = CustomAction(id: "A", name: "Next pane twice", steps: [next, .none, next])
    config.customActions = [action]
    config.setBinding(action.binding, for: .fist)

    // Steps that do nothing are left out; an ordinary binding is its own single step.
    #expect(config.steps(of: config.binding(for: .fist)) == [next, next])
    #expect(config.steps(of: next) == [next])
    #expect(config.steps(of: .none).isEmpty)
    #expect(config.summary(of: action.binding) == "Next pane twice")

    let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
    #expect(restored == config)

    // A gesture left pointing at a deleted action does nothing.
    config.removeCustomAction("A")
    #expect(config.binding(for: .fist).kind == .none)
    #expect(config.steps(of: action.binding).isEmpty)
    #expect(config.summary(of: action.binding) == "Deleted action")
}
