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
    for trigger in Trigger.allCases {
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
