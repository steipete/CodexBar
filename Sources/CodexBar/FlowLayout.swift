import SwiftUI

/// A layout that arranges children left-to-right, wrapping to a new row when they overflow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var isFirstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = isFirstInRow ? size.width : self.spacing + size.width
            if !isFirstInRow, currentX + neededWidth > maxWidth {
                totalHeight += currentRowHeight + self.spacing
                currentX = size.width
                currentRowHeight = size.height
                isFirstInRow = false
            } else {
                currentX += neededWidth
                currentRowHeight = max(currentRowHeight, size.height)
                isFirstInRow = false
            }
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: max(totalHeight, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0
        var isFirstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = isFirstInRow ? size.width : self.spacing + size.width
            if !isFirstInRow, currentX - bounds.minX + neededWidth > maxWidth {
                currentY += currentRowHeight + self.spacing
                currentX = bounds.minX
                currentRowHeight = size.height
                subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
                currentX += size.width
                isFirstInRow = false
            } else {
                if !isFirstInRow { currentX += self.spacing }
                subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
                currentX += size.width
                currentRowHeight = max(currentRowHeight, size.height)
                isFirstInRow = false
            }
        }
    }
}
