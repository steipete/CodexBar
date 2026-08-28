import SwiftUI

enum ChartAxisLabelLayout {
    /// Keeps the label's horizontal center on the x-axis value shared with its bar.
    static let barCenteredAnchor = UnitPoint.top

    static func barCenterX(slotIndex: Int, slotCount: Int, chartWidth: CGFloat) -> CGFloat? {
        guard slotCount > 0, (0..<slotCount).contains(slotIndex), chartWidth >= 0 else { return nil }
        let slotWidth = chartWidth / CGFloat(slotCount)
        return (CGFloat(slotIndex) + 0.5) * slotWidth
    }

    static func labelCenterX(tickX: CGFloat, labelWidth: CGFloat, anchor: UnitPoint) -> CGFloat {
        tickX + (0.5 - anchor.x) * labelWidth
    }
}
