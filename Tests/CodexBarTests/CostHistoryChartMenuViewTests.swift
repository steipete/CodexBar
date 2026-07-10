import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct CostHistoryChartMenuViewTests {
    @Test
    @MainActor
    func `model breakdown keeps every item behind a bounded scrolling viewport`() {
        let breakdown = (1...6).map { index in
            CostUsageDailyReport.ModelBreakdown(
                modelName: "model-\(index)",
                costUSD: Double(index),
                totalTokens: index * 100)
        }

        let ordered = CostHistoryChartMenuView.orderedBreakdownItems(breakdown)

        #expect(ordered.map(\.modelName) == [
            "model-6",
            "model-5",
            "model-4",
            "model-3",
            "model-2",
            "model-1",
        ])
        #expect(CostHistoryChartMenuView.detailViewportRowCount(itemCount: ordered.count) == 4)
        #expect(CostHistoryChartMenuView.detailRowsNeedScrolling(itemCount: ordered.count))
        #expect(CostHistoryChartMenuView.detailOverflowHint(itemCount: ordered.count) == "Scroll to see more models")
        #expect(CostHistoryChartMenuView.detailOverflowHint(itemCount: 4) == nil)
    }

    @Test
    @MainActor
    func `menu hosting view publishes measured height through intrinsic size`() {
        let hosting = MenuHostingView(rootView: EmptyView())
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 1)

        hosting.applyMeasuredHeight(width: 320, height: 123.2)

        #expect(hosting.frame.size == CGSize(width: 320, height: 124))
        #expect(hosting.intrinsicContentSize.height == 124)
    }

    @Test
    @MainActor
    func `cost history defaults selection to latest day`() {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-06-07",
                inputTokens: 100,
                outputTokens: 50,
                totalTokens: 150,
                costUSD: 1.25,
                modelsUsed: ["gpt-5.5"],
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-06-09",
                inputTokens: 200,
                outputTokens: 75,
                totalTokens: 275,
                costUSD: 2.5,
                modelsUsed: ["gpt-5.5"],
                modelBreakdowns: nil),
        ]

        #expect(
            CostHistoryChartMenuView._defaultSelectedDateKeyForTesting(
                provider: .codex,
                daily: daily) == "2026-06-09")
    }

    @Test
    @MainActor
    func `cost history sizes its viewport to the largest breakdown in the range`() {
        let threeRows = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 1), Self.entry(date: "2026-06-08", modelCount: 3)])
        let cappedRows = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 6)])
        let mixedRows = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 6), Self.entry(date: "2026-06-08", modelCount: 1)])
        let noRows = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 0)])

        #expect(threeRows.rowCount == 3)
        #expect(!threeRows.hasOverflow)
        #expect(threeRows.rowHeight == 36)
        #expect(cappedRows.rowCount == 4)
        #expect(cappedRows.hasOverflow)
        #expect(mixedRows.rowCount == 4)
        #expect(mixedRows.hasOverflow)
        #expect(noRows.rowCount == 0)
        #expect(!noRows.hasOverflow)
    }

    @Test
    @MainActor
    func `cost history expands every row only when the range contains mode details`() {
        let compact = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(date: "2026-06-07", modelCount: 2)])
        let expanded = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [
                Self.entry(date: "2026-06-07", modelCount: 2),
                Self.entry(date: "2026-06-08", modelCount: 1, hasModeDetails: true),
            ])

        #expect(compact.rowHeight == 36)
        #expect(expanded.rowHeight == 44)
        #expect(compact.rowCount == expanded.rowCount)
    }

    @Test
    @MainActor
    func `axis dates span first to last for multi-day data`() {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-05-21",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: 1.0,
                modelsUsed: nil,
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-06-17",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: 2.0,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ]
        let dates = CostHistoryChartMenuView._axisDatesForTesting(provider: .codex, daily: daily)
        let cal = Calendar.current
        #expect(dates.count == 2)
        #expect(cal.component(.month, from: dates[0]) == 5)
        #expect(cal.component(.day, from: dates[0]) == 21)
        #expect(cal.component(.month, from: dates[1]) == 6)
        #expect(cal.component(.day, from: dates[1]) == 17)
        #expect(
            CostHistoryChartMenuView._axisLabelPlacementForTesting(
                provider: .codex,
                daily: daily) == .edges)
    }

    @Test
    @MainActor
    func `axis dates collapse to one for single-day data`() {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-06-17",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: 1.0,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ]
        let dates = CostHistoryChartMenuView._axisDatesForTesting(provider: .codex, daily: daily)
        #expect(dates.count == 1)
        #expect(
            CostHistoryChartMenuView._axisLabelPlacementForTesting(
                provider: .codex,
                daily: daily) == .centered)
    }

    @Test
    @MainActor
    func `axis dates are empty when there is no cost data`() {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-06-17",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ]
        let dates = CostHistoryChartMenuView._axisDatesForTesting(provider: .codex, daily: daily)
        #expect(dates.isEmpty)
        #expect(
            CostHistoryChartMenuView._axisLabelPlacementForTesting(
                provider: .codex,
                daily: daily) == .hidden)
    }

    @Test
    @MainActor
    func `y-axis tick values are empty for flat or no data`() {
        #expect(CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: 0).isEmpty)
        #expect(CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: -1).isEmpty)
    }

    @Test
    @MainActor
    func `y-axis tick values use two ticks for small ranges`() {
        let ticks = CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: 0.50)
        #expect(ticks == [0, 0.50])
    }

    @Test
    @MainActor
    func `y-axis tick values use three ticks for ranges at or above one dollar`() {
        let ticks = CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: 12.0)
        #expect(ticks == [0, 6.0, 12.0])

        let large = CostHistoryChartMenuView._yAxisTickValuesForTesting(maxCostUSD: 1000.0)
        #expect(large == [0, 500.0, 1000.0])
    }

    @Test(arguments: [
        (0.0, "$0"),
        (12.56, "$13"),
        (0.50, "$0.50"),
    ])
    @MainActor
    func `y-axis cost labels preserve cents only for nonzero sub-dollar values`(
        value: Double,
        expected: String)
    {
        #expect(CostHistoryChartMenuView._yAxisCostStringForTesting(value) == expected)
    }

    @Test
    @MainActor
    func `cost history fitting height stays stable across compact overflow and mode selections`() {
        let compactLatestHasOneModel = [
            Self.entry(date: "2026-06-07", modelCount: 3),
            Self.entry(date: "2026-06-08", modelCount: 1),
        ]
        let compactLatestHasThreeModels = [
            Self.entry(date: "2026-06-07", modelCount: 1),
            Self.entry(date: "2026-06-08", modelCount: 3),
        ]
        let overflowLatestHasFourModels = [
            Self.entry(date: "2026-06-07", modelCount: 6),
            Self.entry(date: "2026-06-08", modelCount: 4),
        ]
        let overflowLatestHasSixModels = [
            Self.entry(date: "2026-06-07", modelCount: 4),
            Self.entry(date: "2026-06-08", modelCount: 6),
        ]
        let modeLatestHasOneModel = [
            Self.entry(date: "2026-06-07", modelCount: 6),
            Self.entry(date: "2026-06-08", modelCount: 1, hasModeDetails: true),
        ]
        let modeLatestHasSixModels = [
            Self.entry(date: "2026-06-07", modelCount: 1, hasModeDetails: true),
            Self.entry(date: "2026-06-08", modelCount: 6),
        ]

        let compactHeight = Self.renderedHeight(daily: compactLatestHasOneModel)
        let overflowHeight = Self.renderedHeight(daily: overflowLatestHasFourModels)
        let modeHeight = Self.renderedHeight(daily: modeLatestHasOneModel)

        #expect(compactHeight == Self.renderedHeight(daily: compactLatestHasThreeModels))
        #expect(overflowHeight == Self.renderedHeight(daily: overflowLatestHasSixModels))
        #expect(modeHeight == Self.renderedHeight(daily: modeLatestHasSixModels))
        #expect(compactHeight < overflowHeight)
        #expect(overflowHeight < modeHeight)
    }

    @Test
    @MainActor
    func `cost history without model breakdown stays compact`() {
        let noBreakdown = [Self.entry(date: "2026-06-07", modelCount: 0)]
        let withBreakdown = [Self.entry(date: "2026-06-07", modelCount: 1)]

        #expect(Self.renderedHeight(daily: noBreakdown) < Self.renderedHeight(daily: withBreakdown))
    }

    @Test
    @MainActor
    func `single differing project source remains visible`() {
        let matching = Self.project(path: "/tmp/main", sourcePath: "/tmp/main")
        let differing = Self.project(path: "/tmp/main", sourcePath: "/tmp/worktree")

        #expect(CostHistoryChartMenuView.visibleProjectSources(matching).isEmpty)
        #expect(CostHistoryChartMenuView.visibleProjectSources(differing).compactMap(\.path) == ["/tmp/worktree"])
    }

    private static func project(path: String, sourcePath: String) -> CostUsageProjectBreakdown {
        CostUsageProjectBreakdown(
            name: "Project",
            path: path,
            totalTokens: 10,
            totalCostUSD: 0.1,
            daily: [],
            modelBreakdowns: nil,
            sources: [
                CostUsageProjectSourceBreakdown(
                    name: "Source",
                    path: sourcePath,
                    totalTokens: 10,
                    totalCostUSD: 0.1,
                    daily: [],
                    modelBreakdowns: nil),
            ])
    }

    @MainActor
    private static func renderedHeight(daily: [CostUsageDailyReport.Entry]) -> CGFloat {
        let hosting = MenuHostingView(rootView: CostHistoryChartMenuView(
            provider: .codex,
            daily: daily,
            totalCostUSD: nil,
            width: 320))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
        hosting.layoutSubtreeIfNeeded()
        return ceil(hosting.fittingSize.height)
    }

    private static func entry(
        date: String,
        modelCount: Int,
        hasModeDetails: Bool = false) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: 100,
            outputTokens: 50,
            totalTokens: 150,
            costUSD: 1,
            modelsUsed: modelCount > 0 ? (0..<modelCount).map { "model-\($0)" } : nil,
            modelBreakdowns: modelCount > 0
                ? (0..<modelCount).map {
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "model-\($0)",
                        costUSD: Double($0 + 1),
                        totalTokens: ($0 + 1) * 100,
                        standardCostUSD: hasModeDetails ? Double($0 + 1) * 0.75 : nil)
                }
                : nil)
    }
}
