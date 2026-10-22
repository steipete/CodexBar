import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeUnpricedCoverageTests {
    private static let pricedModel = "claude-sonnet-4-20250514"
    private static let unpricedModel = "fixture-proxy-model-without-price"

    @Test
    func `unpriced only Claude day reports coverage and keeps the priced dashboard subtotal`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let pricedDay = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let unpricedDay = try env.makeLocalNoon(year: 2026, month: 7, day: 2)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project/session.jsonl",
            contents: env.jsonl([
                Self.event(env: env, day: pricedDay, id: "priced", model: Self.pricedModel),
                Self.event(env: env, day: unpricedDay, id: "proxy-a", model: Self.unpricedModel),
                Self.event(env: env, day: unpricedDay, id: "proxy-b", model: Self.unpricedModel),
            ]))

        let report = Self.load(env: env, since: pricedDay, until: unpricedDay)
        let priced = try #require(report.data.first { $0.date == "2026-07-01" })
        let unpriced = try #require(report.data.first { $0.date == "2026-07-02" })
        let pricedCost = try #require(priced.costUSD)
        #expect(pricedCost > 0)
        #expect(priced.unpricedRequestCount == nil)
        #expect(unpriced.costUSD == nil)
        #expect(unpriced.unpricedRequestCount == 2)
        #expect(unpriced.estimatedRequestCount == 0)
        #expect(unpriced.unmeteredRequestCount == nil)

        let group = try Self.dashboardGroup(report: report, now: unpricedDay)
        let provider = try #require(group.providers.first)
        #expect(abs((group.totalCost ?? 0) - pricedCost) < 0.000000001)
        #expect(abs((provider.totalCost ?? 0) - pricedCost) < 0.000000001)
        #expect(provider.costIsLowerBound)
        #expect(group.hasPartialCost)
    }

    @Test
    func `mixed Claude day counts only requests whose model has no price`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project/session.jsonl",
            contents: env.jsonl([
                Self.event(env: env, day: day, id: "priced-a", model: Self.pricedModel),
                Self.event(env: env, day: day, id: "priced-b", model: Self.pricedModel),
                Self.event(env: env, day: day, id: "proxy", model: Self.unpricedModel),
            ]))

        let entry = try #require(Self.load(env: env, since: day, until: day).data.first)
        #expect((entry.costUSD ?? 0) > 0)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.estimatedRequestCount == 2)
        #expect(entry.unmeteredRequestCount == nil)
    }

    @Test
    func `fully priced Claude history keeps exact totals without coverage metadata`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let first = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let second = try env.makeLocalNoon(year: 2026, month: 7, day: 2)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project/session.jsonl",
            contents: env.jsonl([
                Self.event(env: env, day: first, id: "a", model: Self.pricedModel),
                Self.event(env: env, day: second, id: "b", model: Self.pricedModel),
            ]))

        let report = Self.load(env: env, since: first, until: second)
        #expect(report.data.count == 2)
        for entry in report.data {
            #expect(entry.costUSD != nil)
            #expect(entry.unpricedRequestCount == nil)
            #expect(entry.estimatedRequestCount == nil)
            #expect(entry.unmeteredRequestCount == nil)
        }

        let group = try Self.dashboardGroup(report: report, now: second)
        let provider = try #require(group.providers.first)
        let summaryCost = try #require(report.summary?.totalCostUSD)
        #expect(abs((provider.totalCost ?? 0) - summaryCost) < 0.000000001)
        #expect(!provider.costIsLowerBound)
        #expect(!group.hasPartialCost)
    }

    private static func load(env: CostUsageTestEnvironment, since: Date, until: Date) -> CostUsageDailyReport {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        return CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: since,
            until: until,
            now: until,
            options: options)
    }

    private static func dashboardGroup(
        report: CostUsageDailyReport,
        now: Date) throws -> SpendDashboardModel.CurrencyGroup
    {
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: now,
            historyDays: 30,
            costProvenance: .listPriceEstimate)
        return try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 30,
            now: now,
            calendar: .current).groups.first)
    }

    private static func event(
        env: CostUsageTestEnvironment,
        day: Date,
        id: String,
        model: String) -> [String: Any]
    {
        [
            "type": "assistant",
            "timestamp": env.isoString(for: day),
            "sessionId": "session-\(id)",
            "requestId": "request-\(id)",
            "message": [
                "id": "message-\(id)",
                "model": model,
                "usage": [
                    "input_tokens": 1000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 100,
                ],
            ],
        ]
    }
}
