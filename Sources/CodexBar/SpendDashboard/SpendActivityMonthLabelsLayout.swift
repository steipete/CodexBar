import SwiftUI

struct SpendActivityMonthLabelsLayout: Layout {
    let offsets: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: 18)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var trailing = bounds.width
        for index in subviews.indices.reversed() where self.offsets.indices.contains(index) {
            let subview = subviews[index]
            let size = subview.sizeThatFits(.unspecified)
            let x = Self.originX(offset: self.offsets[index], labelWidth: size.width, gridWidth: trailing)
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size))
            trailing = x - 4
        }
    }

    static func originX(offset: CGFloat, labelWidth: CGFloat, gridWidth: CGFloat) -> CGFloat {
        max(0, min(offset, gridWidth - labelWidth))
    }
}
