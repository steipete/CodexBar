import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MenuCardNumericTypographyTests {
    @Test
    func `equal length percentages retain their width`() {
        let narrow = self.headerWidth(title: "Session", percent: "11% used")
        let wide = self.headerWidth(title: "Session", percent: "88% used")
        #expect(abs(narrow - wide) < 0.1)
    }

    @Test
    func `digits in metric titles keep proportional typography`() {
        let narrow = self.headerWidth(title: "Model 111111", percent: "50% used")
        let wide = self.headerWidth(title: "Model 888888", percent: "50% used")
        #expect(wide > narrow + 1)
    }

    @Test
    func `countdown digits retain width in the measured header`() {
        let narrow = self.headerWidth(title: "Session", percent: "50% used", reset: "Resets in 11h 11m")
        let wide = self.headerWidth(title: "Session", percent: "50% used", reset: "Resets in 88h 88m")
        #expect(abs(narrow - wide) < 0.1)
    }

    private func headerWidth(title: String, percent: String, reset: String? = nil) -> CGFloat {
        let header = MetricRowHeader(
            title: title,
            layoutTitle: title,
            resetText: reset,
            layoutResetText: reset,
            isHighlighted: false,
            percentText: percent,
            layoutPercentText: percent)
        return NSHostingController(rootView: header.fixedSize())
            .sizeThatFits(in: CGSize(width: 10000, height: 10000)).width
    }
}
