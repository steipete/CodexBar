import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekUsageSummaryDisplayTests {
    private static func sampleUsage() -> DeepSeekUsageSummary {
        DeepSeekUsageSummary(
            todayTokens: 100,
            currentMonthTokens: 500,
            todayCost: 1.5,
            currentMonthCost: 7.5,
            requestCount: 3,
            currentMonthRequestCount: 12,
            topModel: "deepseek-chat",
            categoryBreakdown: [
                DeepSeekCategoryBreakdown(category: .promptCacheHitToken, tokens: 60, cost: 0.5),
                DeepSeekCategoryBreakdown(category: .promptCacheMissToken, tokens: 20, cost: 0.5),
                DeepSeekCategoryBreakdown(category: .responseToken, tokens: 20, cost: 0.5),
            ],
            daily: [
                DeepSeekDailyUsage(
                    date: "2026-05-24",
                    totalTokens: 200,
                    cost: 2.0,
                    requestCount: 4,
                    models: [
                        DeepSeekDailyModelUsage(
                            model: "deepseek-chat",
                            tokens: 200,
                            cost: 2.0,
                            cacheHitTokens: 120,
                            cacheMissTokens: 40,
                            outputTokens: 40,
                            requestCount: 4),
                    ]),
                DeepSeekDailyUsage(
                    date: "2026-05-25",
                    totalTokens: 300,
                    cost: 3.0,
                    requestCount: 5,
                    models: [
                        DeepSeekDailyModelUsage(
                            model: "deepseek-chat",
                            tokens: 300,
                            cost: 3.0,
                            cacheHitTokens: 180,
                            cacheMissTokens: 60,
                            outputTokens: 60,
                            requestCount: 5),
                    ]),
            ],
            currency: "CNY",
            updatedAt: Date())
    }

    @Test
    func `has displayable data when daily usage exists`() {
        #expect(Self.sampleUsage().hasDisplayableData)
    }

    @Test
    func `computes rolling token and cost totals`() {
        let usage = Self.sampleUsage()
        #expect(usage.last7DaysTokens == 500)
        #expect(usage.last30DaysTokens == 500)
        #expect(usage.last7DaysCost == 5.0)
        #expect(usage.cacheHitPercent == 75)
    }

    @Test
    func `projects cost usage token snapshot`() {
        let snapshot = Self.sampleUsage().toCostUsageTokenSnapshot(historyDays: 30)
        #expect(snapshot.currencyCode == "CNY")
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.sessionTokens == 100)
        #expect(snapshot.last30DaysTokens == 500)
        #expect(snapshot.last30DaysCostUSD == 7.5)
        #expect(snapshot.daily.first?.modelBreakdowns?.first?.modelName == "deepseek-chat")
    }

    @Test
    func `daily model usage exposes cache hit percent`() {
        let model = Self.sampleUsage().daily[0].models[0]
        #expect(model.cacheHitPercent == 75)
        #expect(Self.sampleUsage().daily[0].cacheHitPercent == 75)
    }

    @Test
    func `prefers cost trend when daily costs exist`() {
        #expect(Self.sampleUsage().prefersCostTrend)
        let tokenOnly = DeepSeekUsageSummary(
            todayTokens: 10,
            currentMonthTokens: 10,
            todayCost: nil,
            currentMonthCost: nil,
            requestCount: 1,
            currentMonthRequestCount: 1,
            topModel: nil,
            categoryBreakdown: [],
            daily: [DeepSeekDailyUsage(date: "2026-05-26", totalTokens: 10, cost: nil, requestCount: 1)],
            currency: "USD",
            updatedAt: Date())
        #expect(!tokenOnly.prefersCostTrend)
    }
}
