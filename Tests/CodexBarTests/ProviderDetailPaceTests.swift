import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct ProviderDetailPaceTests {
    @MainActor
    @Test
    func `show pace preference hides the tip without removing progress`() throws {
        let progress = try ProviderDetailSection.Row.Progress(used: 0.6, total: 1, expectedUsed: 0.3)
        let hidden = try Self.tipPixels(progress: progress, paceVisible: false)
        #expect(hidden.red == 0 && hidden.green == 0, "Show pace off must hide the supplied tip")
        #expect(hidden.blue > 100, "Ordinary progress remains visible")
    }

    @MainActor
    @Test
    func `pace survives provider localization`() throws {
        let row = try ProviderDetailSection.Row(
            label: "Weekly", value: "60%", progress: .init(used: 0.6, total: 1, expectedUsed: 0.5))
        let section = try ProviderDetailSection(rows: [row])
        for provider in [UsageProvider.synthetic, .deepseek] {
            let localized = UsageMenuCardView.Model.localizedProviderDetails([section], provider: provider)
            #expect(localized.first?.rows.first?.progress?.expectedUsedPercent == 50)
        }
    }

    @MainActor
    @Test
    func `detail bars draw the native pace tip only when pace is known`() throws {
        let ahead = try Self.tipPixels(progress: .init(used: 0.6, total: 1, expectedUsed: 0.3))
        let behind = try Self.tipPixels(progress: .init(used: 0.3, total: 1, expectedUsed: 0.6))
        let unpaced = try Self.tipPixels(progress: .init(used: 0.6, total: 1))
        // A 2pt stripe across the 6pt bar covers dozens of pixels at 2x; the blue fill and gray track cover none.
        #expect(ahead.red > 20 && ahead.green == 0, "Usage ahead of pace draws a red tip: \(ahead)")
        #expect(behind.green > 20 && behind.red == 0, "Usage under pace draws a green tip: \(behind)")
        #expect(unpaced.red == 0 && unpaced.green == 0, "Rows without pace draw no tip: \(unpaced)")
    }

    @MainActor
    @Test
    func `row severity does not change consumed pace`() throws {
        let below = try ProviderDetailSection.Row.Progress(used: 0.3, total: 1, expectedUsed: 0.6)
        let above = try ProviderDetailSection.Row.Progress(used: 0.6, total: 1, expectedUsed: 0.3)

        // Severity thresholds can disagree with pace; the tip still compares consumed usage.
        let criticalBelow = try Self.tipPixels(progress: below, severity: .critical)
        #expect(criticalBelow.green > 20, "Usage below pace keeps a green tip on a critical row: \(criticalBelow)")
        let normalAbove = try Self.tipPixels(progress: above, severity: .normal)
        #expect(normalAbove.red > 20, "Usage ahead of pace keeps a red tip on a normal row: \(normalAbove)")
    }

    @MainActor
    private static func tipPixels(
        progress: ProviderDetailSection.Row.Progress,
        severity: ProviderDetailSection.Row.Severity? = nil,
        paceVisible: Bool = true) throws -> (red: Int, green: Int, blue: Int)
    {
        let row = try ProviderDetailSection.Row(
            label: "Weekly", value: "—", progress: progress, severity: severity)
        let section = try ProviderDetailSection(rows: [row])
        let renderer = ImageRenderer(content: ProviderDetailSectionsContent(
            sections: [section], chartColor: .blue, paceVisible: paceVisible)
            .frame(width: 280).padding(12).background(.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var red = 0
        var green = 0
        var blue = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else {
                    continue
                }
                if color.redComponent > 0.65, color.greenComponent < 0.35, color.blueComponent < 0.35 { red += 1 }
                if color.greenComponent > 0.45, color.redComponent < 0.5, color.blueComponent < 0.5 { green += 1 }
                if color.blueComponent > color.redComponent + 0.2,
                   color.blueComponent > color.greenComponent + 0.1 { blue += 1 }
            }
        }
        return (red, green, blue)
    }
}
