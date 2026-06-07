import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CursorMenuCardModelTests {
    @Test
    func `cursor billing cycle metrics show deficit and run out details`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let cycleMinutes = 30 * 24 * 60
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            secondary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
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

        #expect(model.metrics.map(\.title) == ["Total", "Auto", "API"])
        for metric in model.metrics {
            #expect(metric.percentLabel == "10% left")
            #expect(metric.detailLeftText == "10% in deficit")
            #expect(metric.detailRightText == "Runs out in 2d 16h")
            #expect(metric.pacePercent == 20)
            #expect(metric.paceOnTop == false)
        }
    }
}
