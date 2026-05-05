import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ZaiAvailabilityTests {
    @Test
    func `enables zai when token exists in store`() throws {
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

    @Test
    func `enables zai when token exists in token accounts`() throws {
        let suite = "ZaiAvailabilityTests-token-accounts"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        settings.addTokenAccount(provider: .zai, label: "primary", token: "zai-token-account")

        let metadata = try #require(ProviderRegistry.shared.metadata[.zai])
        settings.setProviderEnabled(provider: .zai, metadata: metadata, enabled: true)

        #expect(store.isEnabled(.zai) == true)
    }
}

private struct StubZaiTokenStore: ZaiTokenStoring {
    let token: String?

    func loadToken() throws -> String? {
        self.token
    }

    func storeToken(_: String?) throws {}
}
