import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeWeeklyOnlyPlanTests {
    @Test
    func `parse claude status weekly only plan has no session`() throws {
        // Plans without a 5-hour limit render no "Current session" row; the weekly percent must not be
        // promoted into the session slot by the order-based fallback.
        let sample = """
        Settings:  Status   Config   Usage
        Current week (all models)
        █████                                              10% used
        Resets Nov 9 at 9am (America/New_York)
        Current week (Sonnet only)
        ▌                                                  1% used
        Resets Nov 9 at 9am (America/New_York)
        """
        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.sessionPercentLeft == nil)
        #expect(snap.primaryResetDescription == nil)
        #expect(snap.weeklyPercentLeft == 90)
        #expect(snap.opusPercentLeft == 99)
    }

    @Test
    func `weekly only claude plan shows weekly row without a session row`() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let weekly = RateWindow(
            usedPercent: 12,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            resetDescription: nil)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: weekly, updatedAt: now),
            credits: nil,
            creditsError: nil,
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

        #expect(model.metrics.map(\.id) == ["secondary"])
        #expect(model.metrics.first?.title == metadata.weeklyLabel)
    }
}
