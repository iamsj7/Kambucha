// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mirror",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "MirrorCore", resources: [.process("Resources")]),
        .executableTarget(name: "MirrorAgent", dependencies: ["MirrorCore"]),
        .executableTarget(name: "Mirror", dependencies: ["MirrorCore"]),
        .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
