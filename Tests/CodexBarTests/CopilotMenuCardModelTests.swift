import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct CopilotMenuCardModelTests {
    @Test
    func `hides copilot budget bars when budget extras are disabled`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "copilot-budget-agent",
                    title: "Budget - Copilot Agent Premium Requests",
                    window: RateWindow(usedPercent: 65, windowMinutes: nil, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.copilot])
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

        #expect(model.metrics.map(\.title) == ["Premium", "Chat"])
    }
}
