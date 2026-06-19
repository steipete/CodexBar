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
    func `cost history detail height follows visible rows and caps at viewport limit`() {
        let singleRowHeight = CostHistoryChartMenuView._detailViewportHeightForTesting(modeSubtitlePresence: [false])
        let twoRowHeight = CostHistoryChartMenuView._detailViewportHeightForTesting(modeSubtitlePresence: [false, true])
        let fourRowHeight = CostHistoryChartMenuView._detailViewportHeightForTesting(
            modeSubtitlePresence: [false, false, false, false])
        let fiveRowHeight = CostHistoryChartMenuView._detailViewportHeightForTesting(
            modeSubtitlePresence: [false, false, false, false, true])

        #expect(singleRowHeight < twoRowHeight)
        #expect(twoRowHeight < fourRowHeight)
        #expect(fiveRowHeight == fourRowHeight)

        let emptyBlockHeight = CostHistoryChartMenuView._detailBlockHeightForTesting(modeSubtitlePresence: [])
        let populatedBlockHeight = CostHistoryChartMenuView._detailBlockHeightForTesting(modeSubtitlePresence: [false])
        #expect(emptyBlockHeight < populatedBlockHeight)
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
    func `cost history total card height grows with rows and the total line`() {
        let oneRow = CostHistoryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [false],
            hasTotal: false)
        let threeRows = CostHistoryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [false, false, false],
            hasTotal: false)
        #expect(oneRow < threeRows)

        let withoutTotal = CostHistoryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [false],
            hasTotal: false)
        let withTotal = CostHistoryChartMenuView._totalCardHeightForTesting(
            modeSubtitlePresence: [false],
            hasTotal: true)
        #expect(withTotal > withoutTotal)
    }
}
