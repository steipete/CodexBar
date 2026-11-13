import AppKit

/// Inputs for one graphical menu-bar meter. Grouped so the render entry points stay within the
/// repository's function parameter limit.
struct MenuBarMeterSpec {
    let fillPercent: Double
    let size: NSSize
    let tint: NSColor
    let isStale: Bool
    var style: UsageBarStyle = .capsule
    var remainingPercent: Double = 0
    var highContrast: Bool = false
}

/// Compact battery meter for the menu bar. Geometry scales with the meter height because the
/// menu card's fixed insets would collapse the core at 5-7pt; severity semantics are shared
/// with `UsageProgressBar` so both surfaces agree on thresholds.
enum MenuBarBatteryMeter {
    static func rects(size: CGSize) -> (body: CGRect, inner: CGRect, nub: CGRect) {
        let nubWidth = max(1.5, (size.height * 0.25).rounded())
        let nubGap: CGFloat = 1
        let bodyWidth = max(0, size.width - nubWidth - nubGap)
        let body = CGRect(
            x: 0.5,
            y: 0.5,
            width: max(0, bodyWidth - 1),
            height: max(0, size.height - 1))
        let inset = max(1, (size.height * 0.18).rounded())
        let inner = CGRect(
            x: inset,
            y: inset,
            width: max(0, bodyWidth - inset * 2),
            height: max(0, size.height - inset * 2))
        let nubHeight = max(2, (size.height * 0.4).rounded())
        let nub = CGRect(
            x: bodyWidth + nubGap,
            y: (size.height - nubHeight) / 2,
            width: nubWidth,
            height: nubHeight)
        return (body, inner, nub)
    }

    static func fillWidth(percent: Double, size: CGSize) -> CGFloat {
        self.rects(size: size).inner.width * UsageProgressBar.renderedFillPercent(percent) / 100
    }

    static func tint(remainingPercent: Double) -> NSColor {
        switch UsageProgressBar.batteryLevel(remainingPercent: remainingPercent) {
        case .ample: .systemGreen
        case .tight: .systemYellow
        case .critical: .systemRed
        }
    }

    static func image(_ spec: MenuBarMeterSpec) -> NSImage {
        let alpha: CGFloat = spec.isStale ? 0.55 : 1.0
        let rects = self.rects(size: spec.size)
        let shellColor = spec.tint.withAlphaComponent(0.5 * alpha)
        let trackColor = spec.tint.withAlphaComponent(0.18 * alpha)
        // High contrast is the menu bar's monochrome switch, so the severity palette yields to the tint.
        let fillColor = (spec.highContrast ? spec.tint : self.tint(remainingPercent: spec.remainingPercent))
            .withAlphaComponent(alpha)
        let fillWidth = self.fillWidth(percent: spec.fillPercent, size: spec.size)
        let bodyRadius = min(2, spec.size.height * 0.3)
        let innerRadius = max(0.5, spec.size.height * 0.15)
        return NSImage(size: spec.size, flipped: false) { _ in
            let innerPath = NSBezierPath(
                roundedRect: rects.inner,
                xRadius: innerRadius,
                yRadius: innerRadius)
            trackColor.setFill()
            innerPath.fill()
            if fillWidth > 0 {
                NSGraphicsContext.saveGraphicsState()
                innerPath.addClip()
                fillColor.setFill()
                NSBezierPath(rect: CGRect(
                    x: rects.inner.minX,
                    y: rects.inner.minY,
                    width: min(fillWidth, rects.inner.width),
                    height: rects.inner.height)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let bodyPath = NSBezierPath(
                roundedRect: rects.body,
                xRadius: bodyRadius,
                yRadius: bodyRadius)
            shellColor.setStroke()
            bodyPath.lineWidth = 1
            bodyPath.stroke()
            let nubPath = NSBezierPath(roundedRect: rects.nub, xRadius: 0.5, yRadius: 0.5)
            shellColor.setFill()
            nubPath.fill()
            return true
        }
    }
}
