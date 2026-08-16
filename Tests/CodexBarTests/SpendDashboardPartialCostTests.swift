import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardPartialCostTests {
    @Test
    func `established Codex history retains priced spend beside an unresolved long context day`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "gpt-5.4-mini"),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 400_000, model: "gpt-5.6-sol"),
            ],
            last30DaysTokens: 400_030,
            last30DaysCostUSD: 3)
        let group = try Self.group(snapshot)

        #expect(snapshot.historyCoverageIsEstablished)
        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 400_030)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.map(\.modelName) == ["gpt-5.4-mini", "gpt-5.6-sol"])
        #expect(group.models.map(\.totalCost) == [3, nil])
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `incomplete Codex history with an unresolved day keeps spend unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "gpt-5.4-mini"),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 400_000, model: "gpt-5.6-sol"),
            ],
            historyCoverageIsEstablished: false,
            last30DaysTokens: 400_030,
            last30DaysCostUSD: 3)
        let group = try Self.group(snapshot)

        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(group.totalCost == nil)
        #expect(group.coveredDayCount == 0)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `established Codex rows without aggregate proof keep partial spend unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "gpt-5.4-mini"),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 400_000, model: "gpt-5.6-sol"),
            ],
            last30DaysTokens: 400_030,
            last30DaysCostUSD: nil)
        let group = try Self.group(snapshot)

        #expect(snapshot.historyCoverageIsEstablished)
        #expect(group.totalCost == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `established fully priced Codex history remains complete`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "gpt-5.4-mini"),
                Self.entry(day: "2026-07-16", cost: 4, tokens: 40, model: "gpt-5.6-sol"),
            ],
            last30DaysTokens: 70,
            last30DaysCostUSD: 7)
        let group = try Self.group(snapshot)

        #expect(group.totalCost == 7)
        #expect(group.totalTokens == 70)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.dailyPoints.map(\.cost) == [3, 4])
    }

    private static func group(_ snapshot: CostUsageTokenSnapshot) throws -> SpendDashboardModel.CurrencyGroup {
        try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Codex", snapshot: snapshot)],
            requestedDays: 30,
            now: self.now,
            calendar: self.calendar).groups.first)
    }

    private static func snapshot(
        entries: [CostUsageDailyReport.Entry],
        historyCoverageIsEstablished: Bool = true,
        last30DaysTokens: Int?,
        last30DaysCostUSD: Double?) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: 2,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            daily: entries,
            updatedAt: self.now)
    }

    private static func entry(
        day: String,
        cost: Double?,
        tokens: Int,
        model: String) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: model, costUSD: cost, totalTokens: tokens)])
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
