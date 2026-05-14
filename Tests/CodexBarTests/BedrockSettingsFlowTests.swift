import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct BedrockSettingsFlowTests {
    @Test
    func `settings store maps Bedrock credentials into provider environment`() throws {
        let suite = "BedrockSettingsFlowTests-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.bedrockAccessKeyID = "AKIATEST"
        settings.bedrockSecretAccessKey = "secret"
        settings.bedrockRegion = "us-west-2"

        let config = try #require(settings.providerConfig(for: .bedrock))
        #expect(config.sanitizedAPIKey == "AKIATEST")
        #expect(config.sanitizedSecretKey == "secret")
        #expect(config.sanitizedCookieHeader == nil)
        #expect(config.sanitizedRegion == "us-west-2")

        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .bedrock,
            settings: settings,
            tokenOverride: nil)

        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "AKIATEST")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == "secret")
        #expect(env[BedrockSettingsReader.regionKeys[0]] == "us-west-2")
        #expect(BedrockSettingsReader.hasCredentials(environment: env))
        #expect(BedrockProviderImplementation().isAvailable(context: ProviderAvailabilityContext(
            provider: .bedrock,
            settings: settings,
            environment: env)))
    }

    @Test
    func `bedrock availability requires secret access key`() throws {
        let suite = "BedrockSettingsFlowTests-missing-secret-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.bedrockAccessKeyID = "AKIATEST"

        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .bedrock,
            settings: settings,
            tokenOverride: nil)

        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "AKIATEST")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == nil)
        #expect(!BedrockProviderImplementation().isAvailable(context: ProviderAvailabilityContext(
            provider: .bedrock,
            settings: settings,
            environment: env)))
    }
}
