import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct AccountMenuBarDisplayModeTests {
    @Test
    func `display mode defaults to combined for missing and invalid values`() throws {
        let suite = "AccountMenuBarDisplayModeTests-default"
        let (store, defaults, _) = try Self.makeStore(suite: suite)

        #expect(store.accountMenuBarDisplayMode(for: .codex) == .combined)

        defaults.set([UsageProvider.codex.rawValue: "invalid"], forKey: "accountMenuBarDisplayModes")
        let invalidStore = try Self.reconstructStore(suite: suite)
        #expect(invalidStore.accountMenuBarDisplayMode(for: .codex) == .combined)
    }

    @Test
    func `display modes are isolated by provider`() throws {
        let (store, _, _) = try Self.makeStore(suite: "AccountMenuBarDisplayModeTests-provider-isolation")

        store.setAccountMenuBarDisplayMode(.separate, for: .codex)

        #expect(store.accountMenuBarDisplayMode(for: .codex) == .separate)
        #expect(store.accountMenuBarDisplayMode(for: .claude) == .combined)
    }

    @Test
    func `display mode persists across settings store instances`() throws {
        let suite = "AccountMenuBarDisplayModeTests-persistence"
        let (store, _, _) = try Self.makeStore(suite: suite)
        store.setAccountMenuBarDisplayMode(.separate, for: .claude)

        let reconstructed = try Self.reconstructStore(suite: suite)

        #expect(reconstructed.accountMenuBarDisplayMode(for: .claude) == .separate)
    }

    @Test
    func `separate display mode disables merged icons`() throws {
        let (store, defaults, _) = try Self.makeStore(suite: "AccountMenuBarDisplayModeTests-separate-disables-merge")
        #expect(store.mergeIcons)

        store.setAccountMenuBarDisplayMode(.separate, for: .codex)

        #expect(store.mergeIcons == false)
        #expect(defaults.object(forKey: "mergeIcons") as? Bool == false)
    }

    @Test
    func `merged icons temporarily override separate display modes`() throws {
        let suite = "AccountMenuBarDisplayModeTests-merge-overrides-separate"
        let (store, defaults, _) = try Self.makeStore(suite: suite)
        store.setAccountMenuBarDisplayMode(.separate, for: .codex)
        store.setAccountMenuBarDisplayMode(.separate, for: .claude)

        store.mergeIcons = true

        #expect(store.accountMenuBarDisplayMode(for: .codex) == .combined)
        #expect(store.accountMenuBarDisplayMode(for: .claude) == .combined)
        #expect(defaults.dictionary(forKey: "accountMenuBarDisplayModes") as? [String: String] == [
            UsageProvider.codex.rawValue: AccountMenuBarDisplayMode.separate.rawValue,
            UsageProvider.claude.rawValue: AccountMenuBarDisplayMode.separate.rawValue,
        ])

        let reconstructed = try Self.reconstructStore(suite: suite)
        #expect(reconstructed.accountMenuBarDisplayMode(for: .codex) == .combined)
        #expect(reconstructed.accountMenuBarDisplayMode(for: .claude) == .combined)

        reconstructed.mergeIcons = false

        #expect(reconstructed.accountMenuBarDisplayMode(for: .codex) == .separate)
        #expect(reconstructed.accountMenuBarDisplayMode(for: .claude) == .separate)
    }

    private static func makeStore(
        suite: String) throws -> (SettingsStore, UserDefaults, CodexBarConfigStore)
    {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "debugDisableKeychainAccess")
        defaults.set(true, forKey: "providerDetectionCompleted")
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: []))
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        return (store, defaults, configStore)
    }

    private static func reconstructStore(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let configStore = testConfigStore(suiteName: suite, reset: false)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
