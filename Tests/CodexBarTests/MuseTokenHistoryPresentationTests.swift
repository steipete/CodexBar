import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MuseTokenHistoryPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_177_600)

    @Test
    func `token history has token summaries comparisons and chart units while quotas remain visible`() throws {
        let snapshot = self.history()
        let model = try self.model(history: snapshot)
        #expect(model.metrics.map(\.percent) == [96, 40])
        let section = try #require(model.tokenUsage)
        #expect(section.sessionLine == "Today: 300 tokens")
        #expect(section.monthLine == "Last 30 days: 300 tokens")
        #expect(section.meteredLine == nil)
        #expect(section.comparisonLines.allSatisfy { !$0.contains("$") && $0.contains("tokens") })
        #expect(UsageMenuCardView.Model.tokenUsageHeader(provider: .muse) == "Token history")
        #expect(StatusItemController.costMenuTitleForProvider(.muse) == "Token history")
        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.valueStyle == .tokens)
        #expect(dashboard.currencyCode == nil)
        #expect(dashboard.kpis.allSatisfy { !$0.value.contains("$") && !$0.title.lowercased().contains("cost") })
        #expect(dashboard.points.first?.value == 300)
        #expect(dashboard.points.first?.hoverDetail?.tokensOnly == true)
        #expect(dashboard.points.first?.hoverDetail?.cost == nil)
        #expect(dashboard.points.first?.accessibilityValue.contains("300 tokens") == true)
        #expect(dashboard.detailLines.contains { $0.contains("dollar costs unavailable") })
    }

    @Test
    func `partial token history retains the recorded subtotal with explicit coverage`() throws {
        let model = try self.model(history: self.history(complete: false))
        let section = try #require(model.tokenUsage)
        #expect(section.monthLine == "Last 30 days: 300 tokens")
        #expect(section.hintLine?.contains("Partial local history") == true)
        #expect(model.inlineUsageDashboard?.detailLines.contains { $0.contains("Partial local history") } == true)
    }

    @Test
    func `incomplete only token days cannot create a cost metric`() {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-08-31",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: [.init(
                modelName: "unknown",
                costUSD: nil,
                totalTokens: nil,
                incompleteRequestCount: 1)],
            unmeteredRequestCount: 1)
        #expect(CostHistoryChartMenuView._availableMetricsForTesting(provider: .muse, daily: [entry]) == [.tokens])
        #expect(CostHistoryChartMenuView._defaultMetricForTesting(provider: .muse, daily: []) == .tokens)
        #expect(CostHistoryChartMenuView._chartValuesForTesting(provider: .muse, daily: [entry], metric: .cost).isEmpty)
    }

    @Test
    func `unpriced local history never manufactures zero dollar totals`() {
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: CostUsageDailyReport(data: [], summary: nil),
            now: self.now,
            monetaryValuesAreAvailable: false)
        #expect(snapshot.sessionTokens == 0)
        #expect(snapshot.last30DaysTokens == 0)
        #expect(snapshot.sessionCostUSD == nil)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.meteredCostUSD == nil)
    }

    private func history(complete: Bool = true) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 300,
            sessionCostUSD: nil,
            last30DaysTokens: 300,
            last30DaysCostUSD: nil,
            historyCoverageIsEstablished: complete,
            daily: [.init(
                date: "2026-08-31",
                inputTokens: 200,
                outputTokens: 100,
                totalTokens: 300,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: self.now)
    }

    private func model(history: CostUsageTokenSnapshot) throws -> UsageMenuCardView.Model {
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 96, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .muse,
                accountEmail: "fixture@example.com",
                accountOrganization: nil,
                loginMethod: "Muse Code Power Usage"))
        return try UsageMenuCardView.Model.make(.init(
            provider: .muse,
            metadata: #require(ProviderDefaults.metadata[.muse]),
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: history,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: "Muse Code Power Usage"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costComparisonPeriodsEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: self.now))
    }
}
