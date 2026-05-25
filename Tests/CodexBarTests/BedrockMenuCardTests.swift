import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct BedrockMenuCardTests {
    @Test
    func `bedrock cost section labels latest billing day`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.bedrock])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: 12.34,
            last30DaysTokens: nil,
            last30DaysCostUSD: 56.78,
            historyDays: 7,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-12",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: 12.34,
                    modelsUsed: ["Amazon Bedrock"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .bedrock,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
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

        #expect(model.tokenUsage?.sessionLine == "Latest billing day (May 12): $12.34")
        #expect(model.tokenUsage?.sessionLine.contains("Today") == false)
        #expect(model.tokenUsage?.monthLine == "Last 7 days: $56.78")
        #expect(model.tokenUsage?.hintLine == "AWS Cost Explorer billing can lag.")
    }
}
