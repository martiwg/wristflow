// swift-tools-version: 6.0
import Foundation
import PackageDescription

let package = Package(
    name: "WristFlow",
    platforms: [.macOS(.v15)],
    targets: [
        // Decides what the user meant from plain landmark frames. Foundation only, so it also
        // builds on Windows and Linux.
        .target(name: "WristFlowCore", path: "Sources/WristFlowCore"),
        .testTarget(name: "WristFlowCoreTests", dependencies: ["WristFlowCore"], path: "Tests/WristFlowCoreTests"),
    ] + macTargets,
    swiftLanguageModes: [.v5]
)

/// The macOS shell: camera, Vision, actions and the menu bar UI.
/// Set WRISTFLOW_CORE_ONLY=1 to build and test the portable core on its own.
var macTargets: [Target] {
    #if os(macOS)
    if ProcessInfo.processInfo.environment["WRISTFLOW_CORE_ONLY"] != nil { return [] }
    return [.executableTarget(name: "WristFlow", dependencies: ["WristFlowCore"], path: "Sources/WristFlowMac")]
    #else
    return []
    #endif
}
