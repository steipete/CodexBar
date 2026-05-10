import SwiftUI

/// Static progress fill with no implicit animations, used inside the menu card.
struct UsageProgressBar: View {
    private static let paceStripeCount = 3
    private static func paceStripeWidth(for scale: CGFloat) -> CGFloat {
        2
    }

    private static func paceStripeSpan(for scale: CGFloat) -> CGFloat {
        let stripeCount = max(1, Self.paceStripeCount)
        return Self.paceStripeWidth(for: scale) * CGFloat(stripeCount)
    }

    let percent: Double
    let tint: Color
    let accessibilityLabel: String
    let pacePercent: Double?
    let paceOnTop: Bool
    let warningMarkerPercents: [Double]
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.displayScale) private var displayScale

    init(
        percent: Double,
        tint: Color,
        accessibilityLabel: String,
        pacePercent: Double? = nil,
        paceOnTop: Bool = true,
        warningMarkerPercents: [Double] = [])
    {
        self.percent = percent
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.pacePercent = pacePercent
        self.paceOnTop = paceOnTop
        self.warningMarkerPercents = warningMarkerPercents
    }

    private var clamped: Double {
        min(100, max(0, self.percent))
    }

    var body: some View {
        // Draw the entire progress bar — track, fill, and pace-tip punch-out — in a single Canvas.
        // A single Canvas uses Core Graphics internally and avoids the SwiftUI compositing modifiers
        // (.compositingGroup, .blendMode) that trigger Metal/RenderBox shader compilation on macOS 26.x,
        // which caused the status item icon to disappear (issue #805).
        Canvas { context, size in
            let scale = max(self.displayScale, 1)
            let fillWidth = size.width * self.clamped / 100
            let paceWidth = size.width * Self.clampedPercent(self.pacePercent) / 100
            let tipWidth = max(25, size.height * 6.5)
            let stripeInset = 1 / scale
            let tipOffset = paceWidth - tipWidth + (Self.paceStripeSpan(for: scale) / 2) + stripeInset
            let showTip = self.pacePercent != nil && tipWidth > 0.5
            let markerPercents = self.warningMarkerPercents
                .map(Self.clampedPercent)
                .filter { $0 > 0 && $0 < 100 }

            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)

            context.clip(to: Path(rect))

            // Track
            let trackPath = Path { p in p.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(trackPath, with: .color(MenuHighlightStyle.progressTrack(self.isHighlighted)))

            // Fill
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { p in p.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(
                    fillPath,
                    with: .color(MenuHighlightStyle.progressTint(self.isHighlighted, fallback: self.tint)))
            }

            if !markerPercents.isEmpty {
                let markerWidth = max(1 / scale, 2)
                let markerColor: Color = self.isHighlighted ? .white : .primary.opacity(0.72)
                for markerPercent in markerPercents {
                    let x = size.width * markerPercent / 100
                    let markerRect = CGRect(
                        x: x - markerWidth / 2,
                        y: 0,
                        width: markerWidth,
                        height: size.height)
                    context.fill(Path(markerRect), with: .color(markerColor))
                }
            }

            // Pace tip: punch-out + center stripe drawn within the canvas context using Core Graphics
            // blend modes so no SwiftUI compositing modifier (.blendMode, .compositingGroup) is needed.
            if showTip {
                let isDeficit = self.paceOnTop == false
                let useDeficitRed = isDeficit && self.isHighlighted == false
                let stripeColor: Color = if self.isHighlighted {
                    .white
                } else if useDeficitRed {
                    .red
                } else {
                    .green
                }

                let tipSize = CGSize(width: tipWidth, height: size.height)
                let stripes = Self.paceStripePaths(size: tipSize, scale: scale)
                let shift = CGAffineTransform(translationX: tipOffset, y: 0)

                // Punch out of the accumulated track+fill pixels.
                context.blendMode = .destinationOut
                context.fill(stripes.punched.applying(shift), with: .color(.white.opacity(0.9)))
                context.blendMode = .normal

                context.fill(stripes.center.applying(shift), with: .color(stripeColor))
            }
        }
        .frame(height: 6)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue("\(Int(self.clamped)) percent")
    }

    private static func paceStripePaths(size: CGSize, scale: CGFloat) -> (punched: Path, center: Path) {
        let rect = CGRect(origin: .zero, size: size)
        let extend = size.height * 2
        let stripeTopY: CGFloat = -extend
        let stripeBottomY: CGFloat = size.height + extend
        let align: (CGFloat) -> CGFloat = { value in
            (value * scale).rounded() / scale
        }

        let stripeWidth = Self.paceStripeWidth(for: scale)
        let punchWidth = stripeWidth * 3
        let stripeInset = 1 / scale
        let stripeAnchorX = align(rect.maxX - stripeInset)
        let stripeMinY = align(stripeTopY)
        let stripeMaxY = align(stripeBottomY)
        let anchorTopX = stripeAnchorX
        var punchedStripe = Path()
        var centerStripe = Path()
        let availableWidth = (anchorTopX - punchWidth) - rect.minX
        guard availableWidth >= 0 else { return (punchedStripe, centerStripe) }

        let punchRightTopX = align(anchorTopX)
        let punchLeftTopX = punchRightTopX - punchWidth
        let punchRightBottomX = punchRightTopX
        let punchLeftBottomX = punchLeftTopX
        punchedStripe.addPath(Path { path in
            path.move(to: CGPoint(x: punchLeftTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: punchRightTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: punchRightBottomX, y: stripeMaxY))
            path.addLine(to: CGPoint(x: punchLeftBottomX, y: stripeMaxY))
            path.closeSubpath()
        })

        let centerLeftTopX = align(punchLeftTopX + (punchWidth - stripeWidth) / 2)
        let centerRightTopX = centerLeftTopX + stripeWidth
        let centerRightBottomX = centerRightTopX
        let centerLeftBottomX = centerLeftTopX
        centerStripe.addPath(Path { path in
            path.move(to: CGPoint(x: centerLeftTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: centerRightTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: centerRightBottomX, y: stripeMaxY))
            path.addLine(to: CGPoint(x: centerLeftBottomX, y: stripeMaxY))
            path.closeSubpath()
        })

        return (punchedStripe, centerStripe)
    }

    private static func clampedPercent(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(100, max(0, value))
    }
}
