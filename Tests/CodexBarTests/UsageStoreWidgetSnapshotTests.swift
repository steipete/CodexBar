import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreWidgetSnapshotTests {
    @Test
    func `widget snapshot includes antigravity grouped usage rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-grouped"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.usageBarsShowUsed = true

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-grouped-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(widgetSnapshots.last?.usageBarsShowUsed == true)
        #expect(entry.usageRows?.map(\.id) == ["primary", "secondary"])
        #expect(entry.usageRows?.map(\.title) == ["Gemini Models", "Claude and GPT"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [90, 80])
    }

    @Test
    func `widget snapshot includes antigravity quota summary rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-quota-summary"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 27, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models Five Hour Limit",
                    window: RateWindow(usedPercent: 9, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Models Weekly Limit",
                    window: RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude and GPT models Five Hour Limit",
                    window: RateWindow(usedPercent: 27, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude and GPT models Weekly Limit",
                    window: RateWindow(usedPercent: 36, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-quota-summary-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.usageRows?.map(\.title) == [
            "Gemini Models Five Hour Limit",
            "Gemini Models Weekly Limit",
            "Claude and GPT models Five Hour Limit",
            "Claude and GPT models Weekly Limit",
        ])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [91, 82, 73, 64])
    }

    @Test
    func `widget snapshot labels antigravity compact fallback with model name`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-compact-fallback"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = try AntigravityStatusSnapshot(
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
        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-compact-fallback-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.primary == nil)
        #expect(entry.usageRows?.map(\.id) == ["antigravity-compact-fallback-MODEL_PLACEHOLDER_NEW"])
        #expect(entry.usageRows?.map(\.title) == ["Experimental Model"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [36])
    }

    @Test
    func `widget snapshot excludes mimo balance from quota rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-mimo-balance"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            updatedAt: Date())
            .toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .mimo)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "mimo-balance-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .mimo })
        #expect(entry.primary == nil)
        #expect(entry.secondary == nil)
        #expect(entry.usageRows?.isEmpty == true)
    }

    @Test
    func `widget snapshot keeps Claude local cost without quota data`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-local-cost-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4200,
                sessionCostUSD: 1.25,
                last30DaysTokens: 42000,
                last30DaysCostUSD: 12.50,
                daily: [],
                updatedAt: updatedAt),
            provider: .claude)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .codex)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-local-cost-only-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(entry.updatedAt == updatedAt)
        #expect(entry.primary == nil)
        #expect(entry.secondary == nil)
        #expect(entry.usageRows?.isEmpty == true)
        #expect(entry.tokenUsage?.sessionTokens == 4200)
        #expect(entry.tokenUsage?.last30DaysTokens == 42000)
    }

    @Test(arguments: [true, false])
    func `widget snapshot respects extra usage visibility for Devin`(_ showsExtraUsage: Bool) async throws {
        let suite = "UsageStoreWidgetSnapshotTests-devin-extra-usage-\(showsExtraUsage)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.showOptionalCreditsAndExtraUsage = showsExtraUsage

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 48,
                    limit: 0,
                    currencyCode: "USD",
                    period: "Extra usage balance",
                    updatedAt: updatedAt),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .devin,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .devin)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "devin-extra-usage-visibility-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .devin })
        #expect((entry.providerCost != nil) == showsExtraUsage)
    }
}
