import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CrofProviderImplementationTests {
    @Test
    func `availability uses crof environment token`() throws {
        let settings = try Self.makeSettings(suite: "CrofProviderImplementationTests-env")
        let implementation = CrofProviderImplementation()

        let context = ProviderAvailabilityContext(
            provider: .crof,
            settings: settings,
            environment: [CrofSettingsReader.apiKeyEnvironmentKeys[0]: "env-token"])

        #expect(implementation.isAvailable(context: context))
    }

    @Test
    func `availability uses stored crof API token`() throws {
        let settings = try Self.makeSettings(suite: "CrofProviderImplementationTests-settings")
        settings[providerConfig: .crof, field: .apiKey] = "stored-token"
        let implementation = CrofProviderImplementation()

        let context = ProviderAvailabilityContext(provider: .crof, settings: settings, environment: [:])

        #expect(implementation.isAvailable(context: context))
    }

    @Test
    func `availability rejects missing crof API token`() throws {
        let settings = try Self.makeSettings(suite: "CrofProviderImplementationTests-missing")
        settings[providerConfig: .crof, field: .apiKey] = "   "
        let implementation = CrofProviderImplementation()

        let context = ProviderAvailabilityContext(provider: .crof, settings: settings, environment: [:])

        #expect(!implementation.isAvailable(context: context))
    }

    private static func makeSettings(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
