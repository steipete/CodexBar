import AppKit

extension MenuBarLayoutRenderer {
    /// A top-origin clockwise ring using the title's native tint and stale-state treatment.
    static func usageCircleImage(
        fillPercent: Double,
        size: CGFloat,
        icon: NSImage?,
        tint: NSColor,
        stale: Bool) -> NSImage
    {
        let diameter = max(1, size.isFinite ? size : 18)
        let fraction = fillPercent.isFinite ? min(1, max(0, fillPercent / 100)) : 0
        let alpha: CGFloat = stale ? 0.55 : 1
        let glyphSource = icon?.copy() as? NSImage
        glyphSource?.cacheMode = .never
        let geometry = glyphSource.flatMap(self.usageCircleGlyphGeometry)
        return NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let stroke = max(0.5, diameter / 16)
            let radius = max(0, (diameter - stroke) / 2)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: stroke / 2, dy: stroke / 2))
            track.lineWidth = stroke
            tint.withAlphaComponent(0.3 * alpha).setStroke()
            track.stroke()
            if fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * fraction,
                    clockwise: true)
                arc.lineWidth = stroke
                tint.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }
            let glyph = glyphSource.map {
                self.attachmentImage($0, tint: tint.withAlphaComponent(alpha), isMonochrome: false)
            }
            glyph?.cacheMode = .never
            if let glyph, let geometry {
                let clearance = stroke
                let innerRadius = max(0, diameter / 2 - stroke - clearance)
                let scale = innerRadius / geometry.radius
                glyph.draw(in: NSRect(
                    x: rect.midX - geometry.center.x * scale,
                    y: rect.midY - geometry.center.y * scale,
                    width: glyph.size.width * scale,
                    height: glyph.size.height * scale))
            }
            return true
        }
    }

    /// Measure only painted artwork, including its furthest corner, so asset padding does not
    /// shrink the mark and square or asymmetric logos still clear the circular track.
    private static func usageCircleGlyphGeometry(_ icon: NSImage) -> (center: NSPoint, radius: CGFloat)? {
        guard icon.size.width > 0, icon.size.height > 0,
              icon.size.width.isFinite, icon.size.height.isFinite else { return nil }
        let scale = 512 / max(icon.size.width, icon.size.height)
        let width = max(1, Int(ceil(icon.size.width * scale)))
        let height = max(1, Int(ceil(icon.size.height * scale)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: scale, y: scale)
        icon.draw(in: NSRect(origin: .zero, size: icon.size))
        NSGraphicsContext.restoreGraphicsState()
        var points: [NSPoint] = []
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 12 {
                points.append(NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
            }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let center = NSPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let radius = points.map {
            hypot(abs($0.x - center.x) + 0.5, abs($0.y - center.y) + 0.5)
        }.max() ?? 1
        return (NSPoint(x: center.x / scale, y: (CGFloat(height) - center.y) / scale), radius / scale)
    }
}
