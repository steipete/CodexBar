import CodexBarCore
import Testing
@testable import CodexBar

struct MenuCardCriticalHeadroomTests {
    private func metric(
        percent: Double,
        style: UsageMenuCardView.Model.PercentStyle,
        statusText: String? = nil,
        isSyntheticCreditLane: Bool = false) -> UsageMenuCardView.Model.Metric
    {
        UsageMenuCardView.Model.Metric(
            id: "session",
            title: "Session",
            percent: percent,
            percentStyle: style,
            statusText: statusText,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true,
            isSyntheticCreditLane: isSyntheticCreditLane)
    }

    @Test
    func `used percentages flag only the critical headroom tier`() {
        #expect(!self.metric(percent: 34, style: .used).isCriticallyLow)
        #expect(!self.metric(percent: 89, style: .used).isCriticallyLow)
        #expect(self.metric(percent: 90, style: .used).isCriticallyLow)
        #expect(self.metric(percent: 100, style: .used).isCriticallyLow)
    }

    @Test
    func `remaining percentages use the same shared threshold`() {
        #expect(!self.metric(percent: 66, style: .left).isCriticallyLow)
        #expect(!self.metric(percent: 11, style: .left).isCriticallyLow)
        #expect(self.metric(percent: AccountMenuLayoutPlanner.criticalHeadroomPercent, style: .left).isCriticallyLow)
        #expect(self.metric(percent: 0, style: .left).isCriticallyLow)
    }

    @Test
    func `unavailable windows and credit lanes never read as critical`() {
        #expect(!self.metric(percent: 0, style: .left, statusText: "Unavailable").isCriticallyLow)
        #expect(!self.metric(percent: 98, style: .used, isSyntheticCreditLane: true).isCriticallyLow)
    }
}
