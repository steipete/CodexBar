import AppKit
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
}
