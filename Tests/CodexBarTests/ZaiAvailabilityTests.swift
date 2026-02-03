import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct ZaiAvailabilityTests {
    @Test
    func enablesZaiWhenTokenExistsInStore() throws {
        let suite = "ZaiAvailabilityTests-token"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let tokenStore = StubZaiTokenStore(token: "zai-test-token")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: tokenStore)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let metadata = try #require(ProviderRegistry.shared.metadata[.zai])
        settings.setProviderEnabled(provider: .zai, metadata: metadata, enabled: true)

        #expect(store.isEnabled(.zai) == true)
        #expect(settings.zaiAPIToken == "zai-test-token")
    }
}

private struct StubZaiTokenStore: ZaiTokenStoring {
    let token: String?

    func loadToken() throws -> String? {
        self.token
    }

    func storeToken(_: String?) throws {}
}
