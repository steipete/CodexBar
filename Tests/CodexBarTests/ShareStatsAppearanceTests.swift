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
}
