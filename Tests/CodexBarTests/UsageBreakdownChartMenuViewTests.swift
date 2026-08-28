import Testing
@testable import CodexBar

@Suite("Usage breakdown chart menu")
@MainActor
struct UsageBreakdownChartMenuViewTests {
    @Test
    func `valid totals remain visible when service rows are absent`() {
        #expect(
            UsageBreakdownChartMenuView.presentationState(
                hasSummary: true,
                hasChartPoints: false) == .totalsOnly)
    }

    @Test
    func `service rows select the chart presentation`() {
        #expect(
            UsageBreakdownChartMenuView.presentationState(
                hasSummary: true,
                hasChartPoints: true) == .chart)
    }

    @Test
    func `missing totals and service rows select the empty presentation`() {
        #expect(
            UsageBreakdownChartMenuView.presentationState(
                hasSummary: false,
                hasChartPoints: false) == .empty)
    }
}
