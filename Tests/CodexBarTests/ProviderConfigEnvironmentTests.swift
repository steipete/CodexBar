import CodexBarCore
import Testing

@Suite
struct ProviderConfigEnvironmentTests {
    @Test
    func appliesAPIKeyOverrideForZai() {
        let config = ProviderConfig(id: .zai, apiKey: "z-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .zai,
            config: config)

        #expect(env[ZaiSettingsReader.apiTokenKey] == "z-token")
    }

    @Test
    func appliesAPIKeyOverrideForWarp() {
        let config = ProviderConfig(id: .warp, apiKey: "w-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .warp,
            config: config)

        let key = WarpSettingsReader.apiKeyEnvironmentKeys.first
        #expect(key != nil)
        guard let key else { return }

        #expect(env[key] == "w-token")
    }

    @Test
    func appliesAPIKeyOverrideForOpenRouter() {
        let config = ProviderConfig(id: .openrouter, apiKey: "or-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .openrouter,
            config: config)

        #expect(env[OpenRouterSettingsReader.envKey] == "or-token")
    }

    @Test
    func openRouterConfigOverrideWinsOverEnvironmentToken() {
        let config = ProviderConfig(id: .openrouter, apiKey: "config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [OpenRouterSettingsReader.envKey: "env-token"],
            provider: .openrouter,
            config: config)

        #expect(env[OpenRouterSettingsReader.envKey] == "config-token")
        #expect(ProviderTokenResolver.openRouterToken(environment: env) == "config-token")
    }

    @Test
    func leavesEnvironmentWhenAPIKeyMissing() {
        let config = ProviderConfig(id: .zai, apiKey: nil)
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [ZaiSettingsReader.apiTokenKey: "existing"],
            provider: .zai,
            config: config)

        #expect(env[ZaiSettingsReader.apiTokenKey] == "existing")
    }
}
