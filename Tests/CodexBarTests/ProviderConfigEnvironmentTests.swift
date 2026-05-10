import CodexBarCore
import Testing

struct ProviderConfigEnvironmentTests {
    @Test
    func `applies API key override for zai`() {
        let config = ProviderConfig(id: .zai, apiKey: "z-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .zai,
            config: config)

        #expect(env[ZaiSettingsReader.apiTokenKey] == "z-token")
    }

    @Test
    func `applies API key override for warp`() {
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
    func `applies API key override for open router`() {
        let config = ProviderConfig(id: .openrouter, apiKey: "or-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .openrouter,
            config: config)

        #expect(env[OpenRouterSettingsReader.envKey] == "or-token")
    }

    @Test
    func `applies API key override for doubao`() {
        let config = ProviderConfig(id: .doubao, apiKey: "db-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.apiKeyEnvironmentKeys[0]] == "db-token")
        #expect(ProviderTokenResolver.doubaoToken(environment: env) == "db-token")
    }

    @Test
    func `ignores legacy API key override for deepseek`() {
        let config = ProviderConfig(id: .deepseek, apiKey: "ds-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .deepseek,
            config: config)

        let key = DeepSeekSettingsReader.apiKeyEnvironmentKeys.first
        #expect(key != nil)
        guard let key else { return }

        #expect(env[key] == nil)
        #expect(ProviderTokenResolver.deepseekToken(environment: env) == nil)
    }

    @Test
    func `applies API key override for kilo`() {
        let config = ProviderConfig(id: .kilo, apiKey: "kilo-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .kilo,
            config: config)

        #expect(env[KiloSettingsReader.apiTokenKey] == "kilo-token")
        #expect(ProviderTokenResolver.kiloToken(environment: env, authFileURL: nil) == "kilo-token")
    }

    @Test
    func `open router config override wins over environment token`() {
        let config = ProviderConfig(id: .openrouter, apiKey: "config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [OpenRouterSettingsReader.envKey: "env-token"],
            provider: .openrouter,
            config: config)

        #expect(env[OpenRouterSettingsReader.envKey] == "config-token")
        #expect(ProviderTokenResolver.openRouterToken(environment: env) == "config-token")
    }

    @Test
    func `deepseek config override leaves environment token alone`() {
        let config = ProviderConfig(id: .deepseek, apiKey: "config-token")
        let envKey = DeepSeekSettingsReader.apiKeyEnvironmentKeys[0]
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [envKey: "env-token"],
            provider: .deepseek,
            config: config)

        #expect(env[envKey] == "env-token")
        #expect(ProviderTokenResolver.deepseekToken(environment: env) == "env-token")
    }

    @Test
    func `applies API key override for codebuff`() {
        let config = ProviderConfig(id: .codebuff, apiKey: "cb-config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .codebuff,
            config: config)

        #expect(env[CodebuffSettingsReader.apiTokenKey] == "cb-config-token")
        #expect(
            ProviderTokenResolver.codebuffToken(environment: env, authFileURL: nil)
                == "cb-config-token")
    }

    @Test
    func `codebuff config override leaves environment token alone`() {
        let config = ProviderConfig(id: .codebuff, apiKey: "config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [CodebuffSettingsReader.apiTokenKey: "env-token"],
            provider: .codebuff,
            config: config)

        #expect(env[CodebuffSettingsReader.apiTokenKey] == "env-token")
        #expect(
            ProviderTokenResolver.codebuffToken(environment: env, authFileURL: nil)
                == "env-token")
    }

    @Test
    func `leaves environment when API key missing`() {
        let config = ProviderConfig(id: .zai, apiKey: nil)
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [ZaiSettingsReader.apiTokenKey: "existing"],
            provider: .zai,
            config: config)

        #expect(env[ZaiSettingsReader.apiTokenKey] == "existing")
    }
}
