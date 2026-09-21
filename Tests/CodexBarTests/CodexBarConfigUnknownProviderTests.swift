import Foundation
import Testing
@testable import CodexBarCore

struct CodexBarConfigUnknownProviderTests {
    @Test
    func `removed provider entries do not invalidate persisted config`() throws {
        let data = Data(#"""
        {
          "version": 1,
          "providers": [
            {"id": "kimik2", "enabled": true},
            {"id": "crossmodel", "enabled": true},
            {"id": "crof", "enabled": true, "apiKey": "retired-fixture-key"},
            {"id": "codex", "enabled": false, "source": "oauth"}
          ]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(decoded.providers.map(\.id) == [.codex])
        #expect(decoded.providerConfig(for: .codex)?.enabled == false)
        #expect(decoded.providerConfig(for: .codex)?.source == .oauth)
    }

    @Test
    func `reading retired Crof config preserves disk bytes until the next save`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let config = CodexBarConfig(providers: UsageProvider.allCases
            .filter { $0.rawValue != "crof" }
            .map { ProviderConfig(id: $0.instanceID, enabled: false) })
        let expected = try store.encodedData(for: config)
        let text = try #require(String(data: expected, encoding: .utf8))
        let retired = text.replacingOccurrences(
            of: "\"providers\" : [",
            with: "\"providers\" : [{\"id\":\"crof\",\"enabled\":true,\"apiKey\":\"retired-fixture-key\"},")
        let original = Data(retired.utf8)
        try store.saveEncodedData(original)

        let loaded = try #require(try store.load())

        #expect(loaded.providers.map(\.id) == config.providers.map(\.id))
        #expect(try Data(contentsOf: store.fileURL) == original)
        try store.save(loaded)
        #expect(try Data(contentsOf: store.fileURL) == expected)
    }
}
