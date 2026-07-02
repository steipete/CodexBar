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
            balance: 8.059489,
            uncollected: 0,
            daily: Self.window(cost: 0.005746, totalTokens: 12467, requestCount: 9),
            weekly: Self.window(cost: 0.665033, totalTokens: 1_925_790, requestCount: 529),
            monthly: Self.window(cost: 5.368746, totalTokens: 35_412_471, requestCount: 3166),
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
        #expect(lines.contains("Auth: API key"))
        #expect(lines.contains("Today: $0.01 · 12K tokens"))
        #expect(lines.contains("Week: $0.67 · 529 requests"))
        #expect(lines.contains("Month: $5.37 · 3.2K requests"))
    }

    @Test
    func `crossmodel provider preserves non USD menu currency`() throws {
        let suite = "MenuDescriptorCrossModelTests-eur"
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
            currency: "EUR",
            balance: 8.059489,
            uncollected: 0,
            daily: Self.window(cost: 0.005746, totalTokens: 12467, requestCount: 9),
            weekly: Self.window(cost: 0.665033, totalTokens: 1_925_790, requestCount: 529),
            monthly: Self.window(cost: 5.368746, totalTokens: 35_412_471, requestCount: 3166),
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

        #expect(lines.contains("Balance: €8.06"))
        #expect(lines.contains("Today: €0.01 · 12K tokens"))
        #expect(!lines.contains(where: { $0.contains("$") }))
    }

    @Test
    @MainActor
    func `crossmodel menu card does not render generic credits bar`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.crossmodel])
        let usage = CrossModelUsageSnapshot(
            currency: "USD",
            balance: 8.059489,
            uncollected: 0,
            daily: Self.window(cost: 0.005746, totalTokens: 12467, requestCount: 9),
            weekly: Self.window(cost: 0.665033, totalTokens: 1_925_790, requestCount: 529),
            monthly: Self.window(cost: 5.368746, totalTokens: 35_412_471, requestCount: 3166),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .crossmodel,
            metadata: metadata,
            snapshot: usage.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.creditsText == nil)
    }

    @Test
    func `crossmodel menu card preserves balance when optional usage is unavailable`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.crossmodel])
        let usage = CrossModelUsageSnapshot(
            currency: "USD",
            balance: 8.059489,
            uncollected: 0,
            daily: nil,
            weekly: nil,
            monthly: nil,
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .crossmodel,
            metadata: metadata,
            snapshot: usage.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.map(\.value) == ["$8.06", "—", "—", "—"])
        #expect(dashboard.points.isEmpty)
        #expect(model.creditsText == nil)
    }

    private static func window(
        cost: Double,
        totalTokens: Int,
        requestCount: Int) -> CrossModelUsageWindow
    {
        CrossModelUsageWindow(
            cost: cost,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: totalTokens,
            requestCount: requestCount,
            successCount: requestCount)
    }
}
