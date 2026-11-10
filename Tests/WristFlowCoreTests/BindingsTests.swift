import Foundation
import Testing
@testable import WristFlowCore

@Test func configFromAnOlderFileKeepsDefaults() throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"holdTime": 0.6}"#.utf8))
    #expect(config.holdTime == 0.6)
    #expect(config.enabled)
    #expect(config.binding(for: .palm).kind == .wisprToggle)
}

@Test func everyTriggerHasADefaultBinding() {
    let config = AppConfig()
    for trigger in Trigger.allCases {
        #expect(config.binding(for: trigger).kind != .none)
    }
}

@Test func fingersCoverEveryJointExceptTheWrist() {
    let joints = Finger.allCases.flatMap(\.joints)
    #expect(joints.count == 20)
    #expect(Set(joints).count == 20)
    #expect(!joints.contains(.wrist))
    #expect(Finger.little.tip == .littleTip)
}
