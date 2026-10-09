import AppKit
import CodexBarCore
import SwiftUI
import Testing
import Vision
@testable import CodexBarWidget

@MainActor
struct WidgetHeadlineLocalizationTests {
    @Test(arguments: [false, true])
    func `inline quota title keeps its localized name percentage and direction`(hasSecondaryLane: Bool) throws {
        try WidgetLocalizationOverride.$language.withValue("de") {
            let entry = WidgetSnapshot.ProviderEntry(
                provider: .codex,
                updatedAt: Date(),
                primary: hasSecondaryLane ? RateWindow(
                    usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil) : nil,
                secondary: RateWindow(
                    usedPercent: 7,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                tertiary: nil,
                creditsRemaining: nil,
                codeReviewRemainingPercent: nil,
                tokenUsage: nil,
                dailyUsage: [])
            let view = UsageTile(entry: entry, size: .medium) {
                TileHeader(provider: entry.provider, updatedAt: entry.updatedAt, size: .medium)
            }
            .environment(\.locale, Locale(identifier: "de"))
            .environment(\.colorScheme, .light)
            .frame(width: 301, height: 127)
            .padding(14)
            .background(Color(white: 0.96))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try #require(renderer.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            #expect(text.contains(W("Weekly")))
            #expect(!text.contains("Weekly"))
            #expect(text.replacingOccurrences(of: " ", with: "").contains("93%"))
            #expect(text.contains("übrig"), "Rendered headline: \(text)")
        }
    }

    @Test(arguments: ["en", "de", "ar"])
    func `live resets use the widget localization bundle`(language: String) {
        WidgetLocalizationOverride.$language.withValue(language) {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let expected = if #available(macOS 15, *) {
                Text(
                    "Resets \(Text(.currentDate, format: WidgetDateText.resetFormat(date)))",
                    bundle: WidgetLocalization.currentBundle)
            } else {
                Text("Resets in \(Text(date, style: .relative))", bundle: WidgetLocalization.currentBundle)
            }
            #expect(WidgetDateText.reset(date) == expected)
        }
    }
}
