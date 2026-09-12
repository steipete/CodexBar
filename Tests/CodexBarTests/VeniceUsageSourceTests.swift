import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct VeniceUsageSourceTests {
    @Test
    func `defaults venice usage source to auto and persists web`() throws {
        let suite = "VeniceUsageSourceTests-source"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.veniceUsageDataSource == .auto)
        store.veniceUsageDataSource = .web
        #expect(store.veniceUsageDataSource == .web)
        store.veniceUsageDataSource = .api
        #expect(store.veniceUsageDataSource == .api)
    }
}
