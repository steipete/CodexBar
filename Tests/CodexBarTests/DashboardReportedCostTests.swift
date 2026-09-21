import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardReportedCostTests {
    private static let now = Date(timeIntervalSince1970: 1_789_779_600) // 2026-09-19 01:00 UTC

    @Test(arguments: [0.0, 12.5])
    func `reported history keeps its aggregate without reinterpreting completed UTC days as Today`(
        reported: Double) throws
    {
        let history = Self.history(cost: reported, dailyCost: 1.25)
        let snapshot = Self.dashboard(history: history)
        let cost = try #require(snapshot.providers.first?.cost)
        #expect(cost.last30DaysUSD == reported)
        #expect(cost.todayUSD == nil)
        #expect(cost.todayIncompleteRequestCount == nil)
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let encoded = try #require(provider["cost"] as? [String: Any])
        #expect(encoded["todayUSD"] is NSNull)
        #expect(encoded["last30DaysUSD"] as? Double == reported)
    }

    @Test
    func `missing reported amounts remain unavailable even when daily history has a local matching date`() {
        #expect(Self.dashboard(history: Self.history(cost: nil, dailyCost: 1.25)).providers.first?.cost == nil)
        #expect(Self.dashboard(history: nil).providers.first?.cost == nil)
    }

    @Test(arguments: [("EUR", 30), ("USD", 7), ("USD", 90)])
    func `reported costs never relabel a different currency or window as thirty day USD`(
        currency: String, days: Int)
    {
        let history = Self.history(cost: 12.5, currency: currency, days: days)
        #expect(Self.dashboard(history: history).providers.first?.cost == nil)
    }

    @Test(arguments: [Optional(5.0), nil])
    func `local cost payload retains precedence including an unavailable local amount`(localAmount: Double?) {
        let local = CostPayload(
            provider: "claude",
            source: "local",
            updatedAt: Self.now,
            sessionTokens: nil,
            sessionCostUSD: nil,
            historyDays: 30,
            last30DaysTokens: nil,
            last30DaysCostUSD: localAmount,
            daily: [],
            totals: nil,
            error: nil)
        let snapshot = Self.dashboard(history: Self.history(cost: 99), local: local, provider: .claude)
        #expect(snapshot.providers.first?.cost?.last30DaysUSD == localAmount)
        #expect(snapshot.providers.first?.cost?.todayUSD == nil)
    }

    @Test
    func `reported incomplete history preserves unknown money and its exclusion count`() throws {
        let entry = ClaudeIncompleteUsagePropagationTests.entry(
            day: "2026-09-18", cost: nil, tokens: nil, incomplete: 2)
        let history = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [entry],
            updatedAt: Self.now)
        let cost = try #require(Self.dashboard(history: history).providers.first?.cost)
        #expect(cost.last30DaysUSD == nil)
        #expect(cost.last30DaysIncompleteRequestCount == 2)
        #expect(cost.todayUSD == nil)
        #expect(cost.todayIncompleteRequestCount == nil)
    }

    private static func history(
        cost: Double?,
        dailyCost: Double? = nil,
        currency: String = "USD",
        days: Int = 30) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 120_000,
            last30DaysCostUSD: cost,
            currencyCode: currency,
            historyDays: days,
            historyLabel: "Last 30 days (UTC)",
            costProvenance: .vendorMetered,
            daily: [ClaudeIncompleteUsagePropagationTests.entry(
                day: "2026-09-18", cost: dailyCost, tokens: 120_000)],
            updatedAt: self.now)
    }

    private static func dashboard(
        history: CostUsageTokenSnapshot?,
        local: CostPayload? = nil,
        provider: UsageProvider = .openrouter) -> DashboardSnapshotPayload
    {
        DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [ProviderPayload(
                provider: provider,
                account: nil,
                version: nil,
                source: "api",
                status: nil,
                usage: UsageSnapshot(primary: nil, secondary: nil, costUsage: history, updatedAt: self.now),
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: nil)],
            costPayloads: local.map { [$0] } ?? [],
            config: CodexBarConfig(providers: [ProviderConfig(id: provider.instanceID, enabled: true)]),
            identityMode: .redacted,
            generatedAt: self.now,
            refreshInterval: 60,
            codexBarVersion: nil)
    }
}
