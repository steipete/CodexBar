import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MenuBarVerticalAlignmentTests {
    @Test(arguments: [MenuBarLayoutSize.small, .regular, .large])
    func `stacked template vertical alignment matches native button across sizes`(size: MenuBarLayoutSize) throws {
        let layout = MenuBarLayout(lines: [
            [.space, .icon, .percent(window: .automatic)],
            [.space, .resetCountdown],
        ])
        try Self.assertStackedTemplateAligned(layout: layout, icon: Self.makeIcon(template: true), size: size)
    }

    @Test(arguments: [MenuBarLayoutSize.small, .regular, .large])
    func `text only stacked template centers vertically without bottom clipping`(size: MenuBarLayoutSize) throws {
        let layout = MenuBarLayout(lines: [[.percent(window: .session)], [.percent(window: .weekly)]])
        try Self.assertStackedTemplateAligned(layout: layout, icon: nil, size: size)
    }

    @Test(arguments: [MenuBarLayoutSize.small, .regular, .large])
    func `composed stacked provider rows center vertically and honor vertical adjustment`(
        size: MenuBarLayoutSize) throws
    {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let icon = Self.makeIcon(template: true)
        let rowLayout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic), .resetCountdown]])

        func compose(shift: Int, isStale: Bool = false) -> MenuBarLayoutRenderedTitle {
            let options = fixture.options(
                size: size, verticalAdjustment: shift, isStale: isStale, forceStackedStyle: true)
            return MenuBarLayoutRenderer.composeStackedProviderRows(
                top: renderer.render(layout: rowLayout, data: fixture.data(), icon: icon, options: options),
                bottom: renderer.render(
                    layout: rowLayout, data: fixture.data(provider: .claude), icon: icon, options: options),
                topProviderName: "Codex",
                bottomProviderName: "Claude")
        }

        let freshZero = compose(shift: 0)
        let staleZero = compose(shift: 0, isStale: true)
        #expect(freshZero.statusImage != nil)
        #expect(staleZero.statusImage == nil)
        let freshMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: freshZero)).midY
        let staleMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: staleZero)).midY
        #expect(abs(freshMid - staleMid) <= 1.0)

        let lowered = try Self.inkCentroidY(of: Self.statusBitmap(image: #require(compose(shift: -2).statusImage)))
        let raised = try Self.inkCentroidY(of: Self.statusBitmap(image: #require(compose(shift: 2).statusImage)))
        #expect(abs((lowered - raised) - 4.0) < 0.6)
    }

    @Test
    func `composed stacked rows normalize mixed baseline shifts when top row offset is zero`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let icon = Self.makeIcon(template: true)
        // At .large + verticalAdjustment +1, an icon top row gets baselineOffset 0 while a text bottom row gets -2.
        let topLayout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        let bottomLayout = MenuBarLayout(lines: [[.percent(window: .automatic)]])

        func compose(shift: Int) -> MenuBarLayoutRenderedTitle {
            let options = fixture.options(size: .large, verticalAdjustment: shift, forceStackedStyle: true)
            return MenuBarLayoutRenderer.composeStackedProviderRows(
                top: renderer.render(layout: topLayout, data: fixture.data(), icon: icon, options: options),
                bottom: renderer.render(
                    layout: bottomLayout, data: fixture.data(provider: .claude), icon: nil, options: options),
                topProviderName: "Codex",
                bottomProviderName: "Claude")
        }

        let zero = compose(shift: 0)
        let plusOne = compose(shift: 1)
        let topOffset = plusOne.attributedTitle.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? CGFloat
        let bottomOffset = plusOne.attributedTitle.attribute(
            .baselineOffset, at: plusOne.attributedTitle.length - 1, effectiveRange: nil) as? CGFloat
        #expect(topOffset == 0)
        #expect(bottomOffset == -2)

        let zeroBitmap = try Self.statusBitmap(image: #require(zero.statusImage))
        let plusOneBitmap = try Self.statusBitmap(image: #require(plusOne.statusImage))
        let zeroBounds = try Self.inkVerticalBounds(of: zeroBitmap)
        let plusOneBounds = try Self.inkVerticalBounds(of: plusOneBitmap)
        #expect(abs((plusOneBounds.maxY - plusOneBounds.minY) - (zeroBounds.maxY - zeroBounds.minY)) < 0.6)
        let delta = try Self.inkCentroidY(of: zeroBitmap) - Self.inkCentroidY(of: plusOneBitmap)
        #expect(abs(delta - 1.0) < 0.4)
    }

    @Test(arguments: [MenuBarLayoutSize.small, .regular, .large])
    func `high contrast spanning icon centers stacked text beside the icon`(size: MenuBarLayoutSize) throws {
        let fixture = MenuBarLayoutRendererTests()
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .session)], [.percent(window: .weekly)]])
        let output = MenuBarLayoutRenderer().render(
            layout: layout,
            data: fixture.data(),
            icon: Self.makeIcon(template: false),
            options: fixture.options(size: size, verticalAdjustment: 0, highContrast: true))
        let attachment = try #require(
            output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let expectedY = floor((NSFont.systemFont(ofSize: NSFont.systemFontSize).capHeight - 22) / 2)
        #expect(attachment.bounds.origin.y == expectedY)
        #expect(output.attributedTitle.size().height <= 22)

        let bitmap = try Self.statusBitmap(image: #require(attachment.image))
        let iconMid = try Self.inkVerticalBounds(of: bitmap, xRange: 0..<32).midY
        let textMid = try Self.inkVerticalBounds(of: bitmap, xRange: 32..<bitmap.pixelsWide).midY
        #expect(abs(textMid - iconMid) <= 1.25)
    }

    @Test
    func `high contrast spanning icon with meter centers vertically and moves meter once`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let icon = Self.makeIcon(template: false)
        let layout = MenuBarLayout(lines: [[.icon, .progressBar(window: .session)], [.percent(window: .weekly)]])

        func bitmap(shift: Int) throws -> NSBitmapImageRep {
            let output = renderer.render(
                layout: layout,
                data: fixture.data(),
                icon: icon,
                options: fixture.options(size: .regular, verticalAdjustment: shift, highContrast: true))
            let attachment = try #require(
                output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            return try Self.statusBitmap(image: #require(attachment.image))
        }

        let zeroBitmap = try bitmap(shift: 0)
        let raisedBitmap = try bitmap(shift: 2)
        let iconMid = try Self.inkVerticalBounds(of: zeroBitmap, xRange: 0..<32).midY
        let contentMid = try Self.inkVerticalBounds(of: zeroBitmap, xRange: 32..<zeroBitmap.pixelsWide).midY
        #expect(abs(contentMid - iconMid) <= 1.25)

        let zeroCentroid = try Self.inkCentroidY(of: zeroBitmap, xRange: 32..<zeroBitmap.pixelsWide)
        let raisedCentroid = try Self.inkCentroidY(of: raisedBitmap, xRange: 32..<raisedBitmap.pixelsWide)
        #expect(abs((zeroCentroid - raisedCentroid) - 2.0) < 0.6)
    }

    @Test
    func `single line template and plugin summary stay vertically aligned with native buttons`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic)]])

        for size in [MenuBarLayoutSize.small, .regular, .large] {
            let fresh = renderer.render(
                layout: layout, data: fixture.data(), icon: nil, options: fixture.options(size: size, isStale: false))
            let stale = renderer.render(
                layout: layout, data: fixture.data(), icon: nil, options: fixture.options(size: size, isStale: true))
            #expect(fresh.statusImage != nil)
            #expect(stale.statusImage == nil)
            let freshMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: fresh)).midY
            let staleMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: stale)).midY
            #expect(abs(freshMid - staleMid) <= 1.0)
        }

        let summaryRenderer = PluginMenuBarSummaryRenderer()
        let elements = [PluginMenuBarSummaryRenderer.Element(iconProvider: nil, value: "75%", accessibility: "75%")]
        let fallback = Self.makeIcon(template: true)
        let templateSummary = summaryRenderer.render(
            elements: elements,
            options: .init(sourceHash: "h1", monospaced: false, highContrast: false, appearance: "aqua"),
            fallbackIcon: { fallback })
        let highContrastSummary = summaryRenderer.render(
            elements: elements,
            options: .init(sourceHash: "h1", monospaced: false, highContrast: true, appearance: "aqua"),
            fallbackIcon: { fallback })
        #expect(templateSummary.statusImage != nil)
        #expect(highContrastSummary.statusImage == nil)
        let templateMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: templateSummary)).midY
        let highContrastMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: highContrastSummary)).midY
        #expect(abs(templateMid - highContrastMid) <= 0.75)
    }

    private static func assertStackedTemplateAligned(
        layout: MenuBarLayout, icon: NSImage?, size: MenuBarLayoutSize) throws
    {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let fresh = renderer.render(
            layout: layout, data: fixture.data(), icon: icon, options: fixture.options(size: size, isStale: false))
        let stale = renderer.render(
            layout: layout, data: fixture.data(), icon: icon, options: fixture.options(size: size, isStale: true))
        let freshImage = try #require(fresh.statusImage)
        #expect(stale.statusImage == nil)

        let freshMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: fresh)).midY
        let staleMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: stale)).midY
        #expect(abs(freshMid - staleMid) <= 1.0)
        #expect(try Self.inkVerticalBounds(of: Self.statusBitmap(image: freshImage)).bottomMargin > 0.5)
    }

    private struct InkVerticalBounds {
        let minY: CGFloat
        let maxY: CGFloat
        let midY: CGFloat
        let bottomMargin: CGFloat
    }

    private static func makeIcon(template: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            (template ? NSColor.black : NSColor.red).setFill()
            (template ? NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)) : NSBezierPath(rect: rect)).fill()
            return true
        }
        image.isTemplate = template
        return image
    }

    private static func buttonBitmap(for rendered: MenuBarLayoutRenderedTitle) throws -> NSBitmapImageRep {
        let width = max(44, rendered.statusItemWidth(gap: .regular))
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        button.isBordered = false
        button.appearance = NSAppearance(named: .aqua)
        _ = StatusItemController.applyMenuBarLayoutContent(rendered, for: button, gap: .regular)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width) * 2,
            pixelsHigh: 44,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        rep.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: rep)
        return rep
    }

    private static func statusBitmap(image: NSImage, scale: Int = 2) throws -> NSBitmapImageRep {
        let context = try #require(CGContext(
            data: nil,
            width: Int(image.size.width) * scale,
            height: Int(image.size.height) * scale,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        image.draw(in: NSRect(origin: .zero, size: image.size))
        let bitmap = try NSBitmapImageRep(cgImage: #require(context.makeImage()))
        bitmap.size = image.size
        return bitmap
    }

    private static func inkVerticalBounds(
        of bitmap: NSBitmapImageRep, xRange: Range<Int>? = nil) throws -> InkVerticalBounds
    {
        let xs = xRange ?? 0..<bitmap.pixelsWide
        let scale = CGFloat(bitmap.pixelsHigh) / max(1, bitmap.size.height)
        var minY = bitmap.pixelsHigh
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in xs where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        try #require(maxY >= minY, "Expected visible ink in bitmap")
        return InkVerticalBounds(
            minY: CGFloat(minY) / scale,
            maxY: CGFloat(maxY) / scale,
            midY: CGFloat(minY + maxY) / (2 * scale),
            bottomMargin: CGFloat(bitmap.pixelsHigh - 1 - maxY) / scale)
    }

    private static func inkCentroidY(of bitmap: NSBitmapImageRep, xRange: Range<Int>? = nil) throws -> CGFloat {
        let xs = xRange ?? 0..<bitmap.pixelsWide
        let scale = CGFloat(bitmap.pixelsHigh) / max(1, bitmap.size.height)
        var mass: CGFloat = 0
        var weightedY: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in xs {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                mass += alpha
                weightedY += CGFloat(y) * alpha
            }
        }
        try #require(mass > 10)
        return weightedY / mass / scale
    }
}
