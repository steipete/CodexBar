import SwiftUI

enum ChartAxisLabelLayout {
    /// Keeps the label's horizontal center on the x-axis value shared with its bar.
    static let barCenteredAnchor = UnitPoint.top
    /// Reserve room for full caption dates at both ends without shifting labels away from their bars.
    static let dateLabelEdgePadding: CGFloat = 32

    @MainActor
    static func dateLabel(_ text: Text) -> some View {
        text
            .font(.caption2)
            // Charts can propose a narrow width at plot edges even when the menu has room for the full date.
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
    }
}
