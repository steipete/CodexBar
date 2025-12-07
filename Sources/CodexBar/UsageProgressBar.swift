import SwiftUI

/// Static progress fill with no implicit animations, used inside the menu card.
struct UsageProgressBar: View {
    let percentLeft: Double
    let tint: Color

    private var clamped: Double {
        min(100, max(0, self.percentLeft))
    }

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = proxy.size.width * self.clamped / 100
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(self.tint)
                    .frame(width: fillWidth)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Usage remaining")
        .accessibilityValue("\(Int(self.clamped)) percent")
        .drawingGroup()
    }
}
