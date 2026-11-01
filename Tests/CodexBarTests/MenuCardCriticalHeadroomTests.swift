import AppKit
import CodexBarCore
import SwiftUI
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
    @MainActor
    func `healthy compact headers reserve no warning glyph space`() {
        let title = "Weekly 89% used"
        let header = MetricRowHeader(
            title: title,
            layoutTitle: title,
            resetText: nil,
            layoutResetText: nil,
            isHighlighted: false,
            isCriticallyLow: false)
        let plain = Text(title).font(.body).fontWeight(.medium).lineLimit(1)
        let proposal = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let healthySize = NSHostingController(rootView: header).sizeThatFits(in: proposal)
        let plainSize = NSHostingController(rootView: plain).sizeThatFits(in: proposal)
        #expect(abs(healthySize.width - plainSize.width) < 1)
        #expect(abs(healthySize.height - plainSize.height) < 1)
    }

    @Test
    @MainActor
    func `critical compact headers include the visible warning glyph`() {
        let title = "Weekly 90% used"
        let proposal = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        func size(critical: Bool) -> CGSize {
            NSHostingController(rootView: MetricRowHeader(
                title: title,
                layoutTitle: title,
                resetText: nil,
                layoutResetText: nil,
                isHighlighted: false,
                isCriticallyLow: critical)).sizeThatFits(in: proposal)
        }
        #expect(size(critical: true).width > size(critical: false).width)
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
