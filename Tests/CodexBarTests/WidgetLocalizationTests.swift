import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarWidget

struct WidgetLocalizationTests {
    @Test
    func `widget resources resolve prose and formatted labels in every supported language`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let appResources = root.appendingPathComponent("Sources/CodexBar/Resources")
        for language in AppLanguage.allCases where language != .system {
            let app = try #require(NSDictionary(contentsOf: appResources.appendingPathComponent(
                "\(language.rawValue).lproj/Localizable.strings")) as? [String: String])
            let bundle = WidgetLocalization.bundle(language: language.rawValue)
            #expect(bundle.bundleURL.lastPathComponent == "\(language.rawValue).lproj")
            try WidgetLocalizationOverride.$language.withValue(language.rawValue) {
                for key in ["Choose an account", "Usage data will appear once the app refreshes.", "Credits left"] {
                    #expect(W(key) == app[key])
                    if language != .english {
                        #expect(W(key) != key, "Untranslated widget text in \(language.rawValue): \(key)")
                    }
                }
                let format = try #require(app["%@ used"])
                #expect(WidgetLaneCopy.caption(title: "Session", showUsed: true) ==
                    String(format: format, W("Session")))
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
