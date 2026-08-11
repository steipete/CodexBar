import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OverviewTokenAllocationTests {
    @Test
    func `known provider tokens produce overflow safe ordered allocation percentages`() throws {
        let allocation = try #require(OverviewTokenAllocation(
            model: Self.model(groups: [
                Self.group(currencyCode: "USD", rows: [
                    Self.row(id: "codex", provider: .codex, tokens: 3_000_000, cost: 6),
                    Self.row(id: "claude", provider: .claude, tokens: 9_000_000, cost: 18),
                ]),
            ]),
            trackedProviders: [.codex, .claude]))

        #expect(allocation.knownTotalTokens == 12_000_000)
        #expect(!allocation.isPartial)
        #expect(allocation.rows.map(\.id) == ["codex", "claude"])
        #expect(allocation.rows[0].tokenCount == 3_000_000)
        #expect(try abs(#require(allocation.rows[0].tokenFraction) - 0.25) < 0.000_001)
        #expect(try abs(#require(allocation.rows[1].tokenFraction) - 0.75) < 0.000_001)
    }

    @Test
    func `missing tokens and absent tracked providers make allocation partial without fabricating zero`() throws {
        let allocation = try #require(OverviewTokenAllocation(
            model: Self.model(groups: [
                Self.group(currencyCode: "USD", rows: [
                    Self.row(id: "codex", provider: .codex, tokens: 4_000_000, cost: 8),
                    Self.row(id: "claude", provider: .claude, tokens: nil, cost: 12),
                ]),
            ]),
            trackedProviders: [.codex, .claude, .openrouter]))

        #expect(allocation.knownTotalTokens == 4_000_000)
        #expect(allocation.isPartial)
        #expect(allocation.rows.count == 2)
        #expect(allocation.rows[0].tokenFraction == 1)
        #expect(allocation.rows[1].tokenCount == nil)
        #expect(allocation.rows[1].tokenFraction == nil)
        #expect(allocation.rows[1].costPerMillionTokens == nil)
    }

    @Test
    func `cost per million stays on the same provider row and preserves currency`() throws {
        let allocation = try #require(OverviewTokenAllocation(
            model: Self.model(groups: [
                Self.group(currencyCode: "USD", rows: [
                    Self.row(id: "codex", provider: .codex, tokens: 2_000_000, cost: 10),
                    Self.row(id: "claude", provider: .claude, tokens: 0, cost: 9),
                    Self.row(id: "gemini", provider: .gemini, tokens: 1_000_000, cost: nil),
                    Self.row(id: "grok", provider: .grok, tokens: 1_000_000, cost: -3),
                    Self.row(id: "cursor", provider: .cursor, tokens: 1_000_000, cost: .infinity),
                ]),
                Self.group(currencyCode: "EUR", rows: [
                    Self.row(id: "openrouter", provider: .openrouter, tokens: 4_000_000, cost: 12),
                ]),
            ]),
            trackedProviders: [.codex, .claude, .gemini, .grok, .cursor, .openrouter]))

        let codexRate = try #require(allocation.rows.first { $0.id == "codex" }?.costPerMillionTokens)
        #expect(abs(codexRate.amount - 5) < 0.000_001)
        #expect(codexRate.currencyCode == "USD")

        let openRouterRate = try #require(allocation.rows.first { $0.id == "openrouter" }?.costPerMillionTokens)
        #expect(abs(openRouterRate.amount - 3) < 0.000_001)
        #expect(openRouterRate.currencyCode == "EUR")

        for id in ["claude", "gemini", "grok", "cursor"] {
            #expect(allocation.rows.first { $0.id == id }?.costPerMillionTokens == nil)
        }
    }

    @Test
    func `short provider coverage keeps allocation available but partial`() throws {
        let allocation = try #require(OverviewTokenAllocation(
            model: Self.model(groups: [
                Self.group(currencyCode: "USD", rows: [
                    Self.row(
                        id: "codex",
                        provider: .codex,
                        tokens: 2_000_000,
                        cost: 10,
                        coveredDayCount: 8),
                ], coveredDayCount: 8),
            ]),
            trackedProviders: [.codex]))

        #expect(allocation.knownTotalTokens == 2_000_000)
        #expect(allocation.rows.first?.tokenFraction == 1)
        #expect(allocation.isPartial)
    }

    @Test
    func `zero invalid and overflowing token totals fail closed`() {
        let zero = OverviewTokenAllocation(
            model: Self.model(groups: [
                Self.group(currencyCode: "USD", rows: [
                    Self.row(id: "codex", provider: .codex, tokens: 0, cost: 1),
                ]),
            ]),
            trackedProviders: [.codex])
        #expect(zero == nil)

        let negative = OverviewTokenAllocation(
            model: Self.model(groups: [
                Self.group(currencyCode: "USD", rows: [
                    Self.row(id: "codex", provider: .codex, tokens: -1, cost: 1),
                ]),
            ]),
            trackedProviders: [.codex])
        #expect(negative == nil)

        let overflow = OverviewTokenAllocation(
            model: Self.model(groups: [
                Self.group(currencyCode: "USD", rows: [
                    Self.row(id: "codex", provider: .codex, tokens: Int.max, cost: 1),
                    Self.row(id: "claude", provider: .claude, tokens: 1, cost: 1),
                ]),
            ]),
            trackedProviders: [.codex, .claude])
        #expect(overflow == nil)
    }

    @Test
    func `duplicate account rows cannot hide a missing tracked provider`() throws {
        let model = Self.model(groups: [
            Self.group(currencyCode: "USD", rows: [
                Self.row(id: "codex-primary", provider: .codex, tokens: 2_000_000, cost: 4),
                Self.row(id: "codex-secondary", provider: .codex, tokens: 1_000_000, cost: 2),
            ]),
        ])
        let allocation = try #require(OverviewTokenAllocation(
            model: model,
            trackedProviders: [.codex, .claude]))
        let summary = OverviewSpendSummary(model: model, trackedProviders: [.codex, .claude])

        #expect(allocation.knownTotalTokens == 3_000_000)
        #expect(allocation.isPartial)
        #expect(summary.primarySpendText == "~$6.00")
        #expect(summary.coverageText == "1 / 2 Providers")
        #expect(summary.tokenText == "~3M tokens")
        #expect(summary.isPartial)
    }

    @Test
    func `positive sub-cent rates never render as zero`() {
        let tiny = OverviewTokenRateFormatting.text(.init(amount: 0.001, currencyCode: "USD"))
        let zero = OverviewTokenRateFormatting.text(.init(amount: 0, currencyCode: "USD"))

        #expect(tiny == "<$0.01 / 1M")
        #expect(zero == "$0.00 / 1M")
    }

    private static func model(groups: [SpendDashboardModel.CurrencyGroup]) -> SpendDashboardModel {
        SpendDashboardModel(requestedDays: 30, groups: groups)
    }

    private static func group(
        currencyCode: String,
        rows: [SpendDashboardModel.ProviderRow],
        coveredDayCount: Int = 30) -> SpendDashboardModel.CurrencyGroup
    {
        let date = Date(timeIntervalSince1970: 1_785_974_400)
        return SpendDashboardModel.CurrencyGroup(
            currencyCode: currencyCode,
            providers: rows,
            models: [],
            dailyPoints: [],
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: coveredDayCount,
            chartDomain: date...date,
            modelHistoryCompleteness: .incomplete)
    }

    private static func row(
        id: String,
        provider: UsageProvider,
        tokens: Int?,
        cost: Double?,
        coveredDayCount: Int = 30) -> SpendDashboardModel.ProviderRow
    {
        SpendDashboardModel.ProviderRow(
            id: id,
            rank: 1,
            provider: provider,
            displayName: provider.rawValue,
            totalTokens: tokens,
            totalCost: cost,
            coveredDayCount: coveredDayCount)
    }
}
