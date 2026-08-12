import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardAllTimeDateTruthTests {
    @Test
    func `Mistral UTC bounds preserve first day in positive offset timezone`() throws {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-07-01T00:00:00Z"))
        let end = try #require(formatter.date(from: "2026-07-02T00:00:00Z"))
        let now = try #require(formatter.date(from: "2026-07-02T12:00:00Z"))
        let entries = [
            Self.entry(day: "2026-07-01", cost: 1, tokens: 10),
            Self.entry(day: "2026-07-02", cost: 2, tokens: 20),
        ]
        let input = SpendDashboardModel.ProviderInput(
            provider: .mistral,
            displayName: "Mistral",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 30,
                last30DaysCostUSD: 3,
                currencyCode: "USD",
                historyDays: 2,
                historyCoverageIsEstablished: true,
                daily: entries,
                updatedAt: end),
            trackedCoverage: .init(start: start, end: end, coveredDayCount: 2))

        let group = try #require(SpendDashboardModel.build(
            inputs: [input],
            range: .allTime,
            now: now,
            calendar: india).groups.first)

        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.providers.first?.coveredDayCount == 2)
        #expect(group.dailyPoints.map(\.cost) == [1, 2])
        #expect(group.dailyPoints.map(\.day) == [
            india.startOfDay(for: start),
            india.startOfDay(for: end),
        ])
    }

    private static func entry(day: String, cost: Double, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }
}
