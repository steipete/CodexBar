import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

struct ShareStatsAppearanceTests {
    @Test @MainActor
    func `export uses the active appearance on neutral surfaces`() throws {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        defer { app.appearance = originalAppearance }
        let payload = ShareStatsPayload(
            days: 30,
            periodEnd: Date(timeIntervalSince1970: 1_793_000_000),
            providers: [.init(
                provider: .claude,
                providerName: "Claude",
                subscriptionName: "Synthetic plan",
                currencyCode: "USD",
                totalTokens: 100,
                estimatedCost: 10,
                coveredDayCount: 30)],
            topModels: [.init(
                provider: .claude,
                providerName: "Claude",
                modelName: "Example model",
                currencyCode: "USD",
                totalTokens: 100,
                estimatedCost: 10)],
            currencies: [.init(currencyCode: "USD", estimatedCost: 10, coveredDayCount: 30)],
            totalTokens: 100)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            app.appearance = try #require(NSAppearance(named: appearance))
            let data = try #require(ShareStatsRenderer.pngData(for: payload))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let corner = try #require(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
            #expect(bitmap.pixelsWide == 1200 && bitmap.pixelsHigh == 630)
            if name == "light" {
                #expect(corner.redComponent > 0.95 && corner.greenComponent > 0.95 && corner.blueComponent > 0.95)
            } else {
                #expect(corner.redComponent < 0.15)
                #expect(abs(corner.redComponent - corner.blueComponent) < 0.01)
            }
            if let directory = ProcessInfo.processInfo.environment["CODEXBAR_SHARE_APPEARANCE_PROOF_DIR"] {
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("share-\(name).png"))
            }
        }
    }

    /// WCAG relative luminance of an sRGB colour.
    private static func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let lhs = Self.luminance(lhs)
        let rhs = Self.luminance(rhs)
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }

    @Test @MainActor
    func `light export identifies every row with a legible provider mark`() throws {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        defer { app.appearance = originalAppearance }
        app.appearance = try #require(NSAppearance(named: .aqua))
        let providers: [ShareStatsProviderPayload] = [
            .init(
                provider: .codex,
                providerName: "Codex",
                subscriptionName: "Synthetic plan",
                currencyCode: "USD",
                totalTokens: 300,
                estimatedCost: 30,
                coveredDayCount: 30),
            .init(
                provider: .gemini,
                providerName: "Gemini",
                subscriptionName: nil,
                currencyCode: "USD",
                totalTokens: 200,
                estimatedCost: 20,
                coveredDayCount: 30),
            .init(
                provider: .cursor,
                providerName: "Cursor",
                subscriptionName: nil,
                currencyCode: "USD",
                totalTokens: 100,
                estimatedCost: 10,
                coveredDayCount: 12),
        ]
        let payload = ShareStatsPayload(
            days: 30,
            periodEnd: Date(timeIntervalSince1970: 1_793_000_000),
            providers: providers,
            topModels: providers.map {
                .init(
                    provider: $0.provider,
                    providerName: $0.providerName,
                    modelName: "Example model",
                    currencyCode: "USD",
                    totalTokens: $0.totalTokens,
                    estimatedCost: $0.estimatedCost)
            },
            currencies: [.init(currencyCode: "USD", estimatedCost: 60, coveredDayCount: 30)],
            totalTokens: 600)
        let data = try #require(ShareStatsRenderer.pngData(for: payload))
        let bitmap = try #require(NSBitmapImageRep(data: data))

        func pixel(_ x: Int, _ y: Int) throws -> NSColor {
            try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }

        // The card is a fixed 1200x630 canvas. Each slot is the leading identity cell of a subscription
        // (x 56) or model (x 656) row, left of its rank number; it must carry a mark with at least 3:1
        // non-text contrast against that row's own surface in the light card.
        let slots = [(56, 301), (56, 351), (56, 401), (656, 301), (656, 355), (656, 409)]
        for (originX, centerY) in slots {
            let surface = try pixel(originX + 280, centerY)
            var strongest = 0.0
            for x in originX..<(originX + 17) {
                for y in (centerY - 10)...(centerY + 10) {
                    strongest = try max(strongest, Self.contrast(pixel(x, y), surface))
                }
            }
            #expect(strongest >= 3, "identity slot at (\(originX), \(centerY)) peaks at \(strongest):1")
        }
        if let directory = ProcessInfo.processInfo.environment["CODEXBAR_SHARE_APPEARANCE_PROOF_DIR"] {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("share-identity-light.png"))
        }
    }
}
