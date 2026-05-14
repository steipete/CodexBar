import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardCostHintTests {
    @Test
    func `claude cost hint explains cache tokens and status line drift`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 1.23,
            last30DaysTokens: 456,
            last30DaysCostUSD: 78.9,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-14",
                    inputTokens: 1,
                    outputTokens: 2,
                    cacheReadTokens: 300,
                    cacheCreationTokens: 400,
                    totalTokens: 703,
                    costUSD: 1.23,
                    modelsUsed: ["claude-sonnet-4-6"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: snapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.tokenUsage?.hintLine?.contains("cache read/write tokens") == true)
        #expect(model.tokenUsage?.hintLine?.contains("Claude Code /status") == true)
    }
}
