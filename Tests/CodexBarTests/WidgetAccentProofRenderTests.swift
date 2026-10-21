import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBarWidget

@MainActor
struct WidgetAccentProofRenderTests {
    @Test
    func `renders a synthetic cursor usage tile`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_WIDGET_PROOF_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .cursor,
            updatedAt: now,
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 70,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let view = UsageTile(entry: entry, size: .medium) {
                TileHeader(provider: entry.provider, updatedAt: entry.updatedAt, size: .medium)
            }
            .environment(\.colorScheme, scheme)
            .padding(12)
            .frame(width: 329, height: 155, alignment: .topLeading)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = scheme == .dark ? "cursor-usage-dark.png" : "cursor-usage-light.png"
            try png.write(to: output.appendingPathComponent(name))
            for language in ["de", "fr", "es", "zh-Hans", "ja", "ar"] {
                try WidgetLocalizationOverride.$language.withValue(language) {
                    let direction: LayoutDirection = Locale.Language(identifier: language).characterDirection ==
                        .rightToLeft ? .rightToLeft : .leftToRight
                    let localized = ImageRenderer(content: view
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.layoutDirection, direction))
                    localized.scale = 2
                    let bitmap = try NSBitmapImageRep(cgImage: #require(localized.cgImage))
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: output.appendingPathComponent("\(language)-\(name)"))
                }
            }
        }
    }
}
