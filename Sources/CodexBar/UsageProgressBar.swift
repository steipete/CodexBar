import SwiftUI

/// Static progress fill with no implicit animations, used inside the menu card.
struct UsageProgressBar: View {
    enum MarkerKind: Equatable {
        case quotaWarning
        case workdayBoundary
    }

    struct Marker: Equatable {
        let percent: Double
        let kind: MarkerKind
    }

    private static let paceStripeCount = 3
    private static let stripePunchOpacity = 0.9

    private nonisolated static var warningMarkerPunchWidth: CGFloat {
        5
    }

    private nonisolated static var warningMarkerStripeWidth: CGFloat {
        1
    }

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
    let workdayMarkerPercents: [Double]
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.displayScale) private var displayScale

    init(
        percent: Double,
        tint: Color,
        accessibilityLabel: String,
        pacePercent: Double? = nil,
        paceOnTop: Bool = true,
        warningMarkerPercents: [Double] = [],
        workdayMarkerPercents: [Double] = [])
    {
        self.percent = percent
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.pacePercent = pacePercent
        self.paceOnTop = paceOnTop
        self.warningMarkerPercents = warningMarkerPercents
        self.workdayMarkerPercents = workdayMarkerPercents
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
            let fillPercent = Self.renderedFillPercent(self.clamped)
            let fillWidth = size.width * fillPercent / 100
            let paceWidth = size.width * Self.clampedPercent(self.pacePercent) / 100
            let tipWidth = max(25, size.height * 6.5)
            let stripeInset = 1 / scale
            let tipOffset = paceWidth - tipWidth + (Self.paceStripeSpan(for: scale) / 2) + stripeInset
            let showTip = self.pacePercent != nil && tipWidth > 0.5
            let markers = Self.resolvedMarkers(
                warningPercents: self.warningMarkerPercents,
                workdayPercents: self.workdayMarkerPercents)

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

            for marker in markers {
                let x = size.width * marker.percent / 100
                switch marker.kind {
                case .quotaWarning:
                    let markerRect = Self.warningMarkerRect(x: x, size: size, scale: scale)
                    let markerStripeRect = Self.warningMarkerStripeRect(markerRect, scale: scale)
                    let markerPunchPath = Path { p in
                        p.addRect(Self.extendedMarkerRect(markerRect, size: size))
                    }
                    let markerStripePath = Path { p in
                        p.addRect(Self.extendedMarkerRect(markerStripeRect, size: size))
                    }

                    // Match the pace stripe treatment: punch through the bar, then draw a slimmer neutral stripe.
                    context.blendMode = .destinationOut
                    context.fill(markerPunchPath, with: .color(.white.opacity(Self.stripePunchOpacity)))
                    context.blendMode = .normal
                    context.fill(
                        markerStripePath,
                        with: .color(Self.warningMarkerColor(isHighlighted: self.isHighlighted)))
                case .workdayBoundary:
                    let markerRect = Self.workdayMarkerRect(x: x, size: size, scale: scale)
                    context.fill(
                        Path(markerRect),
                        with: .color(Self.workdayMarkerColor(isHighlighted: self.isHighlighted)))
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
                context.fill(stripes.punched.applying(shift), with: .color(.white.opacity(Self.stripePunchOpacity)))
                context.blendMode = .normal

                context.fill(stripes.center.applying(shift), with: .color(stripeColor))
            }
        }
        .frame(height: 6)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue(self.markerAccessibilityValue)
    }

    private var markerAccessibilityValue: String {
        var parts = [L("%d percent", Self.displayPercent(self.clamped))]
        let markers = Self.resolvedMarkers(
            warningPercents: self.warningMarkerPercents,
            workdayPercents: self.workdayMarkerPercents)
        let warnings = markers.filter { $0.kind == .quotaWarning }.map(Self.markerPercentText)
        let workdays = markers.filter { $0.kind == .workdayBoundary }.map(Self.markerPercentText)
        if !warnings.isEmpty {
            parts.append("\(L("quota_warnings_title")): \(warnings.joined(separator: ", "))")
        }
        if !workdays.isEmpty {
            parts.append("\(L("weekly_progress_work_days_title")): \(workdays.joined(separator: ", "))")
        }
        return parts.joined(separator: ". ")
    }

    nonisolated static func resolvedMarkers(
        warningPercents: [Double],
        workdayPercents: [Double]) -> [Marker]
    {
        let warnings = Self.normalizedMarkerPercents(warningPercents)
        let workdays = Self.normalizedMarkerPercents(workdayPercents)
            .filter { workday in !warnings.contains { abs($0 - workday) < 0.001 } }
        return (
            warnings.map { Marker(percent: $0, kind: .quotaWarning) } +
                workdays.map { Marker(percent: $0, kind: .workdayBoundary) })
            .sorted { lhs, rhs in lhs.percent < rhs.percent }
    }

    private nonisolated static func normalizedMarkerPercents(_ values: [Double]) -> [Double] {
        values
            .map(self.clampedPercent)
            .filter { $0 > 0 && $0 < 100 }
            .reduce(into: [Double]()) { result, value in
                if !result.contains(where: { abs($0 - value) < 0.001 }) {
                    result.append(value)
                }
            }
    }

    private nonisolated static func markerPercentText(_ marker: Marker) -> String {
        "\(Int(marker.percent.rounded()))%"
    }

    /// Aligns edge rendering with the rounded percent label: sub-0.5% is empty and 99.5%+ is full.
    nonisolated static func renderedFillPercent(_ percent: Double) -> Double {
        let clamped = Self.clampedPercent(percent)
        let displayPercent = Self.displayPercent(clamped)
        if displayPercent <= 0 { return 0 }
        if displayPercent >= 100 { return 100 }
        return clamped
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

    nonisolated static func warningMarkerRect(x: CGFloat, size: CGSize, scale rawScale: CGFloat) -> CGRect {
        let scale = max(rawScale, 1)
        let width = Self.warningMarkerPunchWidth
        let align: (CGFloat) -> CGFloat = { value in
            (value * scale).rounded() / scale
        }

        return CGRect(
            x: align(x - width / 2),
            y: 0,
            width: width,
            height: align(size.height))
    }

    nonisolated static func warningMarkerStripeRect(_ markerRect: CGRect, scale rawScale: CGFloat) -> CGRect {
        let scale = max(rawScale, 1)
        let width = min(markerRect.width, max(1 / scale, Self.warningMarkerStripeWidth))
        let align: (CGFloat) -> CGFloat = { value in
            (value * scale).rounded() / scale
        }

        return CGRect(
            x: align(markerRect.midX - width / 2),
            y: markerRect.minY,
            width: width,
            height: markerRect.height)
    }

    nonisolated static func workdayMarkerRect(x: CGFloat, size: CGSize, scale rawScale: CGFloat) -> CGRect {
        let scale = max(rawScale, 1)
        let width = 1 / scale
        let height = max(1 / scale, size.height * 0.5)
        let align: (CGFloat) -> CGFloat = { value in
            (value * scale).rounded() / scale
        }
        return CGRect(
            x: align(x - width / 2),
            y: align(size.height - height),
            width: width,
            height: align(height))
    }

    private nonisolated static func extendedMarkerRect(_ rect: CGRect, size: CGSize) -> CGRect {
        let extend = size.height * 2
        return rect.insetBy(dx: 0, dy: -extend)
    }

    nonisolated static func warningMarkerColor(isHighlighted: Bool) -> Color {
        isHighlighted ? .white.opacity(0.96) : .primary.opacity(0.68)
    }

    nonisolated static func workdayMarkerColor(isHighlighted: Bool) -> Color {
        isHighlighted ? .white.opacity(0.55) : .primary.opacity(0.30)
    }

    private nonisolated static func displayPercent(_ percent: Double) -> Int {
        Int(self.clampedPercent(percent).rounded())
    }

    private nonisolated static func clampedPercent(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(100, max(0, value))
    }
}
