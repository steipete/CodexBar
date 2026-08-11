import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct MergedOverviewProviderLimitTests {
    @Test
    func `resolved providers cap stale selection fallback`() throws {
        let suite = "MergedOverviewProviderLimitTests-stale-selection-cap"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergedOverviewSelectedProviders = [.grok]
        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor]
        let resolved = store.resolvedMergedOverviewProviders(
            activeProviders: activeProviders,
            maxVisibleProviders: 2)

        #expect(resolved == [.codex, .claude])
        #expect(resolved.count <= 2)
    }
}
