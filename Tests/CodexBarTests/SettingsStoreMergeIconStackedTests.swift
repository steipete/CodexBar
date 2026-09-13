import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct SettingsStoreMergeIconStackedTests {
    @Test
    func `merged icon display style toggles between switcher and stacked`() throws {
        let suite = "SettingsStoreTests-merged-icon-style"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.mergedIconDisplayStyle == .switcher)
        store.mergedIconDisplayStyle = .stacked
        #expect(store.mergeIconsStacked)
        #expect(store.mergedIconDisplayStyle == .stacked)
        store.mergedIconDisplayStyle = .switcher
        #expect(!store.mergeIconsStacked)
    }

    @Test
    func `resolved merge icon stacked providers defaults to first two active providers`() throws {
        let suite = "SettingsStoreTests-merge-icon-stacked-default"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude, .cursor])

        #expect(resolved?.top == .codex)
        #expect(resolved?.bottom == .claude)
    }

    @Test
    func `resolved merge icon stacked providers is nil with fewer than two active providers`() throws {
        let suite = "SettingsStoreTests-merge-icon-stacked-insufficient"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.resolvedMergeIconStackedProviders(activeProviders: [.codex]) == nil)
        #expect(store.resolvedMergeIconStackedProviders(activeProviders: []) == nil)
    }

    @Test
    func `resolved merge icon stacked providers honors explicit top and bottom pick`() throws {
        let suite = "SettingsStoreTests-merge-icon-stacked-explicit"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergeIconStackedTopProvider = .cursor
        store.mergeIconStackedBottomProvider = .codex
        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude, .cursor])

        #expect(resolved?.top == .cursor)
        #expect(resolved?.bottom == .codex)
    }

    @Test
    func `resolved merge icon stacked providers falls back when explicit pick is no longer active`() throws {
        let suite = "SettingsStoreTests-merge-icon-stacked-fallback"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergeIconStackedTopProvider = .cursor
        store.mergeIconStackedBottomProvider = .gemini
        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude])

        #expect(resolved?.top == .codex)
        #expect(resolved?.bottom == .claude)
    }

    @Test
    func `resolved merge icon stacked providers never picks the same provider twice`() throws {
        let suite = "SettingsStoreTests-merge-icon-stacked-no-duplicate"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergeIconStackedTopProvider = .codex
        store.mergeIconStackedBottomProvider = .codex
        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude])

        #expect(resolved?.top == .codex)
        #expect(resolved?.bottom == .claude)
    }
}
