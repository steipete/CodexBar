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
    func `Antigravity day with unpriced requests keeps its spend but marks it partial`() throws {
        // The reader sums the priced models into the day's cost, so the total stays available;
        // the unpriced requests make it a floor, which the UI must show as `~`.
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: 2,
            modelsUsed: nil,
            modelBreakdowns: [
                .init(modelName: "gemini-3.8-flash", costUSD: 2, totalTokens: 60),
                .init(modelName: "unknown", costUSD: nil, totalTokens: 40),
            ],
            unpricedRequestCount: 1,
            estimatedRequestCount: 1)
        let snapshot = Self.snapshot(
            entries: [entry],
            last30DaysTokens: 100,
            last30DaysCostUSD: 2,
            costProvenance: .listPriceEstimate)
        let group = try Self.group(inputs: [
            .init(provider: .antigravity, displayName: "Antigravity", snapshot: snapshot),
        ])

        #expect(group.totalCost == 2)
        #expect(group.dailyPoints.map(\.cost) == [2])
        #expect(group.hasPartialCost)
        #expect(group.hasUnpricedProviders == false)
        #expect(group.models.map(\.modelName) == ["gemini-3.8-flash", "unknown"])
        #expect(group.models.first?.totalCost == 2)
        #expect(group.models.last?.totalCost == nil)
    }

    @Test
    func `a truncated Antigravity scan marks cost and tokens as lower bounds`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: 2,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "gemini-3.8-flash", costUSD: 2, totalTokens: 100)],
            unpricedRequestCount: 0,
            estimatedRequestCount: 1)
        // What a truncated local scan really produces: rows, but no claim over the window.
        let snapshot = Self.snapshot(
            entries: [entry],
            historyCoverageIsEstablished: false,
            last30DaysTokens: 100,
            last30DaysCostUSD: 2,
            costProvenance: .listPriceEstimate,
            historyScanIsPartial: true)
        let group = try Self.group(inputs: [
            .init(provider: .antigravity, displayName: "Antigravity", snapshot: snapshot),
        ])

        #expect(group.totalCost == 2)
        #expect(group.totalTokens == 100)
        #expect(group.hasPartialCost)
        #expect(group.hasPartialTokens)
        #expect(group.dailySummaries.contains { $0.hasPartialCost })
        #expect(group.dailySummaries.contains { !$0.hasPartialCost } == false)
    }

    @Test
    func `a partial Antigravity scan retains its priced subtotal beside an unpriced day`() throws {
        let priced = Self.entry(day: "2026-07-15", cost: 2, tokens: 60, model: "gemini-3.8-flash")
        let unpriced = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 40,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "unknown", costUSD: nil, totalTokens: 40)],
            unpricedRequestCount: 1,
            estimatedRequestCount: 1)
        let snapshot = Self.snapshot(
            entries: [priced, unpriced],
            historyCoverageIsEstablished: false,
            last30DaysTokens: 100,
            last30DaysCostUSD: 2,
            costProvenance: .listPriceEstimate,
            historyScanIsPartial: true)

        let group = try Self.group(inputs: [
            .init(provider: .antigravity, displayName: "Antigravity", snapshot: snapshot),
        ])

        #expect(group.totalCost == 2)
        #expect(group.hasPartialCost)
        #expect(group.dailyPoints.map(\.cost) == [2])
    }

    @Test
    func `a partial scan does not render an unread gap as zero tokens`() throws {
        let snapshot = Self.snapshot(
            entries: [
                Self.entry(day: "2026-07-14", cost: 2, tokens: 60, model: "gemini-3.8-flash"),
                Self.entry(day: "2026-07-16", cost: 1, tokens: 40, model: "gemini-3.8-flash"),
            ],
            historyCoverageIsEstablished: false,
            last30DaysTokens: 100,
            last30DaysCostUSD: 3,
            costProvenance: .listPriceEstimate,
            historyScanIsPartial: true,
            historyDays: 3)

        let group = try Self.group(inputs: [
            .init(provider: .antigravity, displayName: "Antigravity", snapshot: snapshot),
        ])

        let missingDay = try #require(group.dailySummaries.first { $0.totalTokens == nil })
        #expect(missingDay.totalTokens == nil)
        #expect(missingDay.providers.first?.totalTokens == nil)
    }

    @Test
    func `a complete Antigravity scan without unpriced requests reports an exact total`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            costUSD: 2,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "gemini-3.8-flash", costUSD: 2, totalTokens: 100)],
            unpricedRequestCount: 0,
            estimatedRequestCount: 1)
        let snapshot = Self.snapshot(
            entries: [entry],
            last30DaysTokens: 100,
            last30DaysCostUSD: 2,
            costProvenance: .listPriceEstimate)
        let group = try Self.group(inputs: [
            .init(provider: .antigravity, displayName: "Antigravity", snapshot: snapshot),
        ])

        #expect(group.totalCost == 2)
        #expect(group.hasPartialCost == false)
        #expect(group.hasPartialTokens == false)
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
            #expect(spendDashboardProviderCountTitle(group) == "Subscriptions")
            #expect(spendDashboardProviderPanelTitle(group) == "By subscription")
            #expect(spendDashboardPartialSourceCoverageText(group) == "1 of 3 subscriptions have spend")
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

    @Test(arguments: [UsageProvider.claude, .pi])
    func `provider hierarchy retains incomplete source and model rows beside known subtotals`(
        provider: UsageProvider) throws
    {
        let pending = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: ["fixture-pending"],
            modelBreakdowns: [.init(
                modelName: "fixture-pending", costUSD: nil, totalTokens: nil, incompleteRequestCount: 2)])
        let group = try Self.group(inputs: [
            .init(
                id: "known-source",
                provider: provider,
                displayName: "Known source",
                snapshot: Self.snapshot(
                    entries: [Self.entry(day: "2026-07-15", cost: 4, tokens: 40, model: "fixture-known")],
                    last30DaysTokens: 40,
                    last30DaysCostUSD: 4)),
            .init(
                id: "pending-source",
                provider: provider,
                displayName: "Pending source",
                snapshot: Self.snapshot(entries: [pending], last30DaysTokens: nil, last30DaysCostUSD: nil),
                sourceKind: provider == .pi ? .localHistory : .native),
        ])
        let breakdown = try #require(spendDashboardProviderBreakdowns(group).first)
        #expect(Set(breakdown.subscriptions.map(\.id)) == ["known-source", "pending-source"])
        #expect(breakdown.totalCost == 4)
        #expect(breakdown.totalTokens == 40)
        #expect(breakdown.incompleteRequestCount == 2)
        #expect(breakdown.hasPartialCost && breakdown.hasPartialTokens && breakdown.hasPartialModelHistory)
        let pendingModel = try #require(breakdown.models.first { $0.modelName == "fixture-pending" })
        #expect(pendingModel.totalCost == nil)
        #expect(pendingModel.totalTokens == nil)
        #expect(pendingModel.incompleteRequestCount == 2)
        if provider == .pi {
            #expect(breakdown.subscriptions.first { $0.id == "pending-source" }?.sourceKind == .localHistory)
            #expect(spendDashboardProviderCountTitle(group) == L("Sources"))
        }
    }

    @Test
    func `provider model expansion retains incomplete rows beyond the initial display limit`() throws {
        var models = (1...8).map {
            CostUsageDailyReport.ModelBreakdown(modelName: "fixture-model-\($0)", costUSD: 1, totalTokens: 10)
        }
        models.append(.init(modelName: "fixture-incomplete", costUSD: nil, totalTokens: nil, incompleteRequestCount: 2))
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: 80,
            outputTokens: 0,
            totalTokens: 80,
            costUSD: 8,
            modelsUsed: nil,
            modelBreakdowns: models)
        let group = try Self.group(Self.snapshot(entries: [entry], last30DaysTokens: 80, last30DaysCostUSD: 8))
        let provider = try #require(spendDashboardProviderBreakdowns(group).first)
        #expect(provider.models.count == 9)
        #expect(provider.modelCount == 9)
        #expect(provider.models.last?.modelName == "fixture-incomplete")
        #expect(provider.models.last?.incompleteRequestCount == 2)
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
        last30DaysCostUSD: Double?,
        costProvenance: CostProvenance = .unknown,
        historyScanIsPartial: Bool = false,
        historyDays: Int = 2) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: historyDays,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            historyScanIsPartial: historyScanIsPartial,
            costProvenance: costProvenance,
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
