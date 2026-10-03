import AppKit
import SwiftUI
import Testing
@testable import CodexBar

/// Opt-in production settings rendering; no app launch, account transport, or visible window.
@MainActor
struct SpendTimeZoneNativeProofTests {
    @Test
    func `render statistics time zone controls`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_TIME_ZONE_PROOF_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: InMemoryUserDefaults(values: ["tokenCostUsageBucketTimeZone": "America/Detroit"]),
            config: testConfigWithAllProvidersDisabled())
        for language in ["en", "zh-Hans"] {
            for width in [600.0, 360.0] {
                try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                    let hosting = NSHostingView(rootView: SpendTimeZoneControls(settings: settings)
                        .frame(width: width, alignment: .leading)
                        .padding(24)
                        .background(Color.white)
                        .environment(\.colorScheme, .light))
                    hosting.appearance = NSAppearance(named: .aqua)
                    hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(
                            to: output.appendingPathComponent("time-zone-\(language)-\(Int(width)).png"),
                            options: .atomic)
                }
            }
        }
    }
}
