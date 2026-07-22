import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CrofMenuCardTests {
    @Test
    func `model shows credit balance without request quota`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.crof])
        let snapshot = CrofUsageSnapshot(
            credits: 10,
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
        #expect(model.metrics.map(\.title) == ["Credits"])
        #expect(model.metrics.first?.percent == 100)
        #expect(model.metrics.first?.resetText == nil)
        #expect(model.metrics.first?.statusText == "$10.00")
        #expect(model.metrics.first?.detailRightText == nil)
    }
}
