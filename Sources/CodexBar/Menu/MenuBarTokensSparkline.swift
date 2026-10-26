import AppKit
import CodexBarCore

/// Only reported minutes participate; a column keeps its peak rather than hiding brief bursts.
struct MenuBarTokensSparkline: Hashable {
    let values: [Double]
    let latest: Int?

    init(minutes: [ProviderThroughputSnapshot.Minute], columnCount: Int = 18) {
        let reported = Array(minutes.prefix { !$0.isPending })
        let count = min(max(1, columnCount), reported.count)
        self.values = (0..<count).map { column in
            let start = column * reported.count / count
            let end = (column + 1) * reported.count / count
            return Double(reported[start..<end].map(\.totalTokens).max() ?? 0)
        }
        self.latest = reported.last?.totalTokens
    }

    init(values: [Double], latest: Int?) {
        self.values = values
        self.latest = latest
    }

    func image(height: CGFloat, highlighted: Bool) -> NSImage? {
        guard !self.values.isEmpty else { return nil }
        let size = NSSize(width: 34, height: height)
        let values = self.values
        let scale = MenuUsageBarMetrics.scale(values: values, roundedHeadroom: true)
        let image = NSImage(size: size, flipped: false) { _ in
            let spacing: CGFloat = 0.5
            let width = (size.width - spacing * CGFloat(values.count - 1)) / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let barHeight = MenuUsageBarMetrics.height(value: value, scale: scale, available: size.height)
                NSColor.black.withAlphaComponent(MenuUsageBarMetrics.opacity(
                    value: value, scale: scale, highlighted: highlighted)).setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: CGFloat(index) * (width + spacing), y: 0, width: width, height: barHeight),
                    xRadius: min(1.5, width / 2),
                    yRadius: 1.5).fill()
            }
            NSColor.black.withAlphaComponent(0.22).setFill()
            NSRect(x: 0, y: 0, width: size.width, height: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
