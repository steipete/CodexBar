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
        "language_italian",
        "language_vietnamese",
        "language_japanese",
        "language_korean",
        "language_turkish",
        "language_indonesian",
        "language_polish",
        "language_arabic",
        "language_persian",
        "language_thai",
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
    func `app language catalog includes Italian`() {
        #expect(AppLanguage.allCases.contains(.italian))
        #expect(AppLanguage.italian.rawValue == "it")
    }

    @Test
    func `app language catalog includes Indonesian`() {
        #expect(AppLanguage.allCases.contains(.indonesian))
        #expect(AppLanguage.indonesian.rawValue == "id")
    }

    @Test
    func `app language catalog includes Polish`() {
        #expect(AppLanguage.allCases.contains(.polish))
        #expect(AppLanguage.polish.rawValue == "pl")
    }

    @Test
    func `app language catalog includes Arabic Persian and Thai`() {
        #expect(AppLanguage.arabic.rawValue == "ar")
        #expect(AppLanguage.persian.rawValue == "fa")
        #expect(AppLanguage.thai.rawValue == "th")
    }

    @Test
    func `new language bundles include representative native labels`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesURL = root.appendingPathComponent("Sources/CodexBar/Resources")
        let expectations: [String: [String: String]] = [
            "ar": [
                "language_arabic": "العربية",
                "tab_general": "عام",
                "quit_app": "إنهاء CodexBar",
                "usage_percent_suffix_left": "متبقٍ",
            ],
            "fa": [
                "language_persian": "فارسی",
                "tab_general": "عمومی",
                "quit_app": "خروج از CodexBar",
                "usage_percent_suffix_left": "باقی مانده",
            ],
            "th": [
                "language_thai": "ไทย",
                "tab_general": "ทั่วไป",
                "quit_app": "ออกจาก CodexBar",
                "usage_percent_suffix_left": "คงเหลือ",
            ],
        ]

        for (locale, expectedValues) in expectations {
            let url = resourcesURL.appendingPathComponent("\(locale).lproj/Localizable.strings")
            let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for (key, expectedValue) in expectedValues {
                #expect(catalog[key] == expectedValue, "\(locale).\(key)")
            }
        }
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
    func `localized catalogs include workday pace setting copy`() throws {
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
            let catalog = try #require(NSDictionary(contentsOf: stringsURL) as? [String: String])
            let title = catalog["weekly_progress_work_days_title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = catalog["weekly_progress_work_days_subtitle"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            #expect(title?.isEmpty == false, "Missing workday title in \(catalogURL.lastPathComponent)")
            #expect(subtitle?.isEmpty == false, "Missing workday subtitle in \(catalogURL.lastPathComponent)")
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
    func `italian localization matches English catalog and includes current UI labels`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesURL = root.appendingPathComponent("Sources/CodexBar/Resources")
        let enURL = resourcesURL.appendingPathComponent("en.lproj/Localizable.strings")
        let itURL = resourcesURL.appendingPathComponent("it.lproj/Localizable.strings")
        let english = try #require(NSDictionary(contentsOf: enURL) as? [String: String])
        let italian = try #require(NSDictionary(contentsOf: itURL) as? [String: String])

        #expect(Set(italian.keys) == Set(english.keys))
        #expect(italian["Individual credits"] == "Crediti individuali")
        #expect(italian["Workspace"] == "Spazio di lavoro")
        #expect(italian["display_mode_reset_time"] == "Ora di reimpostazione")
        #expect(italian["display_mode_reset_time_desc"]?.contains("↻ 15:56") == true)
        #expect(italian["ory_session_…=…; csrftoken=…"] == "ory_session_…=…; csrftoken=…")
        #expect(italian["quota_warning_notifications_subtitle"]?.contains("scende sotto") == true)
        #expect(italian["metric_mistral_payg"] == "A consumo")
        #expect(italian["metric_mistral_monthly_plan"] == "Piano mensile")

        let intentionallyUnchanged: Set = [
            "Account",
            "Build",
            "Chrome",
            "Cookie: ...",
            "Cookie: …",
            "Deployment",
            "Email",
            "Endpoint",
            "Gemini Flash",
            "GitHub",
            "Google OAuth",
            "No",
            "Oasis-Token",
            "Password",
            "Provider",
            "Token",
            "%@: %@",
            "byte_unit_byte",
            "byte_unit_gigabyte",
            "byte_unit_kilobyte",
            "byte_unit_megabyte",
            "language_arabic",
            "language_italian",
            "language_persian",
            "language_thai",
            "link_email",
            "link_github",
            "ory_session_…=…; csrftoken=…",
        ]
        let unchanged = Set(english.keys.filter { italian[$0] == english[$0] })
        #expect(unchanged == intentionallyUnchanged)

        let warningFormat = try #require(italian["quota_warning_notification_body"])
        let warning = String(
            format: warningFormat,
            locale: Locale(identifier: "it_IT"),
            arguments: ["20%", 15, "settimanale"])
        #expect(warning == "Rimane 20%. Hai raggiunto la soglia di avviso del 15% per la quota settimanale.")

        let titleFormat = try #require(italian["quota_warning_notification_title"])
        let title = String(
            format: titleFormat,
            locale: Locale(identifier: "it_IT"),
            arguments: ["Codex", "settimanale"])
        #expect(title == "Quota settimanale di Codex quasi esaurita")
    }

    @Test
    func `indonesian localization matches English catalog and preserves format placeholders`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesURL = root.appendingPathComponent("Sources/CodexBar/Resources")
        let enURL = resourcesURL.appendingPathComponent("en.lproj/Localizable.strings")
        let idURL = resourcesURL.appendingPathComponent("id.lproj/Localizable.strings")
        let english = try #require(NSDictionary(contentsOf: enURL) as? [String: String])
        let indonesian = try #require(NSDictionary(contentsOf: idURL) as? [String: String])

        #expect(Set(indonesian.keys) == Set(english.keys))
        #expect(indonesian["language_indonesian"] == "Bahasa Indonesia")
        #expect(indonesian["tab_general"] == "Umum")
        #expect(indonesian["quit_app"] == "Keluar CodexBar")
        #expect(indonesian["30d"] == "30 hari")
        #expect(indonesian["On"] == "Aktif")
        #expect(indonesian["Off"] == "Nonaktif")

        let warningFormat = try #require(indonesian["quota_warning_notification_body"])
        let warning = String(
            format: warningFormat,
            locale: Locale(identifier: "id_ID"),
            arguments: ["20%", 15, "sesi"])
        #expect(warning.contains("15%"))
        #expect(!warning.contains("%2$d"))

        let historyFormat = try #require(indonesian["%@: %@%% used"])
        let historyLabel = String(
            format: historyFormat,
            locale: Locale(identifier: "id_ID"),
            arguments: ["12 Jun", "45"])
        #expect(historyLabel == "12 Jun: 45% terpakai")

        let daysFormat = try #require(indonesian["%dd"])
        let daysLabel = String(
            format: daysFormat,
            locale: Locale(identifier: "id_ID"),
            arguments: [30])
        #expect(daysLabel == "30 hari")
    }

    @Test
    func `polish localization matches English catalog and includes current UI labels`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesURL = root.appendingPathComponent("Sources/CodexBar/Resources")
        let enURL = resourcesURL.appendingPathComponent("en.lproj/Localizable.strings")
        let plURL = resourcesURL.appendingPathComponent("pl.lproj/Localizable.strings")
        let english = try #require(NSDictionary(contentsOf: enURL) as? [String: String])
        let polish = try #require(NSDictionary(contentsOf: plURL) as? [String: String])

        #expect(Set(polish.keys) == Set(english.keys))
        #expect(polish["Individual credits"] == "Kredyty indywidualne")
        #expect(polish["Workspace"] == "Obszar roboczy")
        #expect(polish["display_mode_reset_time"] == "Godzina resetu")
        #expect(polish["display_mode_reset_time_desc"]?.contains("↻ 15:56") == true)
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
