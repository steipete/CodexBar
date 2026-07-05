import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct DeepSeekUsageSummaryChartMenuViewTests {
    private static func sampleUsage(includeCost: Bool) -> DeepSeekUsageSummary {
        DeepSeekUsageSummary(
            todayTokens: 100,
            currentMonthTokens: 900,
            todayCost: includeCost ? 1.5 : nil,
            currentMonthCost: includeCost ? 9.0 : nil,
            requestCount: 3,
            currentMonthRequestCount: 27,
            topModel: "deepseek-chat",
            categoryBreakdown: [],
            daily: (1...10).map { day in
                DeepSeekDailyUsage(
                    date: String(format: "2026-05-%02d", day),
                    totalTokens: day * 100,
                    cost: includeCost ? Double(day) * 0.1 : nil,
                    requestCount: day)
            },
            currency: "USD",
            updatedAt: Date())
    }

    @Test
    @MainActor
    func `chart model prefers cost trend when daily costs exist`() {
        let usage = Self.sampleUsage(includeCost: true)
        let summary = DeepSeekUsageSummaryChartMenuView._makeModelSummaryForTesting(
            usage: usage,
            windowDays: 7)

        #expect(summary.prefersCostTrend)
        #expect(summary.pointCount == 7)
        #expect(summary.axisDateCount == 2)
    }

    @Test
    @MainActor
    func `chart model falls back to token trend without costs`() {
        let usage = Self.sampleUsage(includeCost: false)
        let summary = DeepSeekUsageSummaryChartMenuView._makeModelSummaryForTesting(
            usage: usage,
            windowDays: 30)

        #expect(!summary.prefersCostTrend)
        #expect(summary.pointCount == 10)
    }

    @Test
    @MainActor
    func `detail rows scroll when model breakdown exceeds viewport`() {
        #expect(!DeepSeekUsageSummaryChartMenuView._detailRowsNeedScrollingForTesting(itemCount: 4))
        #expect(DeepSeekUsageSummaryChartMenuView._detailRowsNeedScrollingForTesting(itemCount: 5))
    }

    @Test
    @MainActor
    func `total card height grows with detail rows and chart`() {
        let empty = DeepSeekUsageSummaryChartMenuView._totalCardHeightForTesting(rows: 0, hasChart: false)
        let withChart = DeepSeekUsageSummaryChartMenuView._totalCardHeightForTesting(rows: 2, hasChart: true)
        let withManyRows = DeepSeekUsageSummaryChartMenuView._totalCardHeightForTesting(rows: 5, hasChart: true)

        #expect(withChart > empty)
        #expect(withManyRows > withChart)
    }

    @Test
    @MainActor
    func `total card height reserves space for wrapped footer disclaimer`() {
        let narrow = DeepSeekUsageSummaryChartMenuView._totalCardHeightForTesting(
            rows: 1,
            hasChart: true,
            width: 280)
        let wide = DeepSeekUsageSummaryChartMenuView._totalCardHeightForTesting(
            rows: 1,
            hasChart: true,
            width: 420)

        #expect(narrow >= wide)
    }

    @Test
    @MainActor
    func `token breakdown includes cache hit miss and output rows`() {
        #expect(DeepSeekUsageSummaryChartMenuView._tokenBreakdownLineCountForTesting() == 3)
    }

    @Test
    @MainActor
    func `selection band width matches chart bar slot`() {
        #expect(DeepSeekUsageSummaryChartMenuView._barHalfWidthForTesting(slotWidth: 40) == 12)
        #expect(DeepSeekUsageSummaryChartMenuView._barHalfWidthForTesting(slotWidth: 80) == 22)
    }

    @Test
    @MainActor
    func `window kpis use selected model requests and cache hit`() {
        let usage = Self.sampleUsage(includeCost: true)
        let flash = DeepSeekDailyModelUsage(
            model: "deepseek-v4-flash",
            tokens: 118_000,
            cost: 0.1,
            cacheHitTokens: 78000,
            cacheMissTokens: 40000,
            outputTokens: 464,
            requestCount: 4)
        let pro = DeepSeekDailyModelUsage(
            model: "deepseek-v4-pro",
            tokens: 777_000,
            cost: 0.35,
            cacheHitTokens: 653_000,
            cacheMissTokens: 124_000,
            outputTokens: 6200,
            requestCount: 23)

        let flashValues = DeepSeekUsageSummaryChartMenuView._windowKPIValuesForTesting(
            usage: usage,
            windowDays: 7,
            selectedModel: flash)
        let proValues = DeepSeekUsageSummaryChartMenuView._windowKPIValuesForTesting(
            usage: usage,
            windowDays: 7,
            selectedModel: pro)

        #expect(flashValues[2] == "4")
        #expect(flashValues[3] == "66.1%")
        #expect(proValues[2] == "23")
        #expect(proValues[3] == "84.0%")
    }
}
