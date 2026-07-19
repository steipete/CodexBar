import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeAdminAPIInlineDashboardModelTests {
    @Test
    func `claude admin api usage gets inline dashboard`() throws {
        let now = try Self.localNoon(year: 2023, month: 11, day: 17)
        let bucketDay = try Self.localNoon(year: 2023, month: 11, day: 14)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let usage = ClaudeAdminAPIUsageSnapshot(
            daily: [
                ClaudeAdminAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: bucketDay,
                    endTime: bucketDay.addingTimeInterval(86400),
                    costUSD: 1.25,
                    inputTokens: 1000,
                    cacheCreationInputTokens: 400,
                    cacheReadInputTokens: 300,
                    outputTokens: 250,
                    totalTokens: 1950,
                    costItems: [
                        ClaudeAdminAPIUsageSnapshot.CostBreakdown(name: "Claude Sonnet Usage", costUSD: 1.25),
                    ],
                    models: [
                        ClaudeAdminAPIUsageSnapshot.ModelBreakdown(
                            name: "claude-sonnet-4-20250514",
                            inputTokens: 1000,
                            cacheCreationInputTokens: 400,
                            cacheReadInputTokens: 300,
                            outputTokens: 250,
                            totalTokens: 1950),
                    ]),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: usage.toUsageSnapshot(),
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
        #expect(model.inlineUsageDashboard?.kpis.first?.value == "$0.00")
        #expect(model.inlineUsageDashboard?.points.first?.accessibilityValue == "2023-11-14: $1.25")
        #expect(model.inlineUsageDashboard?.detailLines
            .contains { $0.hasPrefix("30d:") && $0.contains("tokens") } == true)
        #expect(model.inlineUsageDashboard?.detailLines.contains("Top model: claude-sonnet-4-20250514") == true)
        #expect(model.planText == "Admin API")
    }

    private static func localNoon(year: Int, month: Int, day: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}
