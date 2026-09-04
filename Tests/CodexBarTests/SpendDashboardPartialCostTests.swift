import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardPartialCostTests {
    @Test
    func `established empty Codex history renders zero spend`() throws {
        let snapshot = Self.snapshot(
            entries: [],
            last30DaysTokens: 0,
            last30DaysCostUSD: 0)
        let group = try Self.group(snapshot)

        #expect(group.totalCost == 0)
        #expect(group.totalTokens == 0)
        #expect(group.coveredDayCount == 2)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `unestablished empty Codex history keeps spend unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [],
            historyCoverageIsEstablished: false,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0)
        let group = try Self.group(snapshot)

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.coveredDayCount == 0)
        #expect(group.dailyPoints.isEmpty)
    }

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
    func `established Cursor history keeps priced days when another day omits cost`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 1, tokens: 5, model: "claude-4.5-sonnet"),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 7, model: "gpt-5"),
            ],
            last30DaysTokens: 12,
            last30DaysCostUSD: 1)
        let group = try Self.group(inputs: [
            .init(provider: .cursor, displayName: "Cursor", snapshot: snapshot),
        ])

        #expect(snapshot.historyCoverageIsEstablished)
        #expect(group.totalCost == 1)
        #expect(group.totalTokens == 12)
        #expect(group.dailyPoints.map(\.cost) == [1])
    }

    @Test
    func `unestablished Cursor history with an unresolved day keeps spend unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 1, tokens: 5, model: "claude-4.5-sonnet"),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 7, model: "gpt-5"),
            ],
            historyCoverageIsEstablished: false,
            last30DaysTokens: 12,
            last30DaysCostUSD: 1)
        let group = try Self.group(inputs: [
            .init(provider: .cursor, displayName: "Cursor", snapshot: snapshot),
        ])

        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(group.totalCost == nil)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `established Cursor history retains priced days when some events omit total cents`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "claude-4.5-sonnet"),
                Self.entry(day: "2026-07-16", cost: nil, tokens: 40, model: "gpt-5"),
            ],
            last30DaysTokens: 70,
            last30DaysCostUSD: 3)
        let group = try Self.group(inputs: [
            .init(provider: .cursor, displayName: "Cursor", snapshot: snapshot),
        ])

        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 70)
        #expect(group.dailyPoints.map(\.cost) == [3])
        #expect(group.modelHistoryCompleteness == .incomplete)
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

    @Test
    func `priced subscription keeps group spend when peers lack prices`() throws {
        let priced = Self.snapshot(
            entries: [Self.entry(day: "2026-07-15", cost: 4, tokens: 40, model: "gpt-5.4-mini")],
            last30DaysTokens: 40,
            last30DaysCostUSD: 4)
        let unpriced = Self.snapshot(
            entries: [Self.entry(day: "2026-07-15", cost: nil, tokens: 100, model: "deepseek-v4-flash")],
            last30DaysTokens: 100,
            last30DaysCostUSD: nil)
        let group = try Self.group(inputs: [
            .init(provider: .codex, displayName: "Codex", snapshot: priced),
            .init(provider: .claude, displayName: "Claude", snapshot: unpriced),
            .init(provider: .cursor, displayName: "Cursor", snapshot: unpriced),
        ])

        #expect(group.totalCost == 4)
        #expect(group.totalTokens == 240)
        #expect(group.hasPartialCost)
        #expect(!group.hasPartialTokens)
        #expect(group.pricedProviderCount == 1)
        #expect(group.providers.count == 3)
        #expect(group.providers.map(\SpendDashboardModel.ProviderRow.totalCost) == [4, nil, nil])
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.map(\.modelName) == ["gpt-5.4-mini", "deepseek-v4-flash", "deepseek-v4-flash"])
        #expect(group.models.map(\.totalCost) == [4, nil, nil])
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardGroupCostText(group).hasPrefix("~"))
            #expect(spendDashboardGroupTokenText(group) == "240")
            #expect(spendDashboardPartialSubscriptionsText(group) == "1 of 3 subscriptions have spend")
            #expect(spendDashboardHistoryCaption(group, requestedDays: 30).contains("Partial estimate"))
        }
    }

    @Test
    func `all unpriced subscriptions keep group spend unavailable`() throws {
        let unpriced = Self.snapshot(
            entries: [Self.entry(day: "2026-07-15", cost: nil, tokens: 100, model: "deepseek-v4-flash")],
            last30DaysTokens: 100,
            last30DaysCostUSD: nil)
        let group = try Self.group(inputs: [
            .init(provider: .claude, displayName: "Claude", snapshot: unpriced),
            .init(provider: .cursor, displayName: "Cursor", snapshot: unpriced),
        ])

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == 200)
        #expect(!group.hasPartialCost)
        #expect(!group.hasPartialTokens)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.map(\.modelName) == ["deepseek-v4-flash", "deepseek-v4-flash"])
        #expect(group.models.map(\.totalCost) == [nil, nil])
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardGroupCostText(group) == "Spend unavailable")
        }
    }

    @Test
    func `unpriced named models stay listed when spend is unavailable`() throws {
        let snapshot = Self.snapshot(
            entries: [Self.entry(day: "2026-07-15", cost: nil, tokens: 100, model: "deepseek-v4-flash")],
            last30DaysTokens: 100,
            last30DaysCostUSD: nil)
        let group = try Self.group(inputs: [
            .init(provider: .claude, displayName: "Claude", snapshot: snapshot),
        ])

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == 100)
        #expect(group.models.map(\.modelName) == ["deepseek-v4-flash"])
        #expect(group.models.map(\.totalCost) == [nil])
        #expect(group.models.map(\.totalTokens) == [100])
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
    }

    @Test
    func `model-less unpriced history stays unavailable instead of listing a lower bound`() throws {
        let modelLess = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let group = try Self.group(inputs: [
            .init(
                provider: .claude,
                displayName: "Claude",
                snapshot: Self.snapshot(
                    entries: [modelLess],
                    last30DaysTokens: 100,
                    last30DaysCostUSD: nil)),
        ])

        #expect(group.totalCost == nil)
        #expect(group.models.isEmpty)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(spendDashboardModelHistoryPresentation(group) == .unavailable)
    }

    @Test
    func `provider breakdown groups accounts and models without inventing account attribution`() throws {
        let group = try Self.group(inputs: [
            .init(
                id: "codex-one",
                provider: .codex,
                displayName: "Codex · #1",
                modelProviderName: "Codex",
                snapshot: Self.snapshot(
                    entries: [Self.entry(day: "2026-07-15", cost: 4, tokens: 40, model: "model-one")],
                    last30DaysTokens: 40,
                    last30DaysCostUSD: 4)),
            .init(
                id: "codex-two",
                provider: .codex,
                displayName: "Codex · #2",
                modelProviderName: "Codex",
                snapshot: Self.snapshot(
                    entries: [Self.entry(day: "2026-07-16", cost: nil, tokens: 20, model: "model-two")],
                    last30DaysTokens: 20,
                    last30DaysCostUSD: nil)),
            .init(
                provider: .cursor,
                displayName: "Cursor",
                snapshot: Self.snapshot(
                    entries: [Self.entry(day: "2026-07-15", cost: 3, tokens: 30, model: "cursor-model")],
                    last30DaysTokens: 30,
                    last30DaysCostUSD: 3)),
        ])

        let breakdowns = spendDashboardProviderBreakdowns(group)
        let codex = try #require(breakdowns.first { $0.provider == .codex })
        #expect(codex.subscriptions.map(\.displayName) == ["Codex · #1", "Codex · #2"])
        #expect(codex.models.map(\.modelName) == ["model-one", "model-two"])
        #expect(codex.totalCost == 4)
        #expect(codex.totalTokens == 60)
        #expect(codex.hasPartialCost)
        #expect(!codex.hasPartialTokens)
        #expect(codex.hasPartialModelHistory)
        let cursor = try #require(breakdowns.first { $0.provider == .cursor })
        #expect(!cursor.hasPartialModelHistory)
    }

    private static func group(_ snapshot: CostUsageTokenSnapshot) throws -> SpendDashboardModel.CurrencyGroup {
        try self.group(inputs: [.init(provider: .codex, displayName: "Codex", snapshot: snapshot)])
    }

    private static func group(
        inputs: [SpendDashboardModel.ProviderInput]) throws -> SpendDashboardModel.CurrencyGroup
    {
        try #require(SpendDashboardModel.build(
            inputs: inputs,
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
