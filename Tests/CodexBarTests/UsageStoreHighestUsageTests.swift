import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreHighestUsageTests {
    @Test
    func `selects highest usage among enabled providers`() {
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
    func `skips fully used providers`() {
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
    func `automatic metric uses secondary for kimi when ranking highest usage`() {
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
    func `automatic metric ignores antigravity tertiary when compact icon has no quota summary`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-antigravity-tertiary"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .antigravity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let antigravitySnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: RateWindow(usedPercent: 85, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(antigravitySnapshot, provider: .antigravity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 70)
    }

    @Test
    func `automatic metric ignores unclassified antigravity compact fallback`() throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-antigravity-unclassified"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .antigravity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let antigravitySnapshot = try AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Experimental Model",
                    modelId: "MODEL_PLACEHOLDER_NEW",
                    remainingFraction: 0.36,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)
            .toUsageSnapshot()

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(antigravitySnapshot, provider: .antigravity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 50)
    }

    @Test
    func `automatic metric ignores legacy antigravity family lanes without quota summary`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-antigravity-constrained-gemini"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .antigravity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let antigravitySnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "Claude"),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "Gemini Pro"),
            tertiary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: "Gemini Flash"),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(antigravitySnapshot, provider: .antigravity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 70)
    }
}

extension UsageStoreHighestUsageTests {
    @Test
    func `automatic metric ranks antigravity by rendered quota summary lanes across groups`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-antigravity-all-summary"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .antigravity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        let antigravity = self.antigravityQuotaSummarySnapshot(
            geminiSessionUsed: 10,
            geminiWeeklyUsed: 20,
            otherSessionUsed: 95,
            otherWeeklyUsed: 90)
        let unknownCadence = NamedRateWindow(
            id: "antigravity-quota-summary-future-daily",
            title: "Future daily lane",
            window: RateWindow(
                usedPercent: 99,
                windowMinutes: 24 * 60,
                resetsAt: nil,
                resetDescription: nil))
        store._setSnapshotForTesting(
            antigravity.with(extraRateWindows: (antigravity.extraRateWindows ?? []) + [unknownCadence]),
            provider: .antigravity)

        var highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .antigravity)
        #expect(highest?.usedPercent == 95)

        store._setSnapshotForTesting(
            self.antigravityQuotaSummarySnapshot(
                geminiSessionUsed: 95,
                geminiWeeklyUsed: 20,
                otherSessionUsed: 10,
                otherWeeklyUsed: 10),
            provider: .antigravity)
        highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .antigravity)
        #expect(highest?.usedPercent == 95)

        store._setSnapshotForTesting(
            self.antigravityQuotaSummarySnapshot(
                geminiSessionUsed: 100,
                geminiWeeklyUsed: 100,
                otherSessionUsed: 50,
                otherWeeklyUsed: 50),
            provider: .antigravity)
        highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
    }

    @Test
    func `automatic metric skips exhausted antigravity quota summary lanes when another remains usable`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-antigravity-summary-usable"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .antigravity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let antigravitySnapshot = self.antigravityQuotaSummarySnapshot(
            geminiSessionUsed: 100,
            geminiWeeklyUsed: 40,
            otherSessionUsed: 100,
            otherWeeklyUsed: 100)

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(antigravitySnapshot, provider: .antigravity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `automatic metric ignores antigravity legacy detail rows`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-antigravity-fallback-detail"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .antigravity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: "antigravity-compact-fallback-model-a",
                        title: "Model A",
                        window: RateWindow(
                            usedPercent: 100,
                            windowMinutes: nil,
                            resetsAt: nil,
                            resetDescription: nil)),
                    NamedRateWindow(
                        id: "model-b",
                        title: "Model B",
                        window: RateWindow(
                            usedPercent: 50,
                            windowMinutes: nil,
                            resetsAt: nil,
                            resetDescription: nil)),
                ],
                updatedAt: Date()),
            provider: .antigravity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `automatic metric skips antigravity with no quota lanes`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-antigravity-empty"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .antigravity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let antigravitySnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(antigravitySnapshot, provider: .antigravity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `automatic metric uses zai 5-hour token lane when ranking highest usage`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-zai-automatic-tertiary"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .zai)
        settings.addTokenAccount(provider: .zai, label: "Primary", token: "zai-token")

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let zaiMeta = registry.metadata[.zai] {
            settings.setProviderEnabled(provider: .zai, metadata: zaiMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let zaiSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 15, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 90, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(zaiSnapshot, provider: .zai)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .zai)
        #expect(highest?.usedPercent == 90)
    }

    @Test
    func `automatic metric keeps copilot most constrained ranking`() {
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
    func `automatic metric does not exclude partially available copilot at hundred percent`() {
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
    func `automatic metric excludes copilot when both lanes are exhausted`() {
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

    @Test
    func `automatic metric uses tertiary when it is most constrained for cursor`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-cursor-tertiary"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .cursor)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let cursorMeta = registry.metadata[.cursor] {
            settings.setProviderEnabled(provider: .cursor, metadata: cursorMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let cursorSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 95, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(cursorSnapshot, provider: .cursor)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .cursor)
        #expect(highest?.usedPercent == 95)
    }

    @Test
    func `automatic metric keeps perplexity in highest usage when purchased credits remain`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-perplexity-purchased"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 15, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let perplexitySnapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 45, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(perplexitySnapshot, provider: .perplexity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .perplexity)
        #expect(highest?.usedPercent == 45)
    }

    @Test
    func `automatic metric ignores exhausted recurring perplexity lane when fallback remains`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-perplexity-recurring-exhausted"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let perplexitySnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(perplexitySnapshot, provider: .perplexity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .perplexity)
        #expect(highest?.usedPercent == 40)
    }

    @Test
    func `automatic metric prefers purchased perplexity credits before bonus in highest usage`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-perplexity-purchased-before-bonus"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let perplexitySnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 45, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(perplexitySnapshot, provider: .perplexity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .perplexity)
        #expect(highest?.usedPercent == 45)
    }

    @Test
    func `primary metric keeps exhausted recurring perplexity lane in highest usage selection`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-perplexity-primary-exhausted"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.primary, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let perplexitySnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(perplexitySnapshot, provider: .perplexity)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 25)
    }

    @Test
    func `automatic metric excludes cursor when all opus lanes are exhausted`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-cursor-all-100"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.automatic, for: .cursor)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let cursorMeta = registry.metadata[.cursor] {
            settings.setProviderEnabled(provider: .cursor, metadata: cursorMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let cursorSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(cursorSnapshot, provider: .cursor)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `cursor highest usage keeps provider when saved tertiary falls back to automatic`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-cursor-missing-tertiary"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.tertiary, for: .cursor)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let cursorMeta = registry.metadata[.cursor] {
            settings.setProviderEnabled(provider: .cursor, metadata: cursorMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let cursorSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(cursorSnapshot, provider: .cursor)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .cursor)
        #expect(highest?.usedPercent == 100)
    }

    private func antigravityQuotaSummarySnapshot(
        geminiSessionUsed: Double,
        geminiWeeklyUsed: Double,
        otherSessionUsed: Double,
        otherWeeklyUsed: Double) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Session",
                    window: RateWindow(
                        usedPercent: geminiSessionUsed,
                        windowMinutes: 5 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    window: RateWindow(
                        usedPercent: geminiWeeklyUsed,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude + GPT Session",
                    window: RateWindow(
                        usedPercent: otherSessionUsed,
                        windowMinutes: 5 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude + GPT Weekly",
                    window: RateWindow(
                        usedPercent: otherWeeklyUsed,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date())
    }
}

extension UsageStoreHighestUsageTests {
    @Test
    func `explicit antigravity metric remains authoritative for highest usage`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreHighestUsageTests-antigravity-explicit"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.secondary, for: .antigravity)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let antigravityMeta = registry.metadata[.antigravity] {
            settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        let antigravity = self.antigravityQuotaSummarySnapshot(
            geminiSessionUsed: 10,
            geminiWeeklyUsed: 20,
            otherSessionUsed: 95,
            otherWeeklyUsed: 90)
            .with(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 95, windowMinutes: nil, resetsAt: nil, resetDescription: nil))
        store._setSnapshotForTesting(antigravity, provider: .antigravity)

        var highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .antigravity)
        #expect(highest?.usedPercent == 95)

        store._setSnapshotForTesting(
            antigravity.with(
                primary: antigravity.primary,
                secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)),
            provider: .antigravity)
        highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
    }
}
