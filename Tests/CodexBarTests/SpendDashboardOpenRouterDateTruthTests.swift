import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardOpenRouterDateTruthTests {
    @Test
    func `completed UTC history never fabricates the current day`() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z"))
        let august6 = try #require(utc.date(from: DateComponents(year: 2026, month: 8, day: 6)))
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-08-05", cost: 1, tokens: 10),
                Self.entry(day: "2026-08-06", cost: 2, tokens: 20),
            ],
            historyDays: 2,
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .openrouter, displayName: "OpenRouter", snapshot: snapshot)],
            requestedDays: 2,
            now: now,
            calendar: utc).groups.first)

        #expect(group.providers.first?.coveredDayCount == 1)
        #expect(group.totalCost == 2)
        #expect(group.totalTokens == 20)
        #expect(group.dailyPoints.map(\.day) == [august6])
        #expect(group.coveredDayCount == 1)
    }

    @Test
    func `thirty completed days stay partial in annual view`() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z"))
        let snapshot = Self.snapshot(
            entries: [Self.entry(day: "2026-08-06", cost: 2, tokens: 20)],
            historyDays: 30,
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .openrouter, displayName: "OpenRouter", snapshot: snapshot)],
            requestedDays: 365,
            now: now,
            calendar: utc).groups.first)

        #expect(group.providers.first?.coveredDayCount == 30)
        #expect(group.coveredDayCount == 30)
        #expect(group.totalCost == nil)
        #expect(group.knownCost == 2)
        #expect(group.totalTokens == nil)
        #expect(group.knownTokens == 20)
    }

    private static func snapshot(
        entries: [CostUsageDailyReport.Entry],
        historyDays: Int,
        updatedAt: Date) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: "USD",
            historyDays: historyDays,
            daily: entries,
            updatedAt: updatedAt)
    }

    private static func entry(day: String, cost: Double, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [
                .init(modelName: "fixture-model", costUSD: cost, totalTokens: tokens),
            ])
    }
}
