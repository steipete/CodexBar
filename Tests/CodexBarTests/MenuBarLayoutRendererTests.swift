import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarLayoutRendererTests {
    private let now = Date(timeIntervalSince1970: 1_752_768_000)

    @Test
    func `renderer composes every token with live values`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let data = self.data()
        let expected: [(MenuBarLayoutToken, String)] = [
            (.providerName, "Codex"),
            (.accountLabel, "user@example.com"),
            (.percent(window: .session), "5h 25%"),
            (.percent(window: .weekly), "W 60%"),
            (.percent(window: .automatic), "50%"),
            (.usageBar, "▮▮▯"),
            (.resetCountdown, "in 2h"),
            (.runsOut, "Runs out tomorrow"),
            (.costToday, "$1.25"),
            (.cost30d, "$20.00"),
            (.separatorDot, "·"),
            (.space, " "),
        ]

        for (token, value) in expected {
            let output = renderer.render(
                layout: MenuBarLayout(lines: [[token]]),
                data: data,
                icon: icon,
                options: self.options())
            #expect(output.attributedTitle.string == value)
        }

        let iconOutput = renderer.render(
            layout: MenuBarLayout(lines: [[.icon]]),
            data: data,
            icon: icon,
            options: self.options())
        #expect(iconOutput.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)

        let absoluteOutput = renderer.render(
            layout: MenuBarLayout(lines: [[.resetAbsolute]]),
            data: data,
            icon: icon,
            options: self.options())
        #expect(absoluteOutput.attributedTitle.string != "–")
    }

    @Test
    func `icon attachment matches the default template size and appearance`() throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
        icon.unlockFocus()
        icon.isTemplate = true

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.icon]]),
            data: self.data(),
            icon: icon,
            options: self.options())
        let attachment = try #require(
            output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let attachmentImage = try #require(attachment.image)

        #expect(attachment.bounds.size == NSSize(width: 16, height: 16))
        #expect(attachmentImage.isTemplate)
        #expect(try self.averageBrightness(of: output.attributedTitle, appearance: .aqua) < 0.25)
        #expect(try self.averageBrightness(of: output.attributedTitle, appearance: .darkAqua) > 0.75)
    }

    @Test
    func `missing token data keeps every sibling visible as a placeholder`() {
        let renderer = MenuBarLayoutRenderer()
        let missingData = MenuBarLayoutRenderData(
            iconKey: "missing",
            providerName: nil,
            accountLabel: nil,
            session: nil,
            weekly: nil,
            automatic: nil,
            runsOut: nil,
            costToday: nil,
            cost30d: nil)
        let layout = MenuBarLayout(lines: [[
            .icon,
            .providerName,
            .accountLabel,
            .percent(window: .session),
            .percent(window: .weekly),
            .percent(window: .automatic),
            .usageBar,
            .resetCountdown,
            .resetAbsolute,
            .runsOut,
            .costToday,
            .cost30d,
        ]])

        let output = renderer.render(layout: layout, data: missingData, icon: nil, options: self.options())

        #expect(output.attributedTitle.string.count(where: { $0 == "–" }) == 12)
        #expect(output.accessibilityLabel.contains("unavailable"))
    }

    @Test
    func `two line title stays within menu bar height`() throws {
        let renderer = MenuBarLayoutRenderer()
        let output = try renderer.render(
            layout: #require(MenuBarLayoutPreset.compactStacked.layout),
            data: self.data(),
            icon: nil,
            options: self.options())
        let bounds = output.attributedTitle.boundingRect(
            with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        #expect(output.attributedTitle.string == "5h 25%\nW 60%")
        #expect(output.accessibilityLabel.contains(L("menu_bar_layout_line", 2)))
        #expect(bounds.height <= 22)
    }

    @Test
    func `two line icon uses compact paragraph metrics`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let output = renderer.render(
            layout: MenuBarLayout(lines: [
                [.icon, .percent(window: .session)],
                [.percent(window: .weekly)],
            ]),
            data: self.data(),
            icon: icon,
            options: self.options())
        let bounds = output.attributedTitle.boundingRect(
            with: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        #expect(output.attributedTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) is NSParagraphStyle)
        #expect(bounds.height <= 22)
    }

    @Test
    func `cached path renders one thousand titles under budget`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic), .separatorDot, .resetCountdown]])
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let first = renderer.render(layout: layout, data: self.data(), icon: icon, options: self.options())
        var last = first
        var fastest = Duration.seconds(10)

        // Best-of-three keeps the frozen 50 ms budget while ignoring one-off CI preemption.
        for _ in 0..<3 {
            let startedAt = ContinuousClock.now
            for _ in 0..<1000 {
                last = renderer.render(layout: layout, data: self.data(), icon: icon, options: self.options())
            }
            fastest = min(fastest, ContinuousClock.now - startedAt)
        }

        #expect(first.attributedTitle === last.attributedTitle)
        #expect(fastest < .milliseconds(50), "Fastest cached batch took \(fastest)")
    }

    @Test
    func `usage bar follows remaining display direction`() {
        let renderer = MenuBarLayoutRenderer()
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.usageBar]]),
            data: self.data(automaticUsedPercent: 10),
            icon: nil,
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: false,
                appearanceName: "aqua",
                isDebugApp: false,
                now: self.now))

        #expect(output.attributedTitle.string == "▮▮▮")
    }

    @Test
    func `absolute reset falls back to provider text`() {
        let renderer = MenuBarLayoutRenderer()
        let textOnlyWindow = MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: 20,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "Friday at 10:00"))
        let data = MenuBarLayoutRenderData(
            iconKey: "codex",
            providerName: "Codex",
            accountLabel: nil,
            session: nil,
            weekly: nil,
            automatic: textOnlyWindow,
            runsOut: nil,
            costToday: nil,
            cost30d: nil)

        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.resetAbsolute]]),
            data: data,
            icon: nil,
            options: self.options())

        #expect(output.attributedTitle.string == "Friday at 10:00")
    }

    @Test
    func `high contrast title keeps icon and text in one attributed path`() {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        var options = self.options()
        options = MenuBarLayoutRenderOptions(
            size: options.size,
            highContrast: true,
            showUsed: options.showUsed,
            appearanceName: options.appearanceName,
            isDebugApp: options.isDebugApp,
            now: options.now)
        let output = renderer.render(
            layout: MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]),
            data: self.data(),
            icon: icon,
            options: options)

        #expect(output.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        let textIndex = (output.attributedTitle.string as NSString).range(of: "50%").location
        #expect(output.attributedTitle
            .attribute(.foregroundColor, at: textIndex, effectiveRange: nil) as? NSColor == .labelColor)
    }

    private func data(automaticUsedPercent: Double = 50) -> MenuBarLayoutRenderData {
        MenuBarLayoutRenderData(
            iconKey: "codex",
            providerName: "Codex",
            accountLabel: "user@example.com",
            session: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(60 * 60),
                resetDescription: nil)),
            weekly: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil)),
            automatic: MenuBarLayoutRenderWindow(RateWindow(
                usedPercent: automaticUsedPercent,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil)),
            runsOut: "Runs out tomorrow",
            costToday: "$1.25",
            cost30d: "$20.00")
    }

    private func options() -> MenuBarLayoutRenderOptions {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: false,
            showUsed: true,
            appearanceName: "aqua",
            isDebugApp: false,
            now: self.now)
    }

    private func averageBrightness(
        of title: NSAttributedString,
        appearance: NSAppearance.Name) throws
        -> CGFloat
    {
        let canvas = NSImage(size: NSSize(width: 24, height: 24))
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            canvas.lockFocus()
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: canvas.size).fill()
            title.draw(at: NSPoint(x: 4, y: 4))
            canvas.unlockFocus()
        }

        let data = try #require(canvas.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var totalBrightness: CGFloat = 0
        var visiblePixelCount = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                totalBrightness += color.brightnessComponent
                visiblePixelCount += 1
            }
        }
        return try totalBrightness / CGFloat(#require(visiblePixelCount > 0 ? visiblePixelCount : nil))
    }
}
