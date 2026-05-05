import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct GeminiMenuCardTests {
    @Test
    func `gemini model uses flash lite title for tertiary metric`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .gemini,
            accountEmail: "gemini@example.com",
            accountOrganization: nil,
            loginMethod: "Paid")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 1440,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: "Resets in 1h"),
            secondary: RateWindow(
                usedPercent: 25,
                windowMinutes: 1440,
                resetsAt: now.addingTimeInterval(7200),
                resetDescription: "Resets in 2h"),
            tertiary: RateWindow(
                usedPercent: 40,
                windowMinutes: 1440,
                resetsAt: now.addingTimeInterval(10800),
                resetDescription: "Resets in 3h"),
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.gemini])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .gemini,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "gemini@example.com", plan: "Paid"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.map(\.title) == ["Pro", "Flash", "Flash Lite"])
    }
}
