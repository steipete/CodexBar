import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreEmptyConfigTests {
    @Test(arguments: ["", " \t\r\n "])
    func `blank external config preserves in memory settings for the next save`(_ contents: String) throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .grok, enabled: true),
            ProviderConfig(id: .groq, enabled: true, apiKey: "fixture-key"),
        ])
        let settings = testSettingsStore(suiteName: "SettingsStoreEmptyConfigTests", config: config)
        let store = settings.configStore
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let before = try store.encodedData(for: settings.configSnapshot)
        try Data(contents.utf8).write(to: store.fileURL)

        settings.reloadConfig(reason: "blank-fixture", origin: .localFile)
        #expect(try store.encodedData(for: settings.configSnapshot) == before)
        #expect(try Data(contentsOf: store.fileURL) == Data(contents.utf8))

        settings.updateProviderConfig(provider: .grok) { $0.enabled = false }
        let saved = try #require(try store.load())
        #expect(saved.providerConfig(for: .grok)?.enabled == false)
        #expect(saved.providerConfig(for: .groq)?.apiKey == "fixture-key")
        #expect(saved.providerConfig(for: .groq)?.enabled == true)
    }
}
