import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OverviewSpendSummaryTests {
    @Test
    func `summary marks incomplete provider coverage as partial`() {
        let group = self.group(
            providers: [
                self.provider(.codex, tokens: 4_800_000, cost: 412.64),
                self.provider(.claude, tokens: nil, cost: nil),
                self.provider(.openrouter, tokens: 9_640_000, cost: 282.74),
                self.provider(.cursor, tokens: 1_250_000, cost: 64.18),
            ],
            totalTokens: 15_690_000,
            totalCost: 759.56,
            coverage: CostUsageCoverageCounts(priced: 3, unpriced: 1))

        let summary = OverviewSpendSummary(
            model: SpendDashboardModel(requestedDays: 30, groups: [group]),
            providerCount: 4)

        #expect(summary.primarySpendText == "~$759.56")
        #expect(summary.providerCoverageText == "3 of 4 subscriptions have spend")
        #expect(summary.tokenText == "~15.7M tokens")
        #expect(summary.historyCoverageText == "Coverage: 30 / 30")
        #expect(summary.pricingCoverageText == "Priced 3 · Unpriced 1 · Unmetered 0 · Estimated 0")
        #expect(summary.provenanceText == "List-price equivalent")
        #expect(summary.isPartial)
    }

    @Test
    func `summary keeps distinct currencies separate`() {
        let usd = self.group(
            currencyCode: "USD",
            providers: [self.provider(.codex, tokens: 1000, cost: 12)],
            totalTokens: 1000,
            totalCost: 12,
            coveredDayCount: 7)
        let eur = self.group(
            currencyCode: "EUR",
            providers: [self.provider(.claude, tokens: 2000, cost: 8)],
            totalTokens: 2000,
            totalCost: 8,
            coveredDayCount: 7,
            provenance: .vendorMetered)

        let summary = OverviewSpendSummary(
            model: SpendDashboardModel(requestedDays: 7, groups: [eur, usd]),
            providerCount: 2)

        #expect(summary.primarySpendText.contains("$12.00"))
        #expect(summary.primarySpendText.contains("€8.00"))
        #expect(summary.providerCoverageText == "2 of 2 subscriptions have spend")
        #expect(summary.tokenText == "3K tokens")
        #expect(summary.historyCoverageText == "Coverage: 7 / 7")
        #expect(summary.provenanceText == "Plan metered · List-price equivalent")
        #expect(!summary.isPartial)
    }

    @Test
    func `summary keeps wholly unpriced spend unavailable`() {
        let group = self.group(
            providers: [self.provider(.claude, tokens: 2000, cost: nil)],
            totalTokens: 2000,
            totalCost: nil,
            coverage: CostUsageCoverageCounts(unpriced: 1),
            provenance: .unknown)

        let summary = OverviewSpendSummary(
            model: SpendDashboardModel(requestedDays: 30, groups: [group]),
            providerCount: 1)

        #expect(summary.primarySpendText == "Spend unavailable")
        #expect(summary.providerCoverageText == "0 of 1 subscriptions have spend")
        #expect(summary.pricingCoverageText == "Priced 0 · Unpriced 1 · Unmetered 0 · Estimated 0")
        #expect(summary.provenanceText == "Spend unavailable")
        #expect(!summary.isPartial)
    }

    @Test
    func `summary marks a missing selected provider as partial`() {
        let group = self.group(
            providers: [self.provider(.codex, tokens: 1000, cost: 12)],
            totalTokens: 1000,
            totalCost: 12)

        let summary = OverviewSpendSummary(
            model: SpendDashboardModel(requestedDays: 30, groups: [group]),
            providerCount: 2)

        #expect(summary.primarySpendText == "~$12.00")
        #expect(summary.providerCoverageText == "1 of 2 subscriptions have spend")
        #expect(summary.tokenText == "~1K tokens")
        #expect(summary.historyCoverageText == "Coverage: 30 / 30")
        #expect(summary.isPartial)
    }

    @Test
    func `six selected providers sum only finite eligible spend and remain partial`() {
        let group = self.group(
            providers: [
                self.provider(.claude, tokens: 2_000_000, cost: 35.09),
                self.provider(.openrouter, tokens: nil, cost: 39.79),
            ],
            totalTokens: 2_000_000,
            totalCost: 35.09 + 39.79,
            coverage: CostUsageCoverageCounts(priced: 2),
            provenance: .vendorMetered)

        let summary = OverviewSpendSummary(
            model: SpendDashboardModel(requestedDays: 30, groups: [group]),
            providerCount: 6)

        #expect((35.09 + 39.79).isFinite)
        #expect(summary.primarySpendText == "~$74.88")
        #expect(summary.providerCoverageText == "2 of 6 subscriptions have spend")
        #expect(summary.tokenText == "~2M tokens")
        #expect(summary.historyCoverageText == "Coverage: 30 / 30")
        #expect(summary.pricingCoverageText == "Priced 2 · Unpriced 0 · Unmetered 0 · Estimated 0")
        #expect(summary.provenanceText == "Plan metered")
        #expect(summary.isPartial)
    }

    private func provider(
        _ provider: UsageProvider,
        tokens: Int?,
        cost: Double?) -> SpendDashboardModel.ProviderRow
    {
        SpendDashboardModel.ProviderRow(
            id: provider.rawValue,
            rank: 1,
            provider: provider,
            displayName: provider.rawValue,
            totalTokens: tokens,
            totalCost: cost,
            coveredDayCount: 30)
    }

    private func group(
        currencyCode: String = "USD",
        providers: [SpendDashboardModel.ProviderRow],
        totalTokens: Int?,
        totalCost: Double?,
        coveredDayCount: Int = 30,
        coverage: CostUsageCoverageCounts? = nil,
        provenance: CostProvenance = .listPriceEstimate) -> SpendDashboardModel.CurrencyGroup
    {
        SpendDashboardModel.CurrencyGroup(
            currencyCode: currencyCode,
            providers: providers,
            models: [],
            projects: [],
            dailyPoints: [],
            totalTokens: totalTokens,
            totalCost: totalCost,
            coveredDayCount: coveredDayCount,
            chartDomain: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 86400),
            modelHistoryCompleteness: totalCost == nil ? .incomplete : .complete,
            coverage: coverage ?? CostUsageCoverageCounts(priced: providers.count),
            provenance: provenance)
    }
}
