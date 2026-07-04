import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct DoubaoMenuCardModelTests {
    @Test
    func `coding plan monthly quota shows deficit and run out details`() throws {
        let now = Date(timeIntervalSince1970: 10_368_000) // 1970-05-01T00:00:00Z
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 5 * 60,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 90,
                windowMinutes: 30 * 24 * 60,
                resetsAt: reset,
                resetDescription: nil),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.doubao])

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

        #expect(model.metrics.map(\.title) == ["5-hour", "Weekly", "Monthly"])
        let monthly = try #require(model.metrics.first { $0.id == "tertiary" })
        #expect(monthly.percentLabel == "10% left")
        #expect(monthly.detailLeftText == "10% in deficit")
        #expect(monthly.detailRightText == "Runs out in 2d 16h")
        #expect(monthly.pacePercent == 20)
        #expect(monthly.paceOnTop == false)
    }

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
