import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MenuBarVerticalAlignmentTests {
    @Test(arguments: [MenuBarLayoutSize.small, .regular, .large])
    func `stacked template vertical alignment matches native button across sizes`(size: MenuBarLayoutSize) throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let icon = Self.makeTemplateIcon()
        let layout = MenuBarLayout(lines: [
            [.space, .icon, .percent(window: .automatic)],
            [.space, .resetCountdown],
        ])

        let fresh = renderer.render(
            layout: layout,
            data: fixture.data(),
            icon: icon,
            options: fixture.options(size: size, isStale: false))
        let stale = renderer.render(
            layout: layout,
            data: fixture.data(),
            icon: icon,
            options: fixture.options(size: size, isStale: true))

        let freshImage = try #require(fresh.statusImage)
        #expect(stale.statusImage == nil)

        let freshBounds = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: fresh))
        let staleBounds = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: stale))
        #expect(
            abs(freshBounds.midY - staleBounds.midY) <= 1.0,
            "Fresh stacked template (\(freshBounds.midY) pt) drifted from stale title (\(staleBounds.midY) pt)")

        let imageBitmap = try Self.statusBitmap(image: freshImage, scale: 2)
        let imageBounds = try Self.inkVerticalBounds(of: imageBitmap)
        #expect(imageBounds.bottomMargin > 0.5, "Stacked template at \(size) should leave bottom margin inside 22 pt")
    }

    @Test(arguments: [MenuBarLayoutSize.small, .regular, .large])
    func `composed stacked provider rows center vertically and honor vertical adjustment`(
        size: MenuBarLayoutSize) throws
    {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let icon = Self.makeTemplateIcon()
        let rowLayout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic), .resetCountdown]])

        func compose(shift: Int, isStale: Bool = false) -> MenuBarLayoutRenderedTitle {
            let options = fixture.options(
                size: size,
                verticalAdjustment: shift,
                isStale: isStale,
                forceStackedStyle: true)
            let top = renderer.render(layout: rowLayout, data: fixture.data(), icon: icon, options: options)
            let bottom = renderer.render(
                layout: rowLayout,
                data: fixture.data(provider: .claude),
                icon: icon,
                options: options)
            return MenuBarLayoutRenderer.composeStackedProviderRows(
                top: top,
                bottom: bottom,
                topProviderName: "Codex",
                bottomProviderName: "Claude")
        }

        let freshZero = compose(shift: 0)
        let staleZero = compose(shift: 0, isStale: true)
        #expect(freshZero.statusImage != nil)
        #expect(staleZero.statusImage == nil)

        let freshBounds = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: freshZero))
        let staleBounds = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: staleZero))
        #expect(
            abs(freshBounds.midY - staleBounds.midY) <= 1.0,
            "Composed stacked template (\(freshBounds.midY) pt) drifted from stale title (\(staleBounds.midY) pt)")

        let lowered = try Self.inkCentroidY(
            of: Self.statusBitmap(image: #require(compose(shift: -2).statusImage), scale: 2))
        let raised = try Self.inkCentroidY(
            of: Self.statusBitmap(image: #require(compose(shift: 2).statusImage), scale: 2))
        #expect(abs((lowered - raised) - 4.0) < 0.6)
    }

    @Test
    func `composed stacked rows normalize mixed baseline shifts when top row offset is zero`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let icon = Self.makeTemplateIcon()
        // At .large + verticalAdjustment +1, an icon-bearing top row gets baselineOffset == 0
        // while a text-only bottom row without an icon gets baselineOffset == -2.
        let topLayout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        let bottomLayout = MenuBarLayout(lines: [[.percent(window: .automatic)]])

        func compose(shift: Int) -> MenuBarLayoutRenderedTitle {
            let options = fixture.options(size: .large, verticalAdjustment: shift, forceStackedStyle: true)
            let top = renderer.render(layout: topLayout, data: fixture.data(), icon: icon, options: options)
            let bottom = renderer.render(
                layout: bottomLayout,
                data: fixture.data(provider: .claude),
                icon: nil,
                options: options)
            return MenuBarLayoutRenderer.composeStackedProviderRows(
                top: top,
                bottom: bottom,
                topProviderName: "Codex",
                bottomProviderName: "Claude")
        }

        let zero = compose(shift: 0)
        let plusOne = compose(shift: 1)
        let topOffset = plusOne.attributedTitle.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? CGFloat
        let bottomOffset = plusOne.attributedTitle.attribute(
            .baselineOffset,
            at: plusOne.attributedTitle.length - 1,
            effectiveRange: nil) as? CGFloat
        #expect(topOffset == 0)
        #expect(bottomOffset == -2)

        let zeroBitmap = try Self.statusBitmap(image: #require(zero.statusImage), scale: 2)
        let plusOneBitmap = try Self.statusBitmap(image: #require(plusOne.statusImage), scale: 2)
        // Moving verticalAdjustment from 0 to +1 should raise the entire composed image by 1 pt,
        // without leaving the lower row 2 pt behind.
        let zeroBounds = try Self.inkVerticalBounds(of: zeroBitmap)
        let plusOneBounds = try Self.inkVerticalBounds(of: plusOneBitmap)
        let zeroSpan = zeroBounds.maxY - zeroBounds.minY
        let plusOneSpan = plusOneBounds.maxY - plusOneBounds.minY
        #expect(
            abs(plusOneSpan - zeroSpan) < 0.6,
            "Mixed-row vertical span changed from \(zeroSpan) pt to \(plusOneSpan) pt")
        let zeroCentroid = try Self.inkCentroidY(of: zeroBitmap)
        let plusOneCentroid = try Self.inkCentroidY(of: plusOneBitmap)
        #expect(
            abs((zeroCentroid - plusOneCentroid) - 1.0) < 0.4,
            "Mixed-row composed image shifted by \(zeroCentroid - plusOneCentroid) pt instead of 1.0 pt")
    }

    @Test(arguments: [MenuBarLayoutSize.small, .regular, .large])
    func `high contrast spanning icon centers stacked text beside the icon`(size: MenuBarLayoutSize) throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let icon = Self.makeSolidRedIcon(size: 16)
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .session)], [.percent(window: .weekly)]])

        let output = renderer.render(
            layout: layout,
            data: fixture.data(),
            icon: icon,
            options: fixture.options(size: size, verticalAdjustment: 0, highContrast: true))
        let attachment = try #require(
            output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let menuBarFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #expect(attachment.bounds.origin.y == floor((menuBarFont.capHeight - 22) / 2))
        #expect(output.attributedTitle.size().height <= 22)
        let image = try #require(attachment.image)
        let bitmap = try Self.statusBitmap(image: image, scale: 2)

        let iconMid = try Self.inkVerticalBounds(of: bitmap, xRange: 0..<(16 * 2)).midY
        let textMid = try Self.inkVerticalBounds(of: bitmap, xRange: (16 * 2)..<bitmap.pixelsWide).midY
        #expect(
            abs(textMid - iconMid) <= 1.25,
            "High-contrast spanning text (\(textMid) pt) drifted from centered icon (\(iconMid) pt)")
    }

    @Test(arguments: [MenuBarLayoutSize.small, .regular, .large])
    func `text only stacked template centers vertically without bottom clipping`(size: MenuBarLayoutSize) throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [
            [.percent(window: .session)],
            [.percent(window: .weekly)],
        ])

        let fresh = renderer.render(
            layout: layout,
            data: fixture.data(),
            icon: nil,
            options: fixture.options(size: size, isStale: false))
        let stale = renderer.render(
            layout: layout,
            data: fixture.data(),
            icon: nil,
            options: fixture.options(size: size, isStale: true))

        let freshImage = try #require(fresh.statusImage)
        #expect(stale.statusImage == nil)

        let freshBounds = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: fresh))
        let staleBounds = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: stale))
        #expect(
            abs(freshBounds.midY - staleBounds.midY) <= 1.0,
            "Text-only stacked template (\(freshBounds.midY) pt) drifted from stale title (\(staleBounds.midY) pt)")

        let imageBounds = try Self.inkVerticalBounds(of: Self.statusBitmap(image: freshImage, scale: 2))
        #expect(imageBounds.bottomMargin > 0.5, "Text-only stacked template at \(size) should not touch the bottom")
    }

    @Test
    func `high contrast spanning icon with meter centers vertically and moves meter once`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let icon = Self.makeSolidRedIcon(size: 16)
        let layout = MenuBarLayout(lines: [
            [.icon, .progressBar(window: .session)],
            [.percent(window: .weekly)],
        ])

        let zero = renderer.render(
            layout: layout,
            data: fixture.data(),
            icon: icon,
            options: fixture.options(size: .regular, verticalAdjustment: 0, highContrast: true))
        let raised = renderer.render(
            layout: layout,
            data: fixture.data(),
            icon: icon,
            options: fixture.options(size: .regular, verticalAdjustment: 2, highContrast: true))

        let zeroAttachment = try #require(
            zero.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let raisedAttachment = try #require(
            raised.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let zeroBitmap = try Self.statusBitmap(image: #require(zeroAttachment.image), scale: 2)
        let raisedBitmap = try Self.statusBitmap(image: #require(raisedAttachment.image), scale: 2)

        let iconMid = try Self.inkVerticalBounds(of: zeroBitmap, xRange: 0..<(16 * 2)).midY
        let contentMid = try Self.inkVerticalBounds(of: zeroBitmap, xRange: (16 * 2)..<zeroBitmap.pixelsWide).midY
        #expect(
            abs(contentMid - iconMid) <= 1.25,
            "Spanning meter content (\(contentMid) pt) drifted from centered icon (\(iconMid) pt)")

        let zeroContentCentroid = try Self.inkCentroidY(of: zeroBitmap, xRange: (16 * 2)..<zeroBitmap.pixelsWide)
        let raisedContentCentroid = try Self.inkCentroidY(
            of: raisedBitmap,
            xRange: (16 * 2)..<raisedBitmap.pixelsWide)
        #expect(abs((zeroContentCentroid - raisedContentCentroid) - 2.0) < 0.6)
    }

    @Test
    func `single line template and plugin summary stay vertically aligned with native buttons`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic)]])

        for size in [MenuBarLayoutSize.small, .regular, .large] {
            let fresh = renderer.render(
                layout: layout,
                data: fixture.data(),
                icon: nil,
                options: fixture.options(size: size, isStale: false))
            let stale = renderer.render(
                layout: layout,
                data: fixture.data(),
                icon: nil,
                options: fixture.options(size: size, isStale: true))
            #expect(fresh.statusImage != nil)
            #expect(stale.statusImage == nil)
            let freshMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: fresh)).midY
            let staleMid = try Self.inkVerticalBounds(of: Self.buttonBitmap(for: stale)).midY
            #expect(abs(freshMid - staleMid) <= 1.0)
        }

        let summaryRenderer = PluginMenuBarSummaryRenderer()
        let elements = [PluginMenuBarSummaryRenderer.Element(
            iconProvider: nil,
            value: "75%",
            accessibility: "Usage: 75%")]
        let fallback = Self.makeTemplateIcon()
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

    private struct InkVerticalBounds {
        let minY: CGFloat
        let maxY: CGFloat
        let midY: CGFloat
        let bottomMargin: CGFloat
    }

    private static func makeTemplateIcon(size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func makeSolidRedIcon(size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func buttonBitmap(for rendered: MenuBarLayoutRenderedTitle) throws -> NSBitmapImageRep {
        let width = max(44, rendered.statusItemWidth(gap: .regular))
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        button.isBordered = false
        button.appearance = NSAppearance(named: .aqua)
        _ = StatusItemController.applyMenuBarLayoutContent(rendered, for: button, gap: .regular)
        let scale = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width) * scale,
            pixelsHigh: 22 * scale,
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

    private static func statusBitmap(image: NSImage, scale: Int) throws -> NSBitmapImageRep {
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
        of bitmap: NSBitmapImageRep,
        xRange: Range<Int>? = nil,
        yRange: Range<Int>? = nil) throws -> InkVerticalBounds
    {
        let xs = xRange ?? 0..<bitmap.pixelsWide
        let ys = yRange ?? 0..<bitmap.pixelsHigh
        let scale = CGFloat(bitmap.pixelsHigh) / max(1, bitmap.size.height)
        var minY = bitmap.pixelsHigh
        var maxY = -1
        for y in ys {
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

    private static func inkCentroidY(
        of bitmap: NSBitmapImageRep,
        xRange: Range<Int>? = nil) throws -> CGFloat
    {
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
