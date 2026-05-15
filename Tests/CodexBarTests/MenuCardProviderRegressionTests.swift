import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardProviderRegressionTests {
    @Test
    func `open router model shows daily and weekly key spend`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.openrouter])
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyLimit: 20,
            keyUsage: 0.5,
            keyUsageDaily: 0.12,
            keyUsageWeekly: 0.74,
            rateLimit: nil,
            updatedAt: now).toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
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
            now: now))

        #expect(model.usageNotes == ["Today: $0.12 · This week: $0.74"])
    }

    @Test
    func `copilot over quota usage keeps used percentage detail`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.copilot])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 115, windowMinutes: nil, resetsAt: nil, resetDescription: "115% used"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: nil)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .copilot,
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
            now: now))

        let metric = try #require(model.metrics.first)
        #expect(metric.percent == 0)
        #expect(metric.percentLabel == "0% left")
        #expect(metric.detailLeftText == "115% used")
    }
}
