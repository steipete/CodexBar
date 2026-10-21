import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarWidget

struct WidgetLocalizationTests {
    @Test
    func `Arabic widget formats numeric arguments using its own resource locale`() {
        WidgetLocalizationOverride.$language.withValue("ar") {
            #expect(W("%dd", 12).contains("١٢"))
        }
    }

    @Test
    func `widget period keys remain translatable independently of the app language`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: 1,
            last30DaysTokens: nil,
            last30DaysCostUSD: 2,
            historyLabel: "This month",
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1))
        let summary = try CodexBarLocalizationOverride.$appLanguage.withValue("fa") {
            try #require(UsageStore.widgetTokenUsageSummary(from: snapshot, provider: .mistral))
        }
        #expect(summary.last30DaysLabel == "This month")
        WidgetLocalizationOverride.$language.withValue("en") {
            #expect(CompactMetricFormatter.costMetricLabel(summary.last30DaysLabel, provider: .mistral) ==
                "This month cost")
        }
        WidgetLocalizationOverride.$language.withValue("fa") {
            #expect(CompactMetricFormatter.costMetricLabel(summary.last30DaysLabel, provider: .mistral) ==
                W("%@ cost", W("This month")))
        }
    }

    @Test
    func `widget resources resolve prose and formatted labels in every supported language`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let appResources = root.appendingPathComponent("Sources/CodexBar/Resources")
        for language in AppLanguage.allCases where language != .system {
            let app = try #require(NSDictionary(contentsOf: appResources.appendingPathComponent(
                "\(language.rawValue).lproj/Localizable.strings")) as? [String: String])
            let bundle = WidgetLocalization.bundle(language: language.rawValue)
            #expect(bundle.bundleURL.lastPathComponent.caseInsensitiveCompare("\(language.rawValue).lproj") ==
                .orderedSame)
            try WidgetLocalizationOverride.$language.withValue(language.rawValue) {
                for key in [
                    "Choose an account",
                    "Enable a provider in CodexBar → Settings → Providers.",
                    "Credits left",
                    "No data",
                ] {
                    #expect(W(key) == app[key])
                    if language != .english {
                        #expect(W(key) != key, "Untranslated widget text in \(language.rawValue): \(key)")
                    }
                }
                let format = try #require(app["%@ used"])
                let locale = Locale(identifier: language.rawValue == "ar" ? "ar@numbers=arab" : language.rawValue)
                #expect(WidgetLaneCopy.caption(title: "Session", showUsed: true) ==
                    String(format: format, locale: locale, W("Session")))
                #expect(W("Reset: %@", "MARKER").contains("MARKER"))
                #expect(CompactMetricFormatter.costMetricLabel("30d API est. · not billed", provider: .codex) ==
                    W("%@ API est. · not billed", W("%dd", 30)))
                #expect(CompactMetricFormatter.costMetricLabel("Today", provider: .claude) ==
                    W("%@ cost", W("Today")))
                #expect(burnFmtDuration(1500).contains("1"))
                #expect(WidgetLaneCopy.duration(3600) == W("%@h", "1"))
                #expect(WidgetLaneCopy.duration(86399) == W("%@d", "1"))
            }
        }
    }

    @Test(arguments: ["zh-Hans", "zh-Hant", "pt-BR"])
    func `widget resolves lowercased SwiftPM locale directories`(language: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-widget-localization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resourceURL = root.appendingPathComponent("WidgetLocalization.bundle", isDirectory: true)
        for fixtureLanguage in ["en", "zh-Hans", "zh-Hant", "pt-BR"] {
            let localizedURL = resourceURL.appendingPathComponent(
                "\(fixtureLanguage.lowercased()).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: localizedURL, withIntermediateDirectories: true)
            try "\"Choose an account\" = \"Fixture \(fixtureLanguage)\";\n".write(
                to: localizedURL.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let resourceBundle = try #require(Bundle(url: resourceURL))

        let bundle = WidgetLocalization.bundle(language: language, resourceBundle: resourceBundle)

        #expect(bundle.bundleURL.lastPathComponent == "\(language.lowercased()).lproj")
        #expect(bundle.localizedString(forKey: "Choose an account", value: nil, table: nil) == "Fixture \(language)")
    }

    @Test
    func `English widget labels preserve durations and accessible provider names`() {
        WidgetLocalizationOverride.$language.withValue("en") {
            #expect(burnFmtDuration(1500) == "1d 1h")
            #expect(burnFmtDuration(61) == "1h 01m")
            #expect(burnWindowLabel(300) == "5-hour limit")
            #expect(ProviderMarkLabel.text(for: .codex, isSelected: true) == "Codex, selected")
        }
    }
}
