import AppKit
import CodexBarCore
import SwiftUI
import Testing
import Vision
import WidgetKit
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

    @Test(arguments: [WidgetFamily.systemMedium, .systemLarge], [ColorScheme.light, .dark])
    func `account overview rows and overflow remain readable`(family: WidgetFamily, scheme: ColorScheme) throws {
        try WidgetLocalizationOverride.$language.withValue("en") {
            let size = CGSize(width: 329, height: family == .systemLarge ? 345 : 155)
            for count in [6, 10] {
                let entry = WidgetAccountsOverviewTests().entry(
                    remaining: (1...count).map { Double($0 * 9) }, overflow: count == 6 ? 3 : 0)
                let view = AccountsOverviewTile(entry: entry, family: family)
                    .environment(\.locale, Locale(identifier: "en"))
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width - 32, height: size.height - 32)
                    .padding(16)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try #require(renderer.cgImage)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").replacingOccurrences(of: " ", with: "")
                let shown = min(count, family == .systemLarge ? 8 : 4)
                for index in 1...shown {
                    #expect(text.contains("Account\(index)"), "Missing account \(index): \(text)")
                    #expect(text.contains("\(index * 9)%"), "Missing quota \(index): \(text)")
                }
                #expect(!text.contains("Account\(shown + 1)"))
                let overflow = count - shown + (count == 6 ? 3 : 0)
                #expect(text.contains("+\(overflow)more"), "Missing overflow: \(text)")
                #expect(!text.contains("999"))
                if let path = ProcessInfo.processInfo.environment["CODEXBAR_WIDGET_HEADLINE_PROOF_DIR"] {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(
                        "accounts-\(family)-\(scheme)-\(count).png"))
                    if count == 6 {
                        let account = entry.snapshot.accounts[0]
                        let usage = try #require(WidgetAccountsOverviewTests()
                            .entry(remaining: [9], includeExtras: false).snapshot.accounts.first?.usage)
                        let baseline = UsageTile(entry: usage, size: WidgetTileSize(family: family)) {
                            VStack(alignment: .leading, spacing: 3) {
                                TileHeader(
                                    provider: usage.provider,
                                    updatedAt: usage.updatedAt,
                                    size: WidgetTileSize(family: family))
                                Text(account.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .environment(\.colorScheme, scheme)
                        .frame(width: size.width - 32, height: size.height - 32)
                        .padding(16)
                        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                        let before = ImageRenderer(content: baseline)
                        before.scale = 3
                        let bitmap = try NSBitmapImageRep(cgImage: #require(before.cgImage))
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(
                            "before-pinned-\(family)-\(scheme).png"))
                    }
                }
            }
        }
    }
}
