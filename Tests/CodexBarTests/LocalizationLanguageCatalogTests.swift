import Foundation
import Testing
@testable import CodexBar

struct LocalizationLanguageCatalogTests {
    private let languageKeys = [
        "language_system",
        "language_english",
        "language_german",
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
        "language_korean",
        "language_turkish",
    ]

    @Test
    func `app language catalog includes Ukrainian`() {
        #expect(AppLanguage.allCases.contains(.ukrainian))
        #expect(AppLanguage.ukrainian.rawValue == "uk")
    }

    @Test
    func `app language catalog includes Korean`() {
        #expect(AppLanguage.allCases.contains(.korean))
        #expect(AppLanguage.korean.rawValue == "ko")
    }

    @Test
    func `app language catalog includes Turkish`() {
        #expect(AppLanguage.allCases.contains(.turkish))
        #expect(AppLanguage.turkish.rawValue == "tr")
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
    func `korean localization bundle includes representative native labels`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let koURL = root.appendingPathComponent("Sources/CodexBar/Resources/ko.lproj/Localizable.strings")
        let catalog = try #require(NSDictionary(contentsOf: koURL) as? [String: String])

        #expect(catalog["language_korean"] == "한국어")
        #expect(catalog["tab_general"] == "일반")
        #expect(catalog["quota_warning_session"] == "세션")
        #expect(catalog["quota_warning_warn_at"] == "경고 기준")
        #expect(catalog["quit_app"] == "CodexBar 종료")
    }

    @Test
    func `turkish localization matches English catalog and preserves format placeholders`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesURL = root.appendingPathComponent("Sources/CodexBar/Resources")
        let enURL = resourcesURL.appendingPathComponent("en.lproj/Localizable.strings")
        let trURL = resourcesURL.appendingPathComponent("tr.lproj/Localizable.strings")
        let english = try #require(NSDictionary(contentsOf: enURL) as? [String: String])
        let turkish = try #require(NSDictionary(contentsOf: trURL) as? [String: String])

        #expect(Set(turkish.keys) == Set(english.keys))
        #expect(turkish["language_turkish"] == "Türkçe")
        #expect(turkish["tab_general"] == "Genel")
        #expect(turkish["quit_app"] == "CodexBar'dan Çık")
        #expect(turkish["display_mode_percent_desc"]?.contains("%45") == true)
        #expect(turkish["session_depleted_notification_body"]?.hasPrefix("0% kaldı.") == true)

        let format = try #require(turkish["quota_warning_notification_body"])
        let rendered = String(
            format: format,
            locale: Locale(identifier: "tr_TR"),
            arguments: ["%20", 15, "oturum"])
        #expect(rendered.contains("15%"))
        #expect(!rendered.contains("%2$d"))

        let historyFormat = try #require(turkish["%@: %@%% used"])
        let historyLabel = String(
            format: historyFormat,
            locale: Locale(identifier: "tr_TR"),
            arguments: ["12 Haz", "45"])
        #expect(historyLabel == "12 Haz: 45% kullanıldı")

        let miniMaxFormat = try #require(turkish["minimax_used_percent_format"])
        let miniMaxLabel = String(
            format: miniMaxFormat,
            locale: Locale(identifier: "tr_TR"),
            arguments: ["45%"])
        #expect(miniMaxLabel == "45% kullanıldı")
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

    @Test
    func `korean usage chart accessibility text preserves argument meanings`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let koURL = root.appendingPathComponent("Sources/CodexBar/Resources/ko.lproj/Localizable.strings")
        let catalog = try #require(NSDictionary(contentsOf: koURL) as? [String: String])
        let format = try #require(catalog["%d days of usage data across %d services"])

        let rendered = String(
            format: format,
            locale: Locale(identifier: "ko_KR"),
            arguments: [7, 3])

        #expect(rendered.contains("7일간"))
        #expect(rendered.contains("3개 서비스"))
    }
}
