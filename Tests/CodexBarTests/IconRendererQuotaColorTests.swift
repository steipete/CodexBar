import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct IconRendererQuotaColorTests {
    typealias Style = IconRenderer.QuotaColorStyle

    private struct Pixel {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    @Test
    func `thresholds follow the percentage left`() {
        #expect(Style.level(forPercentLeft: 100) == .plenty)
        #expect(Style.level(forPercentLeft: 50) == .plenty)
        #expect(Style.level(forPercentLeft: 49.9) == .low)
        #expect(Style.level(forPercentLeft: 25) == .low)
        #expect(Style.level(forPercentLeft: 24.9) == .critical)
        #expect(Style.level(forPercentLeft: 0) == .critical)
        #expect(Style.level(forPercentLeft: nil) == .unknown)
    }

    @Test
    func `used bar values are converted to the percentage left`() {
        let used = Style(isDarkAppearance: false, valuesAreUsed: true)
        #expect(used.level(forBarValue: 10) == .plenty)
        #expect(used.level(forBarValue: 50) == .plenty)
        #expect(used.level(forBarValue: 60) == .low)
        #expect(used.level(forBarValue: 80) == .critical)
        #expect(used.level(forBarValue: nil) == .unknown)
        let left = Style(isDarkAppearance: false, valuesAreUsed: false)
        #expect(left.level(forBarValue: 10) == .critical)
        #expect(left.level(forBarValue: 80) == .plenty)
    }

    @Test(arguments: [false, true])
    func `every shade meets the provider color contrast threshold`(isDark: Bool) {
        let appearance = isDark ? NSAppearance.Name.darkAqua.rawValue : NSAppearance.Name.aqua.rawValue
        for level in [Style.Level.plenty, .low, .critical, .unknown] {
            #expect(MenuBarLayoutRenderer.meetsAppearanceContrast(
                accent: Style.components(for: level, isDarkAppearance: isDark),
                appearanceName: appearance))
        }
    }

    @Test
    func `quota colors use the provider color fallbacks`() {
        func style(
            _ options: MenuBarLayoutRenderOptions = Self.options(),
            increasedContrast: Bool = false,
            isLoading: Bool = false) -> Style?
        {
            IconRenderer.effectiveQuotaColorStyle(
                options: options,
                increasedContrast: increasedContrast,
                isLoading: isLoading)
        }

        #expect(style() == Style(isDarkAppearance: false, valuesAreUsed: false))
        #expect(style(Self.options(appearance: NSAppearance.Name.darkAqua.rawValue))?.isDarkAppearance == true)
        #expect(style(Self.options(appearance: NSAppearance.Name.vibrantDark.rawValue))?.isDarkAppearance == true)
        #expect(style(Self.options(appearance: NSAppearance.Name.vibrantLight.rawValue))?.isDarkAppearance == false)
        #expect(style(Self.options(showUsed: true))?.valuesAreUsed == true)
        #expect(style(Self.options(isHighlighted: true)) == nil)
        #expect(style(Self.options(isStale: true)) == nil)
        #expect(style(Self.options(highContrast: true)) == nil)
        #expect(style(increasedContrast: true) == nil)
        #expect(style(isLoading: true) == nil)
        #expect(style(Self.options(appearance: NSAppearance.Name.accessibilityHighContrastDarkAqua.rawValue)) == nil)
        #expect(style(Self.options(appearance: NSAppearance.Name.accessibilityHighContrastAqua.rawValue)) == nil)
        #expect(style(Self.options(appearance: "UnknownAppearance")) == nil)
    }

    @Test
    func `signature distinguishes appearance and used mode`() {
        let signatures = Set([false, true].flatMap { dark in
            [false, true].map { used in Style(isDarkAppearance: dark, valuesAreUsed: used).signature }
        })
        #expect(signatures.count == 4)
    }

    @Test
    func `default meter icon stays a monochrome template and is cached separately`() {
        let lightColors = Style(isDarkAppearance: false, valuesAreUsed: false)
        let plain = Self.icon(primary: 80, weekly: 30, quotaColors: nil)
        let colored = Self.icon(primary: 80, weekly: 30, quotaColors: lightColors)
        let plainAgain = Self.icon(primary: 80, weekly: 30, quotaColors: nil)
        #expect(plain.isTemplate)
        #expect(!colored.isTemplate)
        #expect(plainAgain.isTemplate)
    }

    @Test(arguments: [false, true])
    func `quota colors draw each bar in its threshold shade`(isDark: Bool) throws {
        let style = Style(isDarkAppearance: isDark, valuesAreUsed: false)
        let greenOverOrange = Self.icon(primary: 100, weekly: 30, quotaColors: style)
        let redOverOrange = Self.icon(primary: 10, weekly: 30, quotaColors: style)

        // Top lane: x=18 is mid-bar; row 10 from the top is mid-height. Bottom lane: x=6 lies inside a 30% fill.
        // A 10% top fill covers x=3...5, so x=4 is inside it.
        let green = try Self.pixel(greenOverOrange, x: 18, yFromTop: 10)
        let orange = try Self.pixel(greenOverOrange, x: 6, yFromTop: 26)
        let red = try Self.pixel(redOverOrange, x: 4, yFromTop: 10)

        #expect(green.alpha > 0.95 && green.green > green.red && green.green > green.blue)
        #expect(orange.alpha > 0.95 && orange.red > orange.green && orange.green > orange.blue)
        #expect(red.alpha > 0.95 && red.red > red.green && red.red > red.blue)
    }

    @Test
    func `dark appearance uses brighter shades than light appearance`() throws {
        let light = try Self.pixel(
            Self.icon(primary: 100, weekly: 100, quotaColors: Style(isDarkAppearance: false, valuesAreUsed: false)),
            x: 18,
            yFromTop: 10)
        let dark = try Self.pixel(
            Self.icon(primary: 100, weekly: 100, quotaColors: Style(isDarkAppearance: true, valuesAreUsed: false)),
            x: 18,
            yFromTop: 10)
        #expect(dark.green > light.green)
    }

    /// Developer proof for PRs, skipped by default:
    ///   CODEXBAR_QUOTA_COLOR_PROOF_DIR=.github/pr-proof swift test --filter IconRendererQuotaColorTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_QUOTA_COLOR_PROOF_DIR"] != nil))
    func `render quota color proof`() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["CODEXBAR_QUOTA_COLOR_PROOF_DIR"])
        let cases: [(session: Double, weekly: Double)] = [(90, 70), (60, 40), (35, 15), (10, 55)]
        let rows: [(label: String, dark: Bool, colored: Bool)] = [
            ("Light, default", false, false),
            ("Light, quota colors", false, true),
            ("Dark, default", true, false),
            ("Dark, quota colors", true, true),
        ]
        let labelWidth: CGFloat = 170
        let cellWidth: CGFloat = 190
        let headerHeight: CGFloat = 54
        let rowHeight: CGFloat = 104
        let iconSide: CGFloat = 18 * 4
        let size = NSSize(
            width: labelWidth + cellWidth * CGFloat(cases.count),
            height: headerHeight + rowHeight * CGFloat(rows.count))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = context
        context.imageInterpolation = .none

        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        for (column, value) in cases.enumerated() {
            ("Session \(Int(value.session))% left\nWeek \(Int(value.weekly))% left" as NSString).draw(
                in: NSRect(
                    x: labelWidth + CGFloat(column) * cellWidth,
                    y: size.height - headerHeight + 6,
                    width: cellWidth,
                    height: headerHeight - 10),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: centered,
                ])
        }
        for (index, row) in rows.enumerated() {
            let y = size.height - headerHeight - CGFloat(index + 1) * rowHeight
            NSColor(white: row.dark ? 0.16 : 0.92, alpha: 1).setFill()
            NSRect(x: 0, y: y, width: size.width, height: rowHeight).fill()
            let textColor = NSColor(white: row.dark ? 0.92 : 0.12, alpha: 1)
            (row.label as NSString).draw(
                at: NSPoint(x: 14, y: y + rowHeight / 2 - 10),
                withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: textColor])
            for (column, value) in cases.enumerated() {
                let style = row.colored ? Style(isDarkAppearance: row.dark, valuesAreUsed: false) : nil
                var icon = Self.icon(primary: value.session, weekly: value.weekly, quotaColors: style, critters: true)
                if icon.isTemplate {
                    icon = Self.tinted(icon, with: textColor)
                }
                icon.draw(in: NSRect(
                    x: labelWidth + CGFloat(column) * cellWidth + (cellWidth - iconSide) / 2,
                    y: y + (rowHeight - iconSide) / 2,
                    width: iconSide,
                    height: iconSide))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("menu-bar-quota-colors.png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
        print("Wrote \(url.path)")
    }

    private static func icon(
        primary: Double,
        weekly: Double,
        quotaColors: Style?,
        critters: Bool = false) -> NSImage
    {
        IconRenderer.makeIcon(
            primaryRemaining: primary,
            weeklyRemaining: weekly,
            creditsRemaining: nil,
            stale: false,
            style: .claude,
            hideCritters: !critters,
            quotaLayoutPolicy: .provider(.claude),
            quotaColors: quotaColors)
    }

    private static func options(
        appearance: String = NSAppearance.Name.aqua.rawValue,
        isHighlighted: Bool = false,
        isStale: Bool = false,
        highContrast: Bool = false,
        showUsed: Bool = false) -> MenuBarLayoutRenderOptions
    {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: highContrast,
            showUsed: showUsed,
            conditionals: [],
            appearanceName: appearance,
            isDebugApp: false,
            isStale: isStale,
            isHighlighted: isHighlighted,
            now: Date(timeIntervalSince1970: 0))
    }

    private static func pixel(_ image: NSImage, x: Int, yFromTop: Int) throws -> Pixel {
        let rep = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        let color = try #require(rep.colorAt(x: x, y: yFromTop)?.usingColorSpace(.sRGB))
        return Pixel(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent)
    }

    private static func tinted(_ template: NSImage, with color: NSColor) -> NSImage {
        let image = NSImage(size: template.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: template.size)
        template.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
