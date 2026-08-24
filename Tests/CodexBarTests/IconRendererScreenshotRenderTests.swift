import AppKit
import CodexBarCore
import XCTest
@testable import CodexBar

/// Developer tool, skipped by default: renders a synthetic single-quota icon for PR proof.
///
/// Run with:
///   CODEXBAR_ICON_SCREENSHOT_DIR=docs/screenshots \
///     swift test --filter IconRendererScreenshotRenderTests
@MainActor
final class IconRendererScreenshotRenderTests: XCTestCase {
    private static let canvasSize = NSSize(width: 360, height: 240)

    func test_renderSyntheticMergedWarpTransition() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_WARP_ICON_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_WARP_ICON_PROOF_DIR to render the merged Warp proof.")
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func icon(usedBonus: Double) -> NSImage {
            let snapshot = UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: usedBonus,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date())
            let percents = IconRemainingResolver.resolvedPercents(snapshot: snapshot, style: .warp, showUsed: true)
            return IconRenderer.makeIcon(
                primaryRemaining: percents.primary,
                weeklyRemaining: percents.secondary,
                creditsRemaining: nil,
                stale: false,
                style: .combined,
                quotaLayoutPolicy: .provider(.warp))
        }

        let data = try XCTUnwrap(
            Self.warpTransitionProofPNG(exhausted: icon(usedBonus: 100), unused: icon(usedBonus: 0)),
            "merged Warp proof render failed")
        let url = directory.appendingPathComponent("merged-warp-bonus-transition.png")
        try data.write(to: url, options: .atomic)
        print("Wrote \(url.path)")
    }

    func test_renderSyntheticSingleQuotaIcon() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_ICON_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ICON_SCREENSHOT_DIR to render the synthetic icon proof.")
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let icon = IconRenderer.makeIcon(
            primaryRemaining: 46,
            weeklyRemaining: nil,
            creditsRemaining: nil,
            stale: false,
            style: .combined,
            hideCritters: true,
            quotaLayoutPolicy: .provider(.codex))
        let data = try XCTUnwrap(Self.proofPNG(icon: icon), "synthetic icon proof render failed")
        let url = directory.appendingPathComponent("codex-single-quota-icon.png")
        try data.write(to: url, options: .atomic)
        print("Wrote \(url.lastPathComponent)")
    }

    private static func proofPNG(icon: NSImage) -> Data? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width),
            pixelsHigh: Int(canvasSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        representation.size = Self.canvasSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: Self.canvasSize).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .regular),
            .foregroundColor: NSColor(white: 0.72, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        NSString(string: "Synthetic proof").draw(
            in: NSRect(x: 24, y: 192, width: 312, height: 36),
            withAttributes: titleAttributes)
        NSString(string: "46% remaining").draw(
            in: NSRect(x: 24, y: 158, width: 312, height: 32),
            withAttributes: subtitleAttributes)

        context.imageInterpolation = .none
        icon.isTemplate = false
        icon.draw(
            in: NSRect(x: 108, y: 20, width: 144, height: 144),
            from: NSRect(origin: .zero, size: icon.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [.interlaced: false])
    }

    private static func warpTransitionProofPNG(exhausted: NSImage, unused: NSImage) -> Data? {
        let size = NSSize(width: 720, height: 300)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        representation.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let title: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: centered,
        ]
        let label: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 19, weight: .medium),
            .foregroundColor: NSColor(white: 0.82, alpha: 1),
            .paragraphStyle: centered,
        ]
        let detail: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor(white: 0.62, alpha: 1),
            .paragraphStyle: centered,
        ]
        NSString(string: "Synthetic merged Warp runtime proof").draw(
            in: NSRect(x: 20, y: 258, width: 680, height: 32),
            withAttributes: title)

        let panels: [(NSImage, String, String, CGFloat)] = [
            (exhausted, "Exhausted bonus", "secondary = 0.000 · dimmed missing lane", 30),
            (unused, "Unused bonus", "secondary = 0.100 · empty present lane", 370),
        ]
        for (image, heading, subtitle, x) in panels {
            NSString(string: heading).draw(
                in: NSRect(x: x, y: 220, width: 320, height: 26),
                withAttributes: label)
            NSString(string: subtitle).draw(
                in: NSRect(x: x, y: 194, width: 320, height: 22),
                withAttributes: detail)
            context.imageInterpolation = .none
            image.isTemplate = false
            image.draw(
                in: NSRect(x: x + 80, y: 20, width: 160, height: 160),
                from: NSRect(origin: .zero, size: image.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [.interlaced: false])
    }
}
