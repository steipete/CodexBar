import SwiftUI

/// Static progress fill with no implicit animations, used inside the menu card.
struct UsageProgressBar: View {
    private static let paceStripeWidth: CGFloat = 2
    private static let paceStripeCount = 3
    private static var paceStripeSpan: CGFloat {
        let stripeCount = max(1, Self.paceStripeCount)
        return Self.paceStripeWidth * CGFloat(stripeCount)
    }

    let percent: Double
    let tint: Color
    let accessibilityLabel: String
    let pacePercent: Double?
    let paceOnTop: Bool
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    init(
        percent: Double,
        tint: Color,
        accessibilityLabel: String,
        pacePercent: Double? = nil,
        paceOnTop: Bool = true)
    {
        self.percent = percent
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.pacePercent = pacePercent
        self.paceOnTop = paceOnTop
    }

    private var clamped: Double {
        min(100, max(0, self.percent))
    }

    private var tipMaxOpacity: Double {
        if self.isHighlighted {
            return 0.55
        }
        return 0.15
    }

    private var tipMidOpacity: Double {
        self.tipMaxOpacity * 0.5
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = max(self.displayScale, 1)
            let fillWidth = proxy.size.width * self.clamped / 100
            let paceWidth = proxy.size.width * Self.clampedPercent(self.pacePercent) / 100
            let tipWidth = max(25, proxy.size.height * 6.5)
            let stripeInset = 1 / scale
            let tipOffset = paceWidth - tipWidth + (Self.paceStripeSpan / 2) + stripeInset
            let showTip = self.pacePercent != nil && tipWidth > 0.5
            let needsPunchCompositing = showTip
            let bar = ZStack(alignment: .leading) {
                Capsule()
                    .fill(MenuHighlightStyle.progressTrack(self.isHighlighted))
                self.actualBar(width: fillWidth)
                if showTip {
                    self.paceTip(width: tipWidth)
                        .offset(x: tipOffset)
                }
            }
            .clipped()
            if self.isHighlighted {
                bar
                    .compositingGroup()
                    .drawingGroup()
            } else if needsPunchCompositing {
                bar
                    .compositingGroup()
            } else {
                bar
            }
        }
        .frame(height: 6)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue("\(Int(self.clamped)) percent")
    }

    private func actualBar(width: CGFloat) -> some View {
        Capsule()
            .fill(MenuHighlightStyle.progressTint(self.isHighlighted, fallback: self.tint))
            .frame(width: width)
            .contentShape(Rectangle())
            .allowsHitTesting(false)
    }

    private func paceTip(width: CGFloat) -> some View {
        let isDeficit = self.paceOnTop == false
        let useDeficitRed = isDeficit && self.isHighlighted == false
        func stripePaths(size: CGSize, scale: CGFloat) -> (punched: Path, center: Path) {
            let rect = CGRect(origin: .zero, size: size)
            let extend = size.height * 2
            let stripeTopY: CGFloat = -extend
            let stripeBottomY: CGFloat = size.height + extend
            let diagonalInset: CGFloat = size.height
            let align: (CGFloat) -> CGFloat = { value in
                (value * scale).rounded() / scale
            }

            let stripeWidth = Self.paceStripeWidth
            let punchWidth = stripeWidth * 3.5
            let stripeInset = 1 / scale
            let stripeAnchorX = align(rect.maxX - stripeInset)
            let stripeMinY = align(stripeTopY)
            let stripeMaxY = align(stripeBottomY)
            let stripeHeight = stripeMaxY - stripeMinY
            let slope = diagonalInset / max(size.height, 1)
            let deltaX = slope * stripeHeight
            let anchorTopX = stripeAnchorX - slope * stripeMinY
            var punchedStripe = Path()
            var centerStripe = Path()
            let availableWidth = (anchorTopX - punchWidth) - rect.minX
            guard availableWidth >= 0 else { return (punchedStripe, centerStripe) }

            let punchRightTopX = align(anchorTopX)
            let punchLeftTopX = punchRightTopX - punchWidth
            let punchRightBottomX = punchRightTopX - deltaX
            let punchLeftBottomX = punchLeftTopX - deltaX
            punchedStripe.addPath(Path { path in
                path.move(to: CGPoint(x: punchLeftTopX, y: stripeMinY))
                path.addLine(to: CGPoint(x: punchRightTopX, y: stripeMinY))
                path.addLine(to: CGPoint(x: punchRightBottomX, y: stripeMaxY))
                path.addLine(to: CGPoint(x: punchLeftBottomX, y: stripeMaxY))
                path.closeSubpath()
            })

            let centerLeftTopX = align(punchLeftTopX + (punchWidth - stripeWidth) / 2)
            let centerRightTopX = centerLeftTopX + stripeWidth
            let centerRightBottomX = centerRightTopX - deltaX
            let centerLeftBottomX = centerLeftTopX - deltaX
            centerStripe.addPath(Path { path in
                path.move(to: CGPoint(x: centerLeftTopX, y: stripeMinY))
                path.addLine(to: CGPoint(x: centerRightTopX, y: stripeMinY))
                path.addLine(to: CGPoint(x: centerRightBottomX, y: stripeMaxY))
                path.addLine(to: CGPoint(x: centerLeftBottomX, y: stripeMaxY))
                path.closeSubpath()
            })

            return (punchedStripe, centerStripe)
        }

        return ZStack {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let diagonalInset: CGFloat = size.height
                let scale = max(self.displayScale, 1)
                let tipPath = Path { path in
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX - diagonalInset, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.closeSubpath()
                }
                context.clip(to: tipPath)
                let stripes = stripePaths(size: size, scale: scale)
                context.fill(stripes.punched, with: .color(.white))
            }
            .blendMode(.destinationOut)

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let diagonalInset: CGFloat = size.height
                let scale = max(self.displayScale, 1)
                let tipPath = Path { path in
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX - diagonalInset, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.closeSubpath()
                }
                context.clip(to: tipPath)
                let stripes = stripePaths(size: size, scale: scale)
                let stripeColor: Color = if self.isHighlighted {
                    .white
                } else if useDeficitRed {
                    .red
                } else {
                    .green
                }
                context.fill(stripes.center, with: .color(stripeColor))
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .allowsHitTesting(false)
    }

    private static func clampedPercent(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(100, max(0, value))
    }
}
