import Foundation
import Testing
@testable import CodexBar

struct ChartAxisLabelLayoutTests {
    @Test
    func `first date label center matches first bar center`() throws {
        let barCenter = try #require(ChartAxisLabelLayout.barCenterX(
            slotIndex: 0,
            slotCount: 16,
            chartWidth: 480))
        let labelCenter = ChartAxisLabelLayout.labelCenterX(
            tickX: barCenter,
            labelWidth: 44,
            anchor: ChartAxisLabelLayout.barCenteredAnchor)

        #expect(abs(labelCenter - barCenter) < 0.0001)
    }

    @Test
    func `last date label center matches last bar center`() throws {
        let barCenter = try #require(ChartAxisLabelLayout.barCenterX(
            slotIndex: 15,
            slotCount: 16,
            chartWidth: 480))
        let labelCenter = ChartAxisLabelLayout.labelCenterX(
            tickX: barCenter,
            labelWidth: 64,
            anchor: ChartAxisLabelLayout.barCenteredAnchor)

        #expect(abs(labelCenter - barCenter) < 0.0001)
    }
}
