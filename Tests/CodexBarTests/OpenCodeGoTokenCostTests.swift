import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OpenCodeGoTokenCostTests {
    @Test
    func `token snapshot projection is nil when local daily history is empty`() {
        let settings = Self.makeSettings()
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        // Web-only source mode and machines without a readable local database leave
        // `opencodegoUsage` present but `daily` empty. A dataless projection here would
        // otherwise still surface a Cost row whose history submenu has nothing to render.
        let emptySnapshot = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 12,
            weeklyUsagePercent: 57,
            monthlyUsagePercent: 34,
            rollingResetInSec: 3600,
            weeklyResetInSec: 86400,
            monthlyResetInSec: 864_000,
            daily: [],
            updatedAt: Date())

        #expect(store.tokenSnapshot(
            fromProviderSnapshot: emptySnapshot.toUsageSnapshot(),
            provider: .opencodego) == nil)
    }

    @Test
    func `token snapshot projection is populated when local daily history exists`() {
        let settings = Self.makeSettings()
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let populatedSnapshot = OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: 12,
            weeklyUsagePercent: 57,
            monthlyUsagePercent: 34,
            rollingResetInSec: 3600,
            weeklyResetInSec: 86400,
            monthlyResetInSec: 864_000,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    requestCount: 5,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date())

        let tokenSnapshot = store.tokenSnapshot(
            fromProviderSnapshot: populatedSnapshot.toUsageSnapshot(),
            provider: .opencodego)
        #expect(tokenSnapshot?.daily.isEmpty == false)
        #expect(tokenSnapshot?.last30DaysCostUSD == 1.23)
    }

    private static func makeSettings() -> SettingsStore {
        let suite = "OpenCodeGoTokenCostTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
    }
}
