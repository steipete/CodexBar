import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CrofMenuCardTests {
    @Test
    func `model shows request count and avoids duplicate credits section`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.crof])
        let snapshot = CrofUsageSnapshot(
            credits: 10,
            requestsPlan: 1000,
            usableRequests: 998,
            updatedAt: now).toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .crof,
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
        #expect(model.metrics.map(\.title) == ["Requests", "Credits"])
        #expect(model.metrics.first?.percent == 99)
        #expect(model.metrics.first?.resetText?.hasPrefix("Resets") == true)
        #expect(model.metrics.first?.detailRightText == "998 requests left")
        #expect(model.metrics.last?.resetText == "$10.00")
    }
}
