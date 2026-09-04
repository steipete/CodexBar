import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardMetricTextTests {
    @Test
    func `metric text shows cost and tokens together`() {
        let text = spendDashboardMetricText(cost: 1.25, tokens: 953_000, currencyCode: "USD")
        #expect(text.contains("$"))
        #expect(text.contains("953"))
    }

    @Test
    func `metric text falls back to cost or tokens alone`() {
        #expect(spendDashboardMetricText(cost: 2, tokens: nil, currencyCode: "USD").contains("$"))
        #expect(spendDashboardMetricText(cost: nil, tokens: 1200, currencyCode: "USD").contains("1"))
        #expect(spendDashboardMetricText(cost: nil, tokens: nil, currencyCode: "USD") == "—")
    }

    @Test
    func `detail sections expose only breakdowns backed by data`() {
        #expect(spendDashboardAvailableDetailSections(hasProjects: false, hasSessions: false) == [
            .providers,
        ])
        #expect(spendDashboardAvailableDetailSections(hasProjects: true, hasSessions: true) == [
            .providers,
            .projects,
            .sessions,
        ])
    }

    @Test
    func `hourly trend appears only when hourly data exists`() {
        #expect(spendDashboardAvailableTrendSections(hasHourlyData: false) == [.daily])
        #expect(spendDashboardAvailableTrendSections(hasHourlyData: true) == [.daily, .hourly])
    }

    @Test
    func `provider metric marks partial aggregates without hiding known values`() {
        let text = spendDashboardBreakdownMetricText(
            cost: 2.5,
            tokens: 1200,
            currencyCode: "USD",
            hasPartialCost: true,
            hasPartialTokens: true)
        #expect(text.contains("~$"))
        #expect(text.contains("~1"))
    }
}
