import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct UsageStoreHighestUsageTests {
    @Test
    func selectsHighestUsageAmongEnabledProviders() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-selects"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let claudeSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(claudeSnapshot, provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 60)
    }

    @Test
    func skipsFullyUsedProviders() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-skips"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let claudeSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(claudeSnapshot, provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func automaticMetricUsesSecondaryForKimiWhenRankingHighestUsage() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-kimi-automatic"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .kimi)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let kimiMeta = registry.metadata[.kimi] {
            settings.setProviderEnabled(provider: .kimi, metadata: kimiMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let kimiSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(kimiSnapshot, provider: .kimi)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 70)
    }

    @Test
    func automaticMetricKeepsCopilotMostConstrainedRanking() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-copilot-automatic"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .copilot)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let copilotMeta = registry.metadata[.copilot] {
            settings.setProviderEnabled(provider: .copilot, metadata: copilotMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let copilotSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(copilotSnapshot, provider: .copilot)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .copilot)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func automaticMetricDoesNotExcludePartiallyAvailableCopilotAtHundredPercent() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-copilot-partial-100"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .copilot)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let copilotMeta = registry.metadata[.copilot] {
            settings.setProviderEnabled(provider: .copilot, metadata: copilotMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let copilotSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(copilotSnapshot, provider: .copilot)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .copilot)
        #expect(highest?.usedPercent == 100)
    }

    @Test
    func automaticMetricExcludesCopilotWhenBothLanesAreExhausted() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-copilot-both-100"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .copilot)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let copilotMeta = registry.metadata[.copilot] {
            settings.setProviderEnabled(provider: .copilot, metadata: copilotMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let copilotSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(copilotSnapshot, provider: .copilot)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }
}
