// swift-tools-version: 6.0
import PackageDescription

/// The personal artifact has no dependency on the upstream all-provider targets or their helpers.
let package = Package(
    name: "PersonalCodexBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CodexBarCore"),
        .executableTarget(name: "CodexBar", dependencies: ["CodexBarCore"]),
        .testTarget(name: "QuotaTests", dependencies: ["CodexBarCore"]),
    ])
