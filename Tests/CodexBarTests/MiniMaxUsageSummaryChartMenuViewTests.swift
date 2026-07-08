import CodexBarCore
import Testing
@testable import CodexBar

struct MiniMaxUsageSummaryChartMenuViewTests {
    @Test
    @MainActor
    func `day detail primary includes projected daily cost`() {
        let usage = MiniMaxUsageSummary(
            totalDays: 1,
            totalTokenConsumed: "88K",
            usageRankingPercent: nil,
            activeDays: 1,
            currentConsecutiveDays: 1,
            lastUpdateTime: "07-02 21:00",
            dailyTokenUsage: [88000],
            days: [
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
        let primary = MiniMaxUsageSummaryChartMenuView._dayDetailPrimaryForTesting(
            usage: usage,
            dateKey: "2026-07-02")
        #expect(primary?.contains("74.63%") == true)
        #expect(primary?.contains("$") == true)
    }

    @Test
    @MainActor
    func `summary KPI values use two decimal token formatting`() {
        let usage = MiniMaxUsageSummary(
            totalDays: 1,
            totalTokenConsumed: "88K",
            usageRankingPercent: nil,
            activeDays: 1,
            currentConsecutiveDays: 1,
            lastUpdateTime: "07-02 21:00",
            dailyTokenUsage: [88000],
            days: [
                MiniMaxUsageSummaryDay(
                    date: "2026-07-02",
                    totalInputToken: 86000,
                    totalCacheReadToken: 64000,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 2500,
                    totalToken: 88000,
                    cacheHitPercent: 74.63,
                    models: []),
            ])
        let values = MiniMaxUsageSummaryChartMenuView.summaryKPIValues(usage: usage)
        #expect(values == ["88.00K", "88.00K", "88.00K", "74.63%"])
    }

    @Test
    @MainActor
    func `model breakdown keeps every item behind a bounded scrolling viewport`() {
        #expect(MiniMaxUsageSummaryChartMenuView.detailViewportRowCount(itemCount: 6) == 4)
        #expect(MiniMaxUsageSummaryChartMenuView.detailRowsNeedScrolling(itemCount: 6))
        #expect(!MiniMaxUsageSummaryChartMenuView.detailRowsNeedScrolling(itemCount: 3))
    }

    @Test
    @MainActor
    func `duplicate model names do not trap detail rendering`() {
        let duplicate = MiniMaxUsageSummaryModel(
            model: "MiniMax-M3",
            inputToken: 100,
            cacheReadToken: 0,
            cacheCreateToken: 0,
            outputToken: 10,
            totalToken: 110,
            cacheHitPercent: 0)
        let usage = MiniMaxUsageSummary(
            totalDays: 1,
            totalTokenConsumed: "220",
            usageRankingPercent: nil,
            activeDays: 1,
            currentConsecutiveDays: 1,
            lastUpdateTime: "07-02 21:00",
            dailyTokenUsage: [220],
            days: [
                MiniMaxUsageSummaryDay(
                    date: "2026-07-02",
                    totalInputToken: 200,
                    totalCacheReadToken: 0,
                    totalCacheCreateToken: 0,
                    totalOutputToken: 20,
                    totalToken: 220,
                    cacheHitPercent: 0,
                    models: [duplicate, duplicate]),
            ])

        #expect(MiniMaxUsageSummaryChartMenuView._detailRowCountForTesting(
            usage: usage,
            dateKey: "2026-07-02") == 2)
    }

    @Test
    @MainActor
    func `usage summary detail height follows visible rows and caps at viewport limit`() {
        let singleRowHeight = MiniMaxUsageSummaryChartMenuView._detailViewportHeightForTesting(
            modeSubtitlePresence: [true])
        let twoRowHeight = MiniMaxUsageSummaryChartMenuView._detailViewportHeightForTesting(
            modeSubtitlePresence: [true, true])
        let fourRowHeight = MiniMaxUsageSummaryChartMenuView._detailViewportHeightForTesting(
            modeSubtitlePresence: [true, true, true, true])
        let fiveRowHeight = MiniMaxUsageSummaryChartMenuView._detailViewportHeightForTesting(
            modeSubtitlePresence: [true, true, true, true, true])

        #expect(singleRowHeight < twoRowHeight)
        #expect(twoRowHeight < fourRowHeight)
        #expect(fiveRowHeight == fourRowHeight)

        let emptyBlockHeight = MiniMaxUsageSummaryChartMenuView._detailBlockHeightForTesting(
            modeSubtitlePresence: [])
        let populatedBlockHeight = MiniMaxUsageSummaryChartMenuView._detailBlockHeightForTesting(
            modeSubtitlePresence: [true])
        #expect(emptyBlockHeight < populatedBlockHeight)
    }

    @Test
    @MainActor
    func `usage summary card height grows with selected day model count`() {
        let oneModel = MiniMaxUsageSummaryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [true],
            hasChart: true)
        let threeModels = MiniMaxUsageSummaryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [true, true, true],
            hasChart: true)
        let fourModels = MiniMaxUsageSummaryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [true, true, true, true],
            hasChart: true)
        let fiveModels = MiniMaxUsageSummaryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [true, true, true, true, true],
            hasChart: true)

        #expect(oneModel < threeModels)
        #expect(threeModels < fourModels)
        #expect(fiveModels == fourModels)
    }

    @Test
    @MainActor
    func `resolved card height includes chart section when data is present`() {
        let withChart = MiniMaxUsageSummaryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [],
            hasChart: true)
        let withoutChart = MiniMaxUsageSummaryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [],
            hasChart: false)
        #expect(withChart > withoutChart)
        #expect(withChart - withoutChart > 130)
    }
}
