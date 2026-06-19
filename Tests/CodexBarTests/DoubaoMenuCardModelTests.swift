import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct DoubaoMenuCardModelTests {
    @Test
    func `unknown request limit renders unavailable instead of full quota`() throws {
        let now = Date(timeIntervalSince1970: 1_742_771_200)
        let metadata = try #require(ProviderDefaults.metadata[.doubao])
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: now,
            apiKeyValid: true,
            requestLimitsReliable: false)
            .toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .doubao,
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

        #expect(model.metrics.isEmpty)
        #expect(model.placeholder == "Limits not available")
        #expect(model.subtitleStyle == .info)
    }
}
