// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mirror",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "MirrorCore", resources: [.process("Resources")]),
        // Keychain and code-signing checks. Only the agent links this, so Mirror.app can't reach the Keychain.
        .target(name: "MirrorSecrets", dependencies: ["MirrorCore"]),
        .executableTarget(name: "MirrorAgent", dependencies: ["MirrorCore", "MirrorSecrets"]),
        .executableTarget(name: "Mirror", dependencies: ["MirrorCore"]),
        .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore", "MirrorSecrets"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
