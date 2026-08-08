import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardCoverageTruthTests {
    @Test
    func `short non OpenRouter history stays a qualified lower bound in a longer window`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z"))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 20,
            last30DaysCostUSD: 2,
            currencyCode: "USD",
            historyDays: 30,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-07",
                    inputTokens: 10,
                    outputTokens: 10,
                    totalTokens: 20,
                    costUSD: 2,
                    modelsUsed: ["claude-sonnet-4"],
                    modelBreakdowns: [
                        .init(modelName: "claude-sonnet-4", costUSD: 2, totalTokens: 20),
                    ]),
            ],
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 365,
            now: now,
            calendar: calendar).groups.first)
        let row = try #require(group.providers.first)

        #expect(row.coveredDayCount == 30)
        #expect(row.totalCost == 2)
        #expect(group.totalCost == nil)
        #expect(group.knownCost == 2)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(spendDashboardProviderCostText(
            row,
            currencyCode: group.currencyCode,
            requestedDays: 365) == "~$2.00")
    }

    @Test
    func `full requested history keeps provider and aggregate amounts exact`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z"))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 20,
            last30DaysCostUSD: 2,
            currencyCode: "USD",
            historyDays: 30,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-07",
                    inputTokens: 10,
                    outputTokens: 10,
                    totalTokens: 20,
                    costUSD: 2,
                    modelsUsed: ["claude-sonnet-4"],
                    modelBreakdowns: [
                        .init(modelName: "claude-sonnet-4", costUSD: 2, totalTokens: 20),
                    ]),
            ],
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 30,
            now: now,
            calendar: calendar).groups.first)
        let row = try #require(group.providers.first)

        #expect(group.totalCost == 2)
        #expect(group.totalTokens == 20)
        #expect(spendDashboardProviderCostText(
            row,
            currencyCode: group.currencyCode,
            requestedDays: 30) == "$2.00")
    }
}
