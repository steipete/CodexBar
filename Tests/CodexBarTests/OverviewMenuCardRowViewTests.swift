import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct OverviewMenuCardRowViewTests {
    @Test
    @MainActor
    func `overview lite summary uses first metric progress`() throws {
        let model = try Self.makeClaudeModel(usedPercent: 25)
        let row = OverviewMenuCardRowView(model: model, storageText: nil, width: 310)

        let summary = try #require(row.liteSummary)
        #expect(summary.progressPercent == 75)
        #expect(summary.progressAccessibilityLabel == "Usage remaining")
    }

    @Test
    @MainActor
    func `overview lite summary uses monitor resolved refreshed model`() throws {
        let staleModel = try Self.makeClaudeModel(usedPercent: 25, updatedAt: Date(timeIntervalSince1970: 1))
        let refreshedModel = try Self.makeClaudeModel(usedPercent: 60, updatedAt: Date(timeIntervalSince1970: 2))
        let monitor = MenuCardRefreshMonitor { provider in
            provider == .claude ? refreshedModel : nil
        }
        let row = OverviewMenuCardRowView(model: staleModel, storageText: nil, width: 310)

        #expect(row.liteSummary?.progressPercent == 75)
        let liveSummary = try #require(row.liteSummary(refreshMonitor: monitor))
        #expect(liveSummary.progressPercent == 40)
    }

    @Test
    @MainActor
    func `overview lite summary ignores inline dashboard only content`() {
        let dashboard = InlineUsageDashboardModel(
            accessibilityLabel: "Claude usage trend",
            valueStyle: .currencyUSD,
            kpis: [
                InlineUsageDashboardModel.KPI(title: "30d", value: "$1.25", emphasis: true),
            ],
            points: [
                InlineUsageDashboardModel.Point(
                    id: "2023-11-14",
                    label: "Nov 14",
                    value: 1.25,
                    accessibilityValue: "2023-11-14: $1.25"),
            ],
            detailLines: ["Top model: claude-sonnet-4"],
            barColor: .orange)
        let model = UsageMenuCardView.Model(
            provider: .claude,
            providerName: "Claude",
            email: "user@example.com",
            subtitleText: "Updated now",
            subtitleStyle: .info,
            planText: "Pro",
            metrics: [],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: dashboard,
            creditsText: nil,
            creditsRemaining: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            codexResetCreditsText: nil,
            codexResetCreditsDetailText: nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .orange)
        let row = OverviewMenuCardRowView(model: model, storageText: nil, width: 310)

        #expect(row.liteSummary == nil)
    }

    private static func makeClaudeModel(
        usedPercent: Double,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: updatedAt.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: updatedAt,
            identity: nil)
        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            usesLiveSubtitle: true,
            now: updatedAt))
    }
}
