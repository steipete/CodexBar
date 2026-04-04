import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardHeaderVisibilityTests {
    @Test
    func `suppresses header email when requested`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "codex@example.com",
            accountOrganization: nil,
            loginMethod: "Pro")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3000),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.codex])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "Pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            showsHeaderEmail: false,
            hidePersonalInfo: false,
            now: now))

        #expect(model.email.isEmpty)
        #expect(model.planText == "Pro")
    }
}
