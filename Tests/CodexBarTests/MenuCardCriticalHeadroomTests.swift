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
    func `critical warning preserves the frozen reset header height`() {
        for width in stride(from: CGFloat(180), through: 340, by: 1) {
            func height(critical: Bool) -> CGFloat {
                NSHostingController(rootView: MetricRowHeader(
                    title: "Weekly 90% used",
                    layoutTitle: "Weekly 90% used",
                    resetText: "Resets in 3d 20h",
                    layoutResetText: "Resets in 3d 20h",
                    isHighlighted: false,
                    isCriticallyLow: critical).frame(width: width))
                    .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
            }
            #expect(
                height(critical: false) == height(critical: true),
                "Critical warning changed frozen header height at width \(width)")
        }
    }

    @Test
    @MainActor
    func `healthy reset content uses full width inside the safe height`() {
        func header(critical: Bool) -> MetricRowHeader {
            MetricRowHeader(
                title: "Weekly 90% used",
                layoutTitle: "Weekly 90% used",
                resetText: "Resets in 3d 20h",
                layoutResetText: "Resets in 3d 20h",
                isHighlighted: false,
                isCriticallyLow: critical)
        }
        var foundFitBoundary = false
        for width in stride(from: CGFloat(150), through: 400, by: 1) {
            let proposal = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            let healthyContent = NSHostingController(rootView: header(critical: false).visibleContent
                .frame(width: width))
                .sizeThatFits(in: proposal)
            let criticalContent = NSHostingController(rootView: header(critical: true).visibleContent
                .frame(width: width))
                .sizeThatFits(in: proposal)
            guard healthyContent.height < criticalContent.height else { continue }
            let safeHeader = NSHostingController(rootView: header(critical: false).frame(width: width))
                .sizeThatFits(in: proposal)
            // Healthy content fits one line; the warning needs two. Both fit inside the frozen envelope.
            #expect(safeHeader.height == criticalContent.height)
            foundFitBoundary = true
            break
        }
        #expect(foundFitBoundary, "Expected a width where only the healthy content fits horizontally")
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
