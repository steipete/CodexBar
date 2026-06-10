import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CostHistoryChartMenuViewTests {
    @Test
    @MainActor
    func `window label keeps today for one day and dynamic labels otherwise`() {
        #expect(CostHistoryChartMenuView.windowLabel(days: 1) == "Today")
        #expect(CostHistoryChartMenuView.windowLabel(days: 7) == "Last 7 days")
        #expect(CostHistoryChartMenuView.windowLabel(days: 30) == "Last 30 days")
    }

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
        #expect(ordered.count == 6)
        #expect(CostHistoryChartMenuView.detailViewportRowCount(itemCount: ordered.count) == 4)
        #expect(CostHistoryChartMenuView.detailRowsNeedScrolling(itemCount: ordered.count))
    }

    @Test
    @MainActor
    func `short model breakdown does not scroll or reserve extra rows`() {
        #expect(CostHistoryChartMenuView.detailViewportRowCount(itemCount: 3) == 3)
        #expect(CostHistoryChartMenuView.detailRowsNeedScrolling(itemCount: 3) == false)
    }
}
