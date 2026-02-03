import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct ProviderToggleStoreTests {
    @Test
    func defaultsMatchMetadata() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProviderToggleStoreTests-defaults"))
        defaults.removePersistentDomain(forName: "ProviderToggleStoreTests-defaults")
        let store = ProviderToggleStore(userDefaults: defaults)
        let registry = ProviderRegistry.shared
        let codexMeta = try #require(registry.metadata[.codex])
        let claudeMeta = try #require(registry.metadata[.claude])

        #expect(store.isEnabled(metadata: codexMeta))
        #expect(!store.isEnabled(metadata: claudeMeta))
    }

    @Test
    func persistsChanges() throws {
        let suite = "ProviderToggleStoreTests-persist"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let storeA = ProviderToggleStore(userDefaults: defaultsA)
        let registry = ProviderRegistry.shared
        let claudeMeta = try #require(registry.metadata[.claude])

        storeA.setEnabled(true, metadata: claudeMeta)

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = ProviderToggleStore(userDefaults: defaultsB)
        #expect(storeB.isEnabled(metadata: claudeMeta))
    }

    @Test
    func purgesLegacyKeys() throws {
        let suite = "ProviderToggleStoreTests-purge"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "showCodexUsage")
        defaults.set(true, forKey: "showClaudeUsage")

        let store = ProviderToggleStore(userDefaults: defaults)
        store.purgeLegacyKeys()

        #expect(defaults.object(forKey: "showCodexUsage") == nil)
        #expect(defaults.object(forKey: "showClaudeUsage") == nil)
    }
}
