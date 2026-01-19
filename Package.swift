// swift-tools-version: 6.2
import CompilerPluginSupport
import Foundation
import PackageDescription

let sweetCookieKitPath = "../SweetCookieKit"
let useLocalSweetCookieKit =
    ProcessInfo.processInfo.environment["CODEXBAR_USE_LOCAL_SWEETCOOKIEKIT"] == "1"
let sweetCookieKitDependency: Package.Dependency =
    useLocalSweetCookieKit && FileManager.default.fileExists(atPath: sweetCookieKitPath)
    ? .package(path: sweetCookieKitPath)
    : .package(url: "https://github.com/steipete/SweetCookieKit", from: "0.2.1")

let package = Package(
    name: "CodexBar",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
        .package(url: "https://github.com/steipete/Commander", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-syntax", from: "600.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.10.0"),
        sweetCookieKitDependency,
    ],
    targets: {
        var targets: [Target] = [
            .target(
                name: "CodexBarCore",
                dependencies: [
                    "CodexBarMacroSupport",
                    .product(name: "Logging", package: "swift-log"),
                    .product(name: "SweetCookieKit", package: "SweetCookieKit"),
                ],
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .macro(
                name: "CodexBarMacros",
                dependencies: [
                    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                    .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                ]),
            .target(
                name: "CodexBarMacroSupport",
                dependencies: [
                    "CodexBarMacros",
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
                name: "CodexBarLinuxTests",
                dependencies: ["CodexBarCore", "CodexBarCLI"],
                path: "TestsLinux",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                    .enableExperimentalFeature("SwiftTesting"),
                ]),
        ]

        #if os(macOS)
        targets.append(contentsOf: [
            .executableTarget(
                name: "CodexBarClaudeWatchdog",
                dependencies: [],
                path: "Sources/CodexBarClaudeWatchdog",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "CodexBar",
                dependencies: [
                    .product(name: "Sparkle", package: "Sparkle"),
                    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                    "CodexBarMacroSupport",
                    "CodexBarCore",
                ],
                path: "Sources/CodexBar",
                resources: [
                    .process("Resources"),
                ],
                swiftSettings: [
                    // Opt into Swift 6 strict concurrency (approachable migration path).
                    .enableUpcomingFeature("StrictConcurrency"),
                    .define("ENABLE_SPARKLE"),
                ]),
            .executableTarget(
                name: "CodexBarWidget",
                dependencies: ["CodexBarCore"],
                path: "Sources/CodexBarWidget",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
            .executableTarget(
                name: "CodexBarClaudeWebProbe",
                dependencies: ["CodexBarCore"],
                path: "Sources/CodexBarClaudeWebProbe",
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency"),
                ]),
        ])

        targets.append(.testTarget(
            name: "CodexBarTests",
            dependencies: ["CodexBar", "CodexBarCore", "CodexBarCLI"],
            path: "Tests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ]))
        #endif

        return targets
    }())
