import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreActiveProviderTests {
    @Test
    func `menu bar shows active provider defaults to false`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreActiveProviderTests-default")

        #expect(settings.menuBarShowsActiveProvider == false)
    }

    @Test
    func `menu bar shows active provider persists across instances`() throws {
        let suite = "SettingsStoreActiveProviderTests-persist-active-toggle"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = Self.makeSettingsStore(userDefaults: defaultsA, configStore: configStore)

        storeA.menuBarShowsActiveProvider = true

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = Self.makeSettingsStore(userDefaults: defaultsB, configStore: configStore)

        #expect(storeB.menuBarShowsActiveProvider == true)
    }

    @Test
    func `last active provider persists across instances`() throws {
        let suite = "SettingsStoreActiveProviderTests-persist-last-provider"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = Self.makeSettingsStore(userDefaults: defaultsA, configStore: configStore)

        storeA.lastActiveProvider = .claude

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = Self.makeSettingsStore(userDefaults: defaultsB, configStore: configStore)

        #expect(storeB.lastActiveProvider == .claude)
    }

    @Test
    func `last active provider invalid raw resolves nil and clearing removes persisted value`() throws {
        let suite = "SettingsStoreActiveProviderTests-invalid-and-clear"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set("invalid-provider", forKey: "lastActiveProvider")

        let configStore = testConfigStore(suiteName: suite)
        let store = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        #expect(store.lastActiveProvider == nil)

        store.lastActiveProvider = .codex
        #expect(defaults.string(forKey: "lastActiveProvider") == UsageProvider.codex.rawValue)

        store.lastActiveProvider = nil
        #expect(defaults.string(forKey: "lastActiveProvider") == nil)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)
    }

    private static func makeSettingsStore(
        userDefaults: UserDefaults,
        configStore: CodexBarConfigStore) -> SettingsStore
    {
        SettingsStore(
            userDefaults: userDefaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
