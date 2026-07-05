import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct DeepSeekHostedSubmenuTests {
    @Test
    func `usage summary render signature changes when daily usage updates`() {
        let usageA = DeepSeekUsageSummary(
            todayTokens: 100,
            currentMonthTokens: 500,
            todayCost: 1.5,
            currentMonthCost: 7.5,
            requestCount: 3,
            currentMonthRequestCount: 12,
            topModel: "deepseek-chat",
            categoryBreakdown: [],
            daily: [
                DeepSeekDailyUsage(date: "2026-05-26", totalTokens: 500, cost: 7.5, requestCount: 12),
            ],
            currency: "USD",
            updatedAt: Date())
        let usageB = DeepSeekUsageSummary(
            todayTokens: 200,
            currentMonthTokens: 600,
            todayCost: 2.5,
            currentMonthCost: 8.5,
            requestCount: 4,
            currentMonthRequestCount: 13,
            topModel: "deepseek-chat",
            categoryBreakdown: [],
            daily: [
                DeepSeekDailyUsage(date: "2026-05-26", totalTokens: 600, cost: 8.5, requestCount: 13),
            ],
            currency: "USD",
            updatedAt: Date())

        let before = StatusItemController.deepSeekUsageSummaryRenderSignature(usage: usageA)
        let after = StatusItemController.deepSeekUsageSummaryRenderSignature(usage: usageB)

        #expect(before != after)
        #expect(before.contains("USD"))
        #expect(after.contains("200"))
    }
}
