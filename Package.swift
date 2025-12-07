// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexBar",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
        .package(url: "https://github.com/steipete/Commander", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "CodexBarCore",
            dependencies: [],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "CodexBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "CodexBarCore",
            ],
            path: "Sources/CodexBar",
            swiftSettings: [
                // Opt into Swift 6 strict concurrency (approachable migration path).
                .enableUpcomingFeature("StrictConcurrency"),
                .define("ENABLE_SPARKLE"),
            ]),
        .executableTarget(
            name: "CodexBarCLI",
            dependencies: [
                "CodexBarCore",
                .product(name: "Commander", package: "Commander"),
            ],
            path: "Sources/CodexBarCLI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .testTarget(
            name: "CodexBarTests",
            dependencies: ["CodexBar", "CodexBarCore", "CodexBarCLI"],
            path: "Tests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ]),
    ])
