import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct XquikMenuCardTests {
    @Test
    func `menu card shows the exact credit balance`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.xquik])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "50,000 credits available"),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .xquik,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "API key"))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .xquik,
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

        #expect(model.creditsText == nil)
        #expect(model.metrics.map(\.title) == ["Credits"])
        #expect(model.metrics.first?.percent == 100)
        #expect(model.metrics.first?.resetText == nil)
        #expect(model.metrics.first?.statusText == "50,000 credits available")
        #expect(model.metrics.first?.detailRightText == nil)
    }
}
