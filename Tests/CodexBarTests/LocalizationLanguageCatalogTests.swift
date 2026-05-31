import Foundation
import Testing
@testable import CodexBar

struct LocalizationLanguageCatalogTests {
    @Test
    func `app language catalog includes Ukrainian`() {
        #expect(AppLanguage.allCases.contains(.ukrainian))
        #expect(AppLanguage.ukrainian.rawValue == "uk")
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
}
