import AppKit

enum UsageColorLevel: Sendable {
    /// Returns a smoothly interpolated tint color based on usage percentage.
    /// - 0-70%: green blending toward orange
    /// - 70-90%: orange blending toward red
    /// - >= 90%: red
    /// - nil usage: returns nil (monochrome fallback)
    static func tintColor(for usedPercent: Double?) -> NSColor? {
        guard let pct = usedPercent else { return nil }
        let clamped = min(max(pct, 0), 100)

        if clamped < 70 {
            let fraction = CGFloat(clamped / 70)
            return NSColor.systemGreen.blended(withFraction: fraction, of: .systemOrange)
        } else if clamped < 90 {
            let fraction = CGFloat((clamped - 70) / 20)
            return NSColor.systemOrange.blended(withFraction: fraction, of: .systemRed)
        } else {
            return .systemRed
        }
    }
}
