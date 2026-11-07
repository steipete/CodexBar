import AppKit
import SwiftUI
import Testing
import WidgetKit
@testable import CodexBarWidget

@MainActor
struct WidgetLowQuotaInkTests {
    @Test
    func `low quota bars reach the pixels through both headline and detail rows`() throws {
        for mode in [WidgetRenderingMode.fullColor, .accented, .vibrant] {
            let lane = QuotaLaneView(title: "Weekly", percent: 92, remainingPercent: 8, color: .blue)
            let hero = HeroBlock(value: "92%", caption: Text("Weekly used"), barPercent: 92, isLow: true, color: .blue)
            for (name, view) in [("lane", AnyView(lane)), ("hero", AnyView(hero))] {
                let image = try Self.render(view, mode: mode)
                let color = try Self.barColor(image)
                if mode == .fullColor {
                    #expect(color.redComponent > 0.8 && color.greenComponent < 0.4 && color.blueComponent < 0.4)
                } else {
                    #expect(color.redComponent < 0.3 && color.greenComponent < 0.3 && color.blueComponent < 0.3)
                }
                if let directory = ProcessInfo.processInfo.environment["CODEXBAR_WIDGET_INK_PROOF_DIR"] {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(mode).png"))
                }
            }
        }
    }

    @Test
    func `healthy quota bars retain the provider color`() throws {
        let image = try Self.render(
            QuotaLaneView(title: "Weekly", percent: 50, remainingPercent: 50, color: .blue), mode: .fullColor)
        let color = try Self.barColor(image)
        #expect(color.blueComponent > 0.7 && color.redComponent < 0.2)
    }

    private static func render(_ view: some View, mode: WidgetRenderingMode) throws -> CGImage {
        let renderer = ImageRenderer(content: view
            .environment(\.widgetRenderingModeOverride, mode)
            .environment(\.colorScheme, .light)
            .frame(width: 160)
            .background(Color.white))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    private static func barColor(_ image: CGImage) throws -> NSColor {
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Both production seams place the bar last; sample inside its fill, clear of rounded caps.
        let color = try #require(bitmap.colorAt(x: image.width / 4, y: image.height - 7))
        return try #require(color.usingColorSpace(.sRGB))
    }
}
