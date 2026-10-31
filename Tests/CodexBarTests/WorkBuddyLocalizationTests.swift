import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct WorkBuddyLocalizationTests {
    @Test
    func `settings and reserved credits have translations in every language`() throws {
        let spec = WorkBuddyProviderDescriptor.spec
        let web = try #require(spec.webSource)
        let picker = try #require(web.picker)
        guard case let .localized(autoKey, _) = picker.auto else {
            Issue.record("Automatic cookie guidance must be localized")
            return
        }
        let keys = try [
            spec.noDataMessage,
            web.field.subtitle,
            #require(web.field.action).title,
            autoKey,
            "Reserved",
            "Rewards",
            "Reward expiry",
        ]
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexBar/Resources")
        for language in AppLanguage.allCases where language != .system {
            let url = resources.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")
            let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys {
                #expect(catalog[key]?.isEmpty == false, "\(language.rawValue): \(key)")
            }
        }
    }
}
