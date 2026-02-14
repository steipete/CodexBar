import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Regression coverage for battery drain caused by fallback-provider animation.
/// See GitHub issues #269, #139.
@MainActor
@Suite(.serialized)
struct BatteryDrainDiagnosticTests {
    private func ensureAppKitInitialized() {
        _ = NSApplication.shared
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    @Test("Fallback provider should not animate when all providers are disabled")
    func fallbackProviderDoesNotAnimate() {
        self.ensureAppKitInitialized()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-AllDisabled"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let meta = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: meta, enabled: false)
            }
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        #expect(
            controller.needsMenuBarIconAnimation() == false,
            "Should not animate when only fallback provider is visible")
        #expect(
            controller.animationDriver == nil,
            "Animation driver should not start for fallback provider")
    }

    @Test("Enabled provider with data should not animate")
    func enabledProviderWithDataDoesNotAnimate() {
        self.ensureAppKitInitialized()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-HasData"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let meta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: meta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        #expect(
            controller.needsMenuBarIconAnimation() == false,
            "Should not animate when provider has data")
        #expect(
            controller.animationDriver == nil,
            "Animation driver should be nil when data is present")
    }

    @Test("Enabled provider without data should animate")
    func enabledProviderWithoutDataAnimates() {
        self.ensureAppKitInitialized()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-NoData"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let registry = ProviderRegistry.shared
        if let meta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: meta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        #expect(
            controller.needsMenuBarIconAnimation() == true,
            "Should animate when enabled provider has no data")
    }
}
