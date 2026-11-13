import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

@MainActor
final class MenuBarBatteryRenderTests: XCTestCase {
    func test_batteryMeterGeometryKeepsCoreVisibleAtMenuBarHeights() {
        for height in [5.0, 6.0, 7.0] {
            let size = CGSize(width: 44, height: height)
            let rects = MenuBarBatteryMeter.rects(size: size)
            XCTAssertGreaterThanOrEqual(rects.inner.height, 2, "core collapses at height \(height)")
            XCTAssertGreaterThanOrEqual(rects.inner.minX, rects.body.minX)
            XCTAssertLessThanOrEqual(rects.inner.maxX, rects.body.maxX)
            XCTAssertLessThanOrEqual(rects.nub.maxX, size.width)
            XCTAssertLessThan(rects.nub.height, rects.body.height)
            XCTAssertLessThan(rects.body.width, size.width)
        }
    }

    func test_batteryMeterFillWidthFollowsRenderedPercent() {
        let size = CGSize(width: 44, height: 6)
        let inner = MenuBarBatteryMeter.rects(size: size).inner
        XCTAssertEqual(MenuBarBatteryMeter.fillWidth(percent: 0, size: size), 0)
        XCTAssertEqual(MenuBarBatteryMeter.fillWidth(percent: 0.4, size: size), 0)
        XCTAssertEqual(MenuBarBatteryMeter.fillWidth(percent: 100, size: size), inner.width)
        XCTAssertEqual(
            MenuBarBatteryMeter.fillWidth(percent: 88, size: size),
            inner.width * 0.88,
            accuracy: 0.001)
    }

    func test_batteryMeterTintFollowsRemainingThresholds() {
        XCTAssertEqual(MenuBarBatteryMeter.tint(remainingPercent: 88), .systemGreen)
        XCTAssertEqual(MenuBarBatteryMeter.tint(remainingPercent: 50), .systemGreen)
        XCTAssertEqual(MenuBarBatteryMeter.tint(remainingPercent: 42), .systemYellow)
        XCTAssertEqual(MenuBarBatteryMeter.tint(remainingPercent: 20), .systemYellow)
        XCTAssertEqual(MenuBarBatteryMeter.tint(remainingPercent: 5), .systemRed)
    }

    func test_batteryMeterImagePixelsUseSeverityColor() throws {
        let size = NSSize(width: 44, height: 6)
        let inner = MenuBarBatteryMeter.rects(size: size).inner
        let sampleX = Int(inner.minX + 1)
        let sampleY = Int(size.height / 2)

        let ample = MenuBarLayoutRenderer.progressBarImage(MenuBarMeterSpec(
            fillPercent: 88,
            size: size,
            tint: .white,
            isStale: false,
            style: .battery,
            remainingPercent: 88))
        let ampleColor = try self.color(in: ample, size: size, x: sampleX, y: sampleY)
        XCTAssertGreaterThan(ampleColor.greenComponent, ampleColor.redComponent)
        XCTAssertGreaterThan(ampleColor.greenComponent, ampleColor.blueComponent)

        let critical = MenuBarLayoutRenderer.progressBarImage(MenuBarMeterSpec(
            fillPercent: 5,
            size: size,
            tint: .white,
            isStale: false,
            style: .battery,
            remainingPercent: 5))
        let criticalColor = try self.color(in: critical, size: size, x: sampleX, y: sampleY)
        XCTAssertGreaterThan(criticalColor.redComponent, criticalColor.greenComponent)
        XCTAssertGreaterThan(criticalColor.redComponent, criticalColor.blueComponent)

        let emptyTail = try self.color(in: ample, size: size, x: Int(inner.maxX - 1), y: sampleY)
        XCTAssertLessThan(emptyTail.alphaComponent, 0.5, "unfilled core must stay track-only")
    }

    func test_capsuleMeterImageKeepsFiveSegmentLayout() throws {
        let size = NSSize(width: 44, height: 6)
        let image = MenuBarLayoutRenderer.progressBarImage(MenuBarMeterSpec(
            fillPercent: 100,
            size: size,
            tint: .systemBlue,
            isStale: false))
        let filled = try self.color(in: image, size: size, x: 1, y: 3)
        XCTAssertGreaterThan(filled.blueComponent, filled.redComponent)
        XCTAssertGreaterThan(filled.alphaComponent, 0.9)
        let gap = try self.color(in: image, size: size, x: 8, y: 3)
        XCTAssertLessThan(gap.alphaComponent, 0.1, "segment gaps must stay transparent")
    }

    func test_usageBarStyleDefaultsToCapsule() {
        XCTAssertEqual(self.options().usageBarStyle, .capsule)
    }

