import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreWidgetSnapshotAccountTests {
    @Test
    func `widget snapshot does not preserve Claude quota after selected account changes`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-account-change-drops-quota"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.addTokenAccount(provider: .claude, label: "Primary", token: "primary-token")
        settings.addTokenAccount(provider: .claude, label: "Secondary", token: "secondary-token")
        settings.setActiveTokenAccountIndex(0, for: .claude)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let accounts = settings.tokenAccounts(for: .claude)
        let primaryAccount = try #require(accounts.first)
        let quotaOwnerKey = store.tokenAccountSnapshotCacheKey(provider: .claude, account: primaryAccount)
        let quotaUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tokenUpdatedAt = quotaUpdatedAt.addingTimeInterval(60)
        let quota = RateWindow(
            usedPercent: 28,
            windowMinutes: 300,
            resetsAt: quotaUpdatedAt.addingTimeInterval(3600),
            resetDescription: nil)
        store.lastQueuedWidgetSnapshot = WidgetSnapshot(
            entries: [
                WidgetSnapshot.ProviderEntry(
                    provider: .claude,
                    updatedAt: quotaUpdatedAt,
                    primary: quota,
                    secondary: nil,
                    tertiary: nil,
                    usageRows: [
                        WidgetSnapshot.WidgetUsageRowSnapshot(
                            id: "primary",
                            title: "Session",
                            percentLeft: 72),
                    ],
                    creditsRemaining: nil,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: [],
                    quotaOwnerKey: quotaOwnerKey),
            ],
            enabledProviders: [.claude],
            generatedAt: quotaUpdatedAt)

        settings.setActiveTokenAccountIndex(1, for: .claude)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4300,
                sessionCostUSD: 1.50,
                last30DaysTokens: 43000,
                last30DaysCostUSD: 13.50,
                daily: [],
                updatedAt: tokenUpdatedAt),
            provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-account-change-drops-quota-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(entry.primary == nil)
        #expect(entry.usageRows?.isEmpty == true)
        #expect(entry.quotaOwnerKey == nil)
        #expect(entry.tokenUsage?.sessionTokens == 4300)
    }

    @Test
    func `stacked Claude account success re-enables quota preservation`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-stacked-success-unblocks-quota"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .claude, label: "Primary", token: "primary-token")
        settings.addTokenAccount(provider: .claude, label: "Secondary", token: "secondary-token")
        settings.setActiveTokenAccountIndex(0, for: .claude)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let account = try #require(settings.effectiveSelectedTokenAccount(for: .claude))
        let quotaUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tokenUpdatedAt = quotaUpdatedAt.addingTimeInterval(60)
        let quota = RateWindow(
            usedPercent: 28,
            windowMinutes: 300,
            resetsAt: quotaUpdatedAt.addingTimeInterval(3600),
            resetDescription: nil)
        let outcome = ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: UsageSnapshot(
                    primary: quota,
                    secondary: nil,
                    updatedAt: quotaUpdatedAt),
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture.api-token",
                strategyKind: .apiToken)),
            attempts: [])

        store.widgetUsagePreservationBlockedProviders.insert(.claude)
        await store.applySelectedOutcome(
            outcome,
            provider: .claude,
            account: account,
            fallbackSnapshot: nil)
        #expect(!store.widgetUsagePreservationBlockedProviders.contains(.claude))

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-stacked-success-primes-quota-test")
        await store.widgetSnapshotPersistTask?.value
        let freshEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(freshEntry.primary == quota)
        #expect(freshEntry.quotaOwnerKey != nil)

        store.snapshots.removeValue(forKey: .claude)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4300,
                sessionCostUSD: 1.50,
                last30DaysTokens: 43000,
                last30DaysCostUSD: 13.50,
                daily: [],
                updatedAt: tokenUpdatedAt),
            provider: .claude)
        store.persistWidgetSnapshot(reason: "claude-stacked-success-preserves-quota-test")
        await store.widgetSnapshotPersistTask?.value

        let preservedEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(preservedEntry.primary == quota)
        #expect(preservedEntry.quotaOwnerKey == freshEntry.quotaOwnerKey)
        #expect(preservedEntry.tokenUsage?.sessionTokens == 4300)
    }
}
