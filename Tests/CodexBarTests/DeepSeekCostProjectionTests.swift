import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct DeepSeekCostProjectionTests {
    @Test
    func `reported Platform spend reaches the shared cost snapshot`() throws {
        let now = Date(timeIntervalSince1970: 1_794_398_400)
        let summary = DeepSeekUsageSummary(
            todayTokens: 1000,
            currentMonthTokens: 1000,
            todayCost: 0.797,
            currentMonthCost: 0.797,
            requestCount: 10,
            currentMonthRequestCount: 10,
            topModel: nil,
            categoryBreakdown: [],
            daily: [.init(date: "2026-11-11", totalTokens: 1000, cost: 0.797, requestCount: 10)],
            currency: "CNY",
            period: .last30Days,
            updatedAt: now)
        let usage = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "CNY",
            totalBalance: 47.19,
            grantedBalance: 0,
            toppedUpBalance: 47.19,
            usageSummary: summary,
            updatedAt: now).toUsageSnapshot()

        #expect(DeepSeekProviderDescriptor.descriptor.tokenCost.supportsTokenCost)
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.deepseek))
        let cost = try #require(usage.costUsage)
        #expect(cost.currencyCode == "CNY")
        #expect(cost.daily.first?.costUSD == 0.797)
        #expect(cost.costProvenance == .vendorMetered)
    }

    @MainActor
    @Test
    func `profile transitions clear the snapshot and published spend`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let now = Date(timeIntervalSince1970: 1_794_398_400)
        let cost = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: 0.797,
            last30DaysTokens: nil,
            last30DaysCostUSD: 0.797,
            daily: [],
            updatedAt: now)
        let usage = UsageSnapshot(primary: nil, secondary: nil, costUsage: cost, updatedAt: now)
        #expect(usage.withoutDeepSeekDetailedUsage().costUsage == nil)
        store.snapshots[.deepseek] = usage
        store.publishProviderDerivedTokenSnapshot(from: usage, for: .deepseek)
        #expect(store.tokenSnapshot(for: .deepseek) != nil)
        store.beginDeepSeekProfileTransition()
        #expect(store.deepseekProfileTransitionSnapshot?.costUsage == nil)
        #expect(store.tokenSnapshot(for: .deepseek) == nil)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .deepseek) == nil)
    }

    @MainActor
    @Test
    func `missing Platform usage is unavailable rather than confirmed zero`() {
        let store = self.makeStore()
        defer { store.stopSharedSpendDashboardPublication() }
        let now = Date(timeIntervalSince1970: 1_794_398_400)
        let cost = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: 0.797,
            last30DaysTokens: nil,
            last30DaysCostUSD: 0.797,
            daily: [],
            updatedAt: now)
        store.publishProviderDerivedTokenSnapshot(
            from: UsageSnapshot(primary: nil, secondary: nil, costUsage: cost, updatedAt: now),
            for: .deepseek)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .deepseek)?.snapshot != nil)

        store.publishProviderDerivedTokenSnapshot(
            from: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            for: .deepseek)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .deepseek) == nil)
    }

    @MainActor
    private func makeStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "DeepSeekCostProjectionTests",
            userDefaults: InMemoryUserDefaults(),
            config: CodexBarConfig(providers: []))
        settings.statusChecksEnabled = false
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: "/nonexistent/deepseek-projection", cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}
