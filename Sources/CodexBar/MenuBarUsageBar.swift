import AppKit
import CodexBarCore

/// A thin colored vertical bar in the menu bar showing remaining API capacity.
///
/// Visual: a mini "fuel gauge" pill — green when ahead of limits, orange when
/// approaching, red when nearly exhausted. Updates alongside the main CodexBar icon.
@MainActor
final class MenuBarUsageBar {
    private var statusItem: NSStatusItem
    private let statusBar: NSStatusBar

    // Pixel grid mirrors the main IconRenderer (2× retina output).
    private static let ptWidth: CGFloat = 8
    private static let ptHeight: CGFloat = 18
    private static let scale: CGFloat = 2

    init(statusBar: NSStatusBar = .system) {
        self.statusBar = statusBar
        self.statusItem = statusBar.statusItem(withLength: Self.ptWidth)
        self.statusItem.button?.imageScaling = .scaleNone
        self.statusItem.isVisible = false
    }

    /// Update the bar with the best remaining-percent value across enabled providers.
    /// Passes `nil` to hide the bar (e.g. when no provider has data yet).
    func update(remainingPercent: Double?) {
        guard let remaining = remainingPercent else {
            self.statusItem.isVisible = false
            return
        }
        self.statusItem.isVisible = true
        self.statusItem.button?.image = Self.makeBarImage(remainingPercent: remaining)
    }

    // MARK: - Image Generation

    private static func makeBarImage(remainingPercent: Double) -> NSImage {
        let size = NSSize(width: ptWidth, height: ptHeight)
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        defer { image.unlockFocus() }

        let trackW: CGFloat = 4
        let trackH: CGFloat = 16
        let trackX = (ptWidth - trackW) / 2
        let trackY = (ptHeight - trackH) / 2
        let r: CGFloat = 2          // corner radius

        // ── track (empty background) ──────────────────────────────────────
        let trackRect = CGRect(x: trackX, y: trackY, width: trackW, height: trackH)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: r, yRadius: r).fill()

        // ── fill (remaining capacity, anchored at bottom) ─────────────────
        let clampedRemaining = min(100, max(0, remainingPercent))
        let fillH = max(r * 2, trackH * CGFloat(clampedRemaining) / 100)
        let fillRect = CGRect(x: trackX, y: trackY, width: trackW, height: fillH)

        let fillColor: NSColor = {
            if clampedRemaining > 40 { return .systemGreen }
            if clampedRemaining > 20 { return .systemOrange }
            return .systemRed
        }()

        fillColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: r, yRadius: r).fill()

        // ── thin stroke outline ───────────────────────────────────────────
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        let strokePath = NSBezierPath(roundedRect: trackRect.insetBy(dx: 0.25, dy: 0.25), xRadius: r, yRadius: r)
        strokePath.lineWidth = 0.5
        strokePath.stroke()

        image.isTemplate = false    // keep colors; NOT a template image
        return image
    }
}
