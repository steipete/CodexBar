import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MiniMaxMenuCardBillingTests {
    @Test
    func `minimax billing history renders inline dashboard`() throws {
        let now = Date()
        let billing = MiniMaxBillingSummary(
            todayTokens: 1234,
            last30DaysTokens: 5678,
            todayCash: 1.5,
            last30DaysCash: 4.25,
            daily: [
                MiniMaxBillingDay(day: "2026-05-16", tokens: 1111, cash: 2.75),
                MiniMaxBillingDay(day: "2026-05-17", tokens: 1234, cash: 1.5),
            ],
            topMethods: [MiniMaxBillingBreakdown(name: "chat", tokens: 2345, cash: 4.25)],
            topModels: [MiniMaxBillingBreakdown(name: "MiniMax-M1", tokens: 2345, cash: 4.25)],
            updatedAt: now)
        let minimax = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "text-generation",
                    windowType: "Today",
                    timeRange: "2026/05/17 00:00 - 2026/05/18 00:00",
                    usage: 2,
                    limit: 10,
                    percent: 20,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
            ],
            billingSummary: billing)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
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
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.accessibilityLabel == "MiniMax 30 day token usage trend")
        #expect(model.inlineUsageDashboard?.kpis.first?.value == "1.2K")
        #expect(model.inlineUsageDashboard?.points.count == 2)
        #expect(model.usageNotes.contains("Last 30 days: 5.7K tokens"))

        let hiddenModel = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
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
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: now))

        #expect(hiddenModel.inlineUsageDashboard == nil)
        #expect(!hiddenModel.usageNotes.contains("Last 30 days: 5.7K tokens"))
    }
}
