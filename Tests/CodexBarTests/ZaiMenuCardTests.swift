import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ZaiMenuCardTests {
    @Test
    func `zai metrics titles are Tokens MCP and 5-hour when session token limit present`() throws {
        let now = Date()
        let zai = ZaiUsageSnapshot(
            tokenLimit: ZaiLimitEntry(
                type: .tokensLimit,
                unit: .weeks,
                number: 1,
                usage: nil,
                currentValue: nil,
                remaining: nil,
                percentage: 9,
                usageDetails: [],
                nextResetTime: nil),
            sessionTokenLimit: ZaiLimitEntry(
                type: .tokensLimit,
                unit: .hours,
                number: 5,
                usage: 1000,
                currentValue: 750,
                remaining: 250,
                percentage: 25,
                usageDetails: [],
                nextResetTime: nil),
            timeLimit: ZaiLimitEntry(
                type: .timeLimit,
                unit: .minutes,
                number: 1,
                usage: 100,
                currentValue: 50,
                remaining: 50,
                percentage: 50,
                usageDetails: [],
                nextResetTime: nil),
            planName: "pro",
            updatedAt: now)
        let snapshot = zai.toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.zai])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .zai,
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

        #expect(model.metrics.map(\.title) == ["Tokens", "MCP", "5-hour"])
        let tertiary = try #require(model.metrics.first(where: { $0.title == "5-hour" }))
        #expect(tertiary.detailText == "750 / 1K (250 remaining)")
    }
}
