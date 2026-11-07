import Foundation
import Testing
@testable import CodexBarCore

struct WidgetSnapshotSelectionTests {
    @Test
    func `pinned decode materializes only its provider while retaining availability and account ambiguity`() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let entries: [WidgetSnapshot.ProviderEntry] = [UsageProvider.codex, .claude, .gemini].map { provider in
            WidgetSnapshot.ProviderEntry(provider: provider, updatedAt: date, primary: nil, secondary: nil)
        }
        let snapshot = WidgetSnapshot(
            entries: entries,
            accounts: [
                .init(id: "duplicate", provider: .codex, label: "First", usage: entries[0]),
                .init(id: "duplicate", provider: .claude, label: "Second", usage: entries[1]),
            ],
            generatedAt: date)
        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.userInfo[WidgetSnapshot.selectedProviderKey] = UsageProvider.codex.instanceID
        let selected = try decoder.decode(WidgetSnapshot.self, from: data)
        #expect(selected.entries.map(\.provider) == [.codex])
        #expect(selected.enabledProviders == [.codex, .claude, .gemini])
        #expect(selected.accounts.count == 2)
        #expect(selected.account(id: "duplicate", provider: .codex) == nil)
        #expect(selected.generatedAt == date)

        let legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            .filter { $0.key != "enabledProviders" }
        let legacySelected = try decoder.decode(
            WidgetSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(legacySelected.entries.count == 1)
        #expect(legacySelected.enabledProviders == [.codex, .claude, .gemini])

        decoder.userInfo.removeAll()
        #expect(try decoder.decode(WidgetSnapshot.self, from: data).entries.count == 3)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        WidgetSnapshotStore.save(snapshot, to: url)
        let pinned = try #require(WidgetSnapshotStore.load(from: url, provider: .codex))
        #expect(pinned.entries.map(\.provider) == [.codex])
        #expect(pinned.enabledProviders == selected.enabledProviders)
        #expect(pinned.accounts.count == 2)
        #expect(pinned.entries.first?.updatedAt == date)
        #expect(WidgetSnapshotStore.load(from: url)?.entries.count == 3)
    }
}

extension WidgetSnapshotSelectionTests {
    @Test
    func `pinned decode skips unrelated payloads but still rejects a malformed selected payload`() throws {
        let data = Data(#"""
        {"entries":[
          {"provider":"codex","updatedAt":0,"dailyUsage":[]},
          {"provider":"claude","updatedAt":0,"dailyUsage":"invalid fixture"}
        ],"generatedAt":0}
        """#.utf8)
        let decoder = JSONDecoder()
        let key = WidgetSnapshot.selectedProviderKey
        decoder.userInfo[key] = UsageProvider.codex.instanceID
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: data)
        #expect(snapshot.entries.map(\.provider) == [.codex])
        #expect(snapshot.enabledProviders == [.codex, .claude])
        decoder.userInfo[key] = UsageProvider.claude.instanceID
        #expect(throws: DecodingError.self) { try decoder.decode(WidgetSnapshot.self, from: data) }
        decoder.userInfo[key] = UsageProvider.gemini.instanceID
        #expect(try decoder.decode(WidgetSnapshot.self, from: data).entries.isEmpty)
        decoder.userInfo.removeAll()
        #expect(throws: DecodingError.self) { try decoder.decode(WidgetSnapshot.self, from: data) }
    }
}
