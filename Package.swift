// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kambucha",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "KambuchaCore", resources: [.process("Resources")]),
        // Keychain and code-signing checks. Only the agent links this, so Kambucha.app can't reach the Keychain.
        .target(name: "KambuchaSecrets", dependencies: ["KambuchaCore"]),
        .executableTarget(name: "KambuchaAgent", dependencies: ["KambuchaCore", "KambuchaSecrets"]),
        .executableTarget(name: "Kambucha", dependencies: ["KambuchaCore"]),
        .testTarget(name: "KambuchaTests", dependencies: ["Kambucha", "KambuchaCore"]),
        .testTarget(name: "KambuchaCoreTests", dependencies: ["KambuchaCore", "KambuchaSecrets"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
