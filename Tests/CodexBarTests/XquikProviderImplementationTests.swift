import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct XquikProviderImplementationTests {
    @Test
    func `availability uses the Xquik environment key`() throws {
        let settings = try Self.makeSettings(suite: "XquikProviderImplementationTests-env")
        let implementation = XquikProviderImplementation()
        let context = ProviderAvailabilityContext(
            provider: .xquik,
            settings: settings,
            environment: [XquikSettingsReader.apiKeyEnvironmentKey: "xq_env"])

        #expect(implementation.isAvailable(context: context))
    }

    @Test
    func `availability uses the stored Xquik API key`() throws {
        let settings = try Self.makeSettings(suite: "XquikProviderImplementationTests-settings")
        settings[providerConfig: .xquik, field: .apiKey] = "xq_stored"
        let implementation = XquikProviderImplementation()

        #expect(implementation.isAvailable(context: .init(provider: .xquik, settings: settings, environment: [:])))
    }

    @Test
    func `availability rejects a missing Xquik API key`() throws {
        let settings = try Self.makeSettings(suite: "XquikProviderImplementationTests-missing")
        settings[providerConfig: .xquik, field: .apiKey] = "   "
        let implementation = XquikProviderImplementation()

        #expect(!implementation.isAvailable(context: .init(provider: .xquik, settings: settings, environment: [:])))
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
