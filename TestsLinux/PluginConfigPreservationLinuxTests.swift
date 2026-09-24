import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct PluginConfigPreservationLinuxTests {
    @Test
    func `config writes retain plugins without a registered runtime`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let raw = Data(#"""
        {"version":1,"providers":[{"id":"portable-fixture","pluginSecrets":{"TOKEN":"fixture-secret"},
        "pluginSettings":{"scope":"fixture"},"future":[null,true,18446744073709551615]}]}
        """#.utf8)
        try store.saveEncodedData(raw)
        let loaded = try #require(try store.load())
        let updated = CodexBarCLI.configSettingProviderEnabled(loaded, provider: .grok, enabled: true)
        try store.save(updated)
        let original = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let before = try #require(original["providers"] as? [NSDictionary])
        let after = try #require(saved["providers"] as? [NSDictionary])
        #expect(after.first == before.first)
        #expect(updated.providerConfig(for: .grok)?.enabled == true)
    }
}
