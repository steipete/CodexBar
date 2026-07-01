import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorCrossModelTests {
    @Test
    func `crossmodel provider contributes balance and usage windows`() throws {
        let suite = "MenuDescriptorCrossModelTests-usage"
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
        let usage = CrossModelUsageSnapshot(
            currency: "USD",
            balanceUSD: 8.059489,
            uncollectedUSD: 0,
            daily: Self.window(costUSD: 0.005746, totalTokens: 12467, requestCount: 9),
            weekly: Self.window(costUSD: 0.665033, totalTokens: 1_925_790, requestCount: 529),
            monthly: Self.window(costUSD: 5.368746, totalTokens: 35_412_471, requestCount: 3166),
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))
        store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .crossmodel)

        let descriptor = MenuDescriptor.build(
            provider: .crossmodel,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains("Balance: $8.06"))
        #expect(lines.count(where: { $0 == "Balance: $8.06" }) == 1)
        #expect(!lines.contains("Plan: Balance: $8.06"))
        #expect(lines.contains("Today: $0.01 · 12K tokens"))
        #expect(lines.contains("Week: $0.67 · 529 requests"))
        #expect(lines.contains("Month: $5.37 · 3.2K requests"))
    }

    private static func window(
        costUSD: Double,
        totalTokens: Int,
        requestCount: Int) -> CrossModelUsageWindow
    {
        CrossModelUsageWindow(
            costUSD: costUSD,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: totalTokens,
            requestCount: requestCount,
            successCount: requestCount)
    }
}
