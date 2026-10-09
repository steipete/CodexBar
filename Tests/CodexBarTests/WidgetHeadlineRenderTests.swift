import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBarWidget

@MainActor
struct WidgetHeadlineRenderTests {
    @Test(arguments: [WidgetTileSize.small, .medium, .large])
    func `quota headlines fit every widget family`(size: WidgetTileSize) throws {
        let dimensions = CGSize(width: size == .small ? 155 : 329, height: size == .large ? 345 : 155)
        let now = Date()
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: now.addingTimeInterval(-310),
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 7,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: nil),
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        for language in ["en", "de", "ar"] {
            try WidgetLocalizationOverride.$language.withValue(language) {
                let view = UsageTile(entry: entry, size: size) {
                    TileHeader(provider: entry.provider, updatedAt: entry.updatedAt, size: size)
                }
                .environment(\.locale, Locale(identifier: language))
                .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
                .environment(\.colorScheme, .light)
                .frame(width: dimensions.width - 28, height: dimensions.height - 28)
                .padding(14)
                .background(Color(white: 0.96))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int(dimensions.width * 2))
                #expect(image.height == Int(dimensions.height * 2))
                if let path = ProcessInfo.processInfo.environment["CODEXBAR_WIDGET_HEADLINE_PROOF_DIR"] {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: path)
                        .appendingPathComponent("\(language)-\(size).png"))
                }
            }
        }
    }
}
