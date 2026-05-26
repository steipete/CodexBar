import Testing
@testable import CodexBar

struct CostHistoryChartMenuViewTests {
    @Test
    @MainActor
    func `window label keeps today for one day and dynamic labels otherwise`() {
        #expect(CostHistoryChartMenuView.windowLabel(days: 1) == "Today")
        #expect(CostHistoryChartMenuView.windowLabel(days: 7) == "Last 7 days")
        #expect(CostHistoryChartMenuView.windowLabel(days: 30) == "Last 30 days")
    }
}
