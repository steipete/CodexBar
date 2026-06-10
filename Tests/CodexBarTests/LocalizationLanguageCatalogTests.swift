import Foundation
import Testing
@testable import CodexBar

struct LocalizationLanguageCatalogTests {
    private let languageKeys = [
        "language_system",
        "language_english",
        "language_spanish",
        "language_catalan",
        "language_chinese_simplified",
        "language_chinese_traditional",
        "language_portuguese_brazilian",
        "language_swedish",
        "language_french",
        "language_dutch",
        "language_ukrainian",
        "language_vietnamese",
        "language_japanese",
    ]

    @Test
    func `app language catalog includes Ukrainian`() {
        #expect(AppLanguage.allCases.contains(.ukrainian))
        #expect(AppLanguage.ukrainian.rawValue == "uk")
    }

    @Test
    func `localized catalogs include every app language label`() throws {
        #expect(self.languageKeys.count == AppLanguage.allCases.count)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesURL = root.appendingPathComponent("Sources/CodexBar/Resources")
        let catalogs = try FileManager.default.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }

        for catalogURL in catalogs {
            let stringsURL = catalogURL.appendingPathComponent("Localizable.strings")
            let contents = try String(contentsOf: stringsURL, encoding: .utf8)
            for key in self.languageKeys {
                #expect(contents.contains("\"\(key)\""), "Missing \(key) in \(catalogURL.lastPathComponent)")
            }
        }
    }

    @Test
    func `ukrainian localization bundle exists and contains key UI labels`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ukURL = root.appendingPathComponent("Sources/CodexBar/Resources/uk.lproj/Localizable.strings")
        let contents = try String(contentsOf: ukURL, encoding: .utf8)

        let requiredKeys = [
            "\"language_title\"",
            "\"language_subtitle\"",
            "\"language_system\"",
            "\"language_ukrainian\"",
            "\"tab_general\"",
            "\"quit_app\"",
        ]
        for key in requiredKeys {
            #expect(contents.contains(key), "Missing localization key: \(key)")
        }
    }

    @Test
    func `japanese usage chart accessibility text preserves argument meanings`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let jaURL = root.appendingPathComponent("Sources/CodexBar/Resources/ja.lproj/Localizable.strings")
        let catalog = try #require(NSDictionary(contentsOf: jaURL) as? [String: String])
        let format = try #require(catalog["%d days of usage data across %d services"])

        let rendered = String(
            format: format,
            locale: Locale(identifier: "ja_JP"),
            arguments: [7, 3])

        #expect(rendered.contains("7日間"))
        #expect(rendered.contains("3サービス"))
    }
}
