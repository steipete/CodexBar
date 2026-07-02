import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxUsagePricingTests {
    @Test
    func `m27 standard pricing bills cache read separately from input`() {
        let cost = MiniMaxUsagePricing.minimaxCostUSD(
            model: "MiniMax-M2.7",
            inputToken: 1_000_000,
            cacheReadToken: 500_000,
            cacheCreateToken: 0,
            outputToken: 0)

        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 0.18) < 0.0001)
    }

    @Test
    func `m3 long context uses higher rates above threshold`() {
        let shortContext = MiniMaxUsagePricing.minimaxCostUSD(
            model: "MiniMax-M3-512k",
            inputToken: 400_000,
            cacheReadToken: 0,
            cacheCreateToken: 0,
            outputToken: 1_000_000)
        let longContext = MiniMaxUsagePricing.minimaxCostUSD(
            model: "MiniMax-M3",
            inputToken: 600_000,
            cacheReadToken: 0,
            cacheCreateToken: 0,
            outputToken: 1_000_000)

        #expect(shortContext != nil)
        #expect(longContext != nil)
        #expect((longContext ?? 0) > (shortContext ?? 0))
    }

    @Test
    func `coding plan models are treated as zero cost`() {
        let cost = MiniMaxUsagePricing.minimaxCostUSD(
            model: "coding-plan-vlm",
            inputToken: 1_000_000,
            cacheReadToken: 500_000,
            cacheCreateToken: 100_000,
            outputToken: 250_000)

        #expect(cost == 0)
    }

    @Test
    func `projected daily cost aggregates model breakdown`() {
        let summary = Self.sampleSummary()
        guard let day = summary.days.last else {
            Issue.record("Expected sample summary day")
            return
        }
        let cost = summary.projectedCostUSD(for: day)
        #expect(cost != nil)
        #expect((cost ?? 0) > 0)
        #expect(summary.projectedCostUSD(lastDays: 30) != nil)
    }

    @Test
    func `snapshot day with model breakdown projects cost history`() {
        let summary = Self.sampleSummary()
        let snapshot = summary.toCostUsageTokenSnapshot(
            historyDays: 30,
            now: Date(timeIntervalSince1970: 1_735_689_600))

        #expect(snapshot != nil)
        #expect(snapshot?.sessionCostUSD != nil)
        #expect(snapshot?.last30DaysCostUSD != nil)
        #expect(snapshot?.daily.count == 2)
        #expect(snapshot?.daily.last?.modelBreakdowns?.count == 1)
        #expect(snapshot?.daily.last?.modelBreakdowns?.first?.modelName == "MiniMax-M3-512k")
    }

    private static func sampleSummary() -> MiniMaxUsageSummary {
        MiniMaxUsageSummary(
            totalDays: 77,
            totalTokenConsumed: "2.37B",
            usageRankingPercent: 3.8,
            activeDays: 60,
            currentConsecutiveDays: 31,
            lastUpdateTime: "07-02 20:00",
            dailyTokenUsage: [201_889, 2_800_317, 4_486_224, 88000],
            days: [
                MiniMaxUsageSummaryDay(
                    date: "2026-06-29",
                    totalInputToken: 200_395,
                    totalCacheReadToken: 172_249,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 1494,
                    totalToken: 201_889,
                    cacheHitPercent: 85.95,
                    models: [
                        MiniMaxUsageSummaryModel(
                            model: "MiniMax-M3-512k",
                            inputToken: 200_395,
                            cacheReadToken: 172_249,
                            cacheCreateToken: 0,
                            outputToken: 1494,
                            totalToken: 374_138,
                            cacheHitPercent: 85.95),
                    ]),
                MiniMaxUsageSummaryDay(
                    date: "2026-07-02",
                    totalInputToken: 86000,
                    totalCacheReadToken: 64000,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 2500,
                    totalToken: 88000,
                    cacheHitPercent: 74.63,
                    models: [
                        MiniMaxUsageSummaryModel(
                            model: "MiniMax-M3-512k",
                            inputToken: 86000,
                            cacheReadToken: 64000,
                            cacheCreateToken: 0,
                            outputToken: 2500,
                            totalToken: 88000,
                            cacheHitPercent: 74.6),
                    ]),
            ])
    }
}