    func test_switchingUsageBarStyleInvalidatesCachedTitle() throws {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.progressBar(window: .session)]])
        let data = self.data(sessionUsedPercent: 25)
        let capsule = renderer.render(
            layout: layout, data: data, icon: nil, options: self.options(usageBarStyle: .capsule))
        let battery = renderer.render(
            layout: layout, data: data, icon: nil, options: self.options(usageBarStyle: .battery))

        let capsuleImage = try self.barImage(in: capsule.attributedTitle)
        let batteryImage = try self.barImage(in: battery.attributedTitle)
        XCTAssertNotEqual(
            try self.bitmap(of: capsuleImage),
            try self.bitmap(of: batteryImage),
            "the title cache must key on the usage bar style")
    }

    func test_batteryTitleBarColorsByRemainingPercent() throws {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.progressBar(window: .session)]])

        let ample = renderer.render(
            layout: layout,
            data: self.data(sessionUsedPercent: 25),
            icon: nil,
            options: self.options(usageBarStyle: .battery, showUsed: false))
        let ampleColor = try self.coreColor(in: self.barImage(in: ample.attributedTitle))
        XCTAssertGreaterThan(ampleColor.greenComponent, ampleColor.redComponent)
        XCTAssertGreaterThan(ampleColor.greenComponent, ampleColor.blueComponent)

        let critical = renderer.render(
            layout: layout,
            data: self.data(sessionUsedPercent: 95),
            icon: nil,
            options: self.options(usageBarStyle: .battery, showUsed: false))
        let criticalColor = try self.coreColor(in: self.barImage(in: critical.attributedTitle))
        XCTAssertGreaterThan(criticalColor.redComponent, criticalColor.greenComponent)
        XCTAssertGreaterThan(criticalColor.redComponent, criticalColor.blueComponent)
    }

    func test_batteryTitleBarStaysMonochromeInHighContrast() throws {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.progressBar(window: .session)]]),
            data: self.data(sessionUsedPercent: 95),
            icon: nil,
            options: self.options(usageBarStyle: .battery, showUsed: false, highContrast: true))
        let color = try self.coreColor(in: self.barImage(in: output.attributedTitle))
        XCTAssertGreaterThan(color.alphaComponent, 0.5)
        XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.02)
        XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.02)
    }

    func test_characterUsageBarTokenIgnoresBatteryStyle() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.usageBar]])
        let data = self.data(sessionUsedPercent: 25)
        let capsule = renderer.render(
            layout: layout, data: data, icon: nil, options: self.options(usageBarStyle: .capsule))
        let battery = renderer.render(
            layout: layout, data: data, icon: nil, options: self.options(usageBarStyle: .battery))
        XCTAssertEqual(capsule.attributedTitle.string, battery.attributedTitle.string)
        XCTAssertEqual(battery.attributedTitle.string, "▮▮▯")
    }

    private func coreColor(in image: NSImage) throws -> NSColor {
        let size = image.size
        let inner = MenuBarBatteryMeter.rects(size: size).inner
        return try self.color(
            in: image,
            size: size,
            x: Int(inner.minX + 1),
            y: Int(size.height / 2))
    }

    private func barImage(in title: NSAttributedString) throws -> NSImage {
        let text = title.string
        let index = try XCTUnwrap(text.firstIndex(of: "\u{FFFC}"))
        let attachment = try XCTUnwrap(title.attribute(
            .attachment,
            at: text.distance(from: text.startIndex, to: index),
            effectiveRange: nil) as? NSTextAttachment)
        return try XCTUnwrap(attachment.image)
    }

    private func data(sessionUsedPercent: Double) -> MenuBarLayoutRenderData {
        MenuBarLayoutRenderData(
            provider: .codex,
            iconKey: "codex",
            providerName: "Codex",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .codex, snapshot: nil),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            session: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: sessionUsedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil)),
            weekly: nil,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil)),
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
    }

    private func options(
        usageBarStyle: UsageBarStyle = .capsule,
        showUsed: Bool = true,
        highContrast: Bool = false) -> MenuBarLayoutRenderOptions
    {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: highContrast,
            showUsed: showUsed,
            conditionals: [],
            appearanceName: "aqua",
            isDebugApp: false,
            now: Date(timeIntervalSince1970: 1_752_768_000),
            usageBarStyle: usageBarStyle)
    }

    private func bitmap(of image: NSImage) throws -> Data {
        let rep = try self.renderedRep(of: image)
        let bytes = try XCTUnwrap(rep.bitmapData)
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    private func color(in image: NSImage, size: NSSize, x: Int, y: Int) throws -> NSColor {
        let rep = try self.renderedRep(of: image, size: size)
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y))
        return color.usingColorSpace(.deviceRGB) ?? color
    }

    private func renderedRep(of image: NSImage, size: NSSize? = nil) throws -> NSBitmapImageRep {
        let drawSize = size ?? image.size
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(drawSize.width),
            pixelsHigh: Int(drawSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: drawSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
