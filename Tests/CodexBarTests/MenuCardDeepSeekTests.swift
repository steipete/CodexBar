import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardDeepSeekTests {
    @Test
    func `model shows balance as status text instead of percentage detail`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .deepseek,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$9.32 (Paid: $9.32 / Granted: $0.00)"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.deepseek])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .deepseek,
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

        let primary = try #require(model.metrics.first)
        #expect(primary.title == "Balance")
        #expect(primary.statusText == "$9.32 (Paid: $9.32 / Granted: $0.00)")
        #expect(primary.detailText == nil)
        #expect(primary.resetText == nil)
    }
}
