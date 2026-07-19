import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardKiloPassTests {
    @Test
    func `kilo model shows pass before credits and keeps reset with detail`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.kilo])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "0/19 credits"),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(27 * 24 * 60 * 60),
                resetDescription: "$0.00 / $19.00 (+ $9.50 bonus)"),
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .kilo,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Starter · Auto top-up: off"))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kilo,
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

        #expect(model.metrics.prefix(2).map(\.id) == ["secondary", "primary"])
        let passMetric = try #require(model.metrics.first)
        #expect(passMetric.title == "Kilo Pass")
        #expect(passMetric.resetText != nil)
        #expect(passMetric.detailText == "$0.00 / $19.00 (+ $9.50 bonus)")
    }
}
