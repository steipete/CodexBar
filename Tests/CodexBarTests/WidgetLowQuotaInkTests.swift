import AppKit
import CodexBarCore
import SwiftUI
import Testing
import Vision
import WidgetKit
@testable import CodexBarWidget

/// Rendered, not helper-level: a low limit only counts as a warning if it reaches the pixels.
@MainActor
struct WidgetLowQuotaInkTests {
    /// The installed scenario: nothing about the headline is low, so the model-scoped Sonnet row is
    /// the tile's only warning. Model-scoped rows cannot become the headline.
    private static func claudeEntry() -> WidgetSnapshot.ProviderEntry {
        let now = Date()
        return WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: now.addingTimeInterval(-60),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "primary",
                    title: "Session",
                    percentLeft: 39,
                    window: RateWindow(
                        usedPercent: 61,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3 * 60 * 60),
                        resetDescription: nil)),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "secondary", title: "Weekly", percentLeft: 70),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "claude-weekly-scoped-sonnet",
                    title: "Sonnet",
                    percentLeft: 8),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
    }

    /// `content` is the usable height inside the tile's margins: 127pt on the smallest macOS tile and
    /// 132pt in the installed hosted capture.
    private static func render(tile: some View, content: CGFloat) throws -> CGImage {
        let view = tile
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, .light)
            .frame(width: content, height: content)
            .padding(14)
            .background(Color(white: 0.96))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try #require(renderer.cgImage)
    }

    private static func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    /// Opaque RGB samples, top-left origin.
    private static func pixels(of image: CGImage) throws -> [(r: Double, g: Double, b: Double)] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let srgb = try #require(bitmap.converting(to: .sRGB, renderingIntent: .default))
        var samples: [(r: Double, g: Double, b: Double)] = []
        samples.reserveCapacity(srgb.pixelsWide * srgb.pixelsHigh)
        for y in 0..<srgb.pixelsHigh {
            for x in 0..<srgb.pixelsWide {
                guard let color = srgb.colorAt(x: x, y: y) else { continue }
                samples.append((color.redComponent, color.greenComponent, color.blueComponent))
            }
        }
        return samples
    }

    private static func redPixelCount(in image: CGImage) throws -> Int {
        try self.pixels(of: image).count(where: { $0.r > 0.6 && $0.g < 0.45 && $0.b < 0.45 })
    }

    private static func expectWarningVisible(_ image: CGImage) throws {
        // The only red on this tile is the low Sonnet figure. Pixels need no text recognition, so this
        // holds on hosts without Vision, where the text checks below cannot run.
        #expect(try self.redPixelCount(in: image) > 20)
        guard VisionTextRecognition.isAvailable else { return }
        let text = try self.recognizedText(in: image)
        let compact = text.replacingOccurrences(of: " ", with: "")
        #expect(compact.contains("39%"), "Headline missing: \(text)")
        #expect(compact.contains("Weekly"), "Weekly row missing: \(text)")
        #expect(compact.contains("70%"), "Weekly value missing: \(text)")
        #expect(compact.contains("Sonnet"), "Sonnet row missing: \(text)")
        #expect(compact.contains("8%"), "Sonnet value missing: \(text)")
        #expect(!compact.contains("more"), "Rows folded into overflow: \(text)")
    }

    @Test(arguments: [CGFloat(127), 132])
    func `small switcher keeps a low model quota out of overflow`(content: CGFloat) throws {
        try WidgetLocalizationOverride.$language.withValue("en") {
            let entry = Self.claudeEntry()
            let tile = UsageTile(entry: entry, size: .small) {
                ProviderPagerHeader(
                    providers: [.codex, .claude, .kimi, .zai],
                    selected: .claude,
                    updatedAt: entry.updatedAt,
                    size: .small)
            }
            .environment(\.widgetProviderSelectionOverride) { _ in }
            try Self.expectWarningVisible(Self.render(tile: tile, content: content))
        }
    }

    @Test(arguments: [CGFloat(127), 132])
    func `small usage widget keeps a low model quota out of overflow`(content: CGFloat) throws {
        try WidgetLocalizationOverride.$language.withValue("en") {
            let entry = Self.claudeEntry()
            let tile = UsageTile(entry: entry, size: .small) {
                TileHeader(provider: entry.provider, updatedAt: entry.updatedAt, size: .small)
            }
            try Self.expectWarningVisible(Self.render(tile: tile, content: content))
        }
    }

    // MARK: - Bar ink

    private static func barImage(isLow: Bool, mode: WidgetRenderingMode) throws -> CGImage {
        let view = QuotaBar(percent: 100, color: WidgetInk.data, isLow: isLow, height: 8)
            .environment(\.widgetRenderingModeOverride, mode)
            .environment(\.colorScheme, .light)
            .frame(width: 60)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    /// The bar's centre pixel, clear of the rounded caps.
    private static func barCentre(_ image: CGImage) throws -> (r: Double, g: Double, b: Double) {
        try self.pixels(of: image)[image.width * (image.height / 2) + image.width / 2]
    }

    @Test
    func `full colour draws a low bar red and a healthy bar in neutral ink`() throws {
        let low = try Self.barCentre(Self.barImage(isLow: true, mode: .fullColor))
        #expect(low.r > 0.8 && low.g < 0.4 && low.b < 0.4)

        let healthy = try Self.barCentre(Self.barImage(isLow: false, mode: .fullColor))
        #expect(abs(healthy.r - healthy.g) < 0.02 && abs(healthy.g - healthy.b) < 0.02)
    }

    @Test
    func `masked modes draw a low bar stronger than a healthy one`() throws {
        // Red reads dimmer than ink through a luminance mask, which would invert the warning.
        for mode in [WidgetRenderingMode.accented, .vibrant] {
            let low = try Self.barCentre(Self.barImage(isLow: true, mode: mode))
            #expect(abs(low.r - low.g) < 0.02 && abs(low.g - low.b) < 0.02)

            let healthy = try Self.barCentre(Self.barImage(isLow: false, mode: mode))
            #expect(low.r < healthy.r - 0.05)
        }
    }
}
