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

    func `applies API key override for moonshot`() {
        let config = ProviderConfig(id: .moonshot, apiKey: "moon-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .moonshot,
            config: config)

        let key = MoonshotSettingsReader.apiKeyEnvironmentKeys.first
        #expect(key != nil)
        guard let key else { return }

        #expect(env[key] == "moon-token")
    }

    @Test
    func `applies API key override for elevenlabs`() {
        let config = ProviderConfig(id: .elevenlabs, apiKey: "xi-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .elevenlabs,
            config: config)

        #expect(env[ElevenLabsSettingsReader.apiKeyEnvironmentKey] == "xi-token")
        #expect(ProviderTokenResolver.elevenLabsToken(environment: env) == "xi-token")
    }

    @Test
    func `applies API key override for groq`() {
        let config = ProviderConfig(id: .groq, apiKey: "gsk-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .groq,
            config: config)

        #expect(env[GroqSettingsReader.apiKeyEnvironmentKey] == "gsk-token")
        #expect(ProviderTokenResolver.groqToken(environment: env) == "gsk-token")
    }

    @Test
    func `applies LLM Proxy config overrides`() {
        let config = ProviderConfig(
            id: .llmproxy,
            apiKey: "proxy-token",
            enterpriseHost: "https://proxy.example.com")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .llmproxy,
            config: config)

        #expect(env[LLMProxySettingsReader.apiKeyEnvironmentKey] == "proxy-token")
        #expect(env[LLMProxySettingsReader.baseURLEnvironmentKey] == "https://proxy.example.com")
        #expect(ProviderTokenResolver.llmProxyToken(environment: env) == "proxy-token")
    }

    @Test
    func `openai config override uses preferred admin key environment`() {
        let config = ProviderConfig(id: .openai, apiKey: "config-openai-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey: "env-admin-token",
                OpenAIAPISettingsReader.apiKeyEnvironmentKey: "env-api-token",
            ],
            provider: .openai,
            config: config)

        #expect(env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] == "config-openai-token")
        #expect(env[OpenAIAPISettingsReader.apiKeyEnvironmentKey] == "env-api-token")
        #expect(ProviderTokenResolver.openAIAPIToken(environment: env) == "config-openai-token")
    }

    @Test
    func `openai config override applies project ID without replacing environment key`() {
        let config = ProviderConfig(id: .openai, workspaceID: "proj_config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey: "env-admin-token",
            ],
            provider: .openai,
            config: config)

        #expect(env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] == "env-admin-token")
        #expect(env[OpenAIAPISettingsReader.projectIDEnvironmentKey] == "proj_config")
        #expect(OpenAIAPISettingsReader.projectID(environment: env) == "proj_config")
    }

    @Test
    func `applies Azure OpenAI config overrides`() {
        let config = ProviderConfig(
            id: .azureopenai,
            apiKey: "config-azure-token",
            workspaceID: "chat-prod",
            enterpriseHost: "https://example-resource.openai.azure.com")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [
                AzureOpenAISettingsReader.apiKeyEnvironmentKey: "env-azure-token",
                AzureOpenAISettingsReader.endpointEnvironmentKey: "https://env-resource.openai.azure.com",
                AzureOpenAISettingsReader.deploymentNameEnvironmentKey: "env-deployment",
            ],
            provider: .azureopenai,
            config: config)

        #expect(env[AzureOpenAISettingsReader.apiKeyEnvironmentKey] == "config-azure-token")
        #expect(env[AzureOpenAISettingsReader.endpointEnvironmentKey] == "https://example-resource.openai.azure.com")
        #expect(env[AzureOpenAISettingsReader.deploymentNameEnvironmentKey] == "chat-prod")
        #expect(ProviderTokenResolver.azureOpenAIToken(environment: env) == "config-azure-token")
        #expect(AzureOpenAISettingsReader.deploymentName(environment: env) == "chat-prod")
    }

    @Test
    func `bedrock config maps AWS credential fields`() {
        let config = ProviderConfig(
            id: .bedrock,
            apiKey: "AKIATEST",
            secretKey: "secret",
            cookieHeader: "legacy-cookie-secret",
            region: "us-west-2")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .bedrock,
            config: config)

        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "AKIATEST")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == "secret")
        #expect(env[BedrockSettingsReader.regionKeys[0]] == "us-west-2")
        #expect(!env.values.contains("legacy-cookie-secret"))
    }

    @Test
    func `bedrock config merges secret and region without replacing environment access key`() {
        let config = ProviderConfig(
            id: .bedrock,
            apiKey: nil,
            secretKey: "config-secret",
            region: "eu-central-1")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [BedrockSettingsReader.accessKeyIDKey: "env-access"],
            provider: .bedrock,
            config: config)

        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "env-access")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == "config-secret")
        #expect(env[BedrockSettingsReader.regionKeys[0]] == "eu-central-1")
        #expect(BedrockSettingsReader.hasCredentials(environment: env))
    }

    @Test
    func `bedrock profile mode projects AWS_PROFILE without saved static keys`() {
        let config = ProviderConfig(
            id: .bedrock,
            apiKey: "AKIATEST",
            secretKey: "secret",
            region: "eu-west-1",
            awsProfile: "work",
            awsAuthMode: "profile")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .bedrock,
            config: config)
        #expect(env[BedrockSettingsReader.authModeKey] == "profile")
        #expect(env[BedrockSettingsReader.profileKey] == "work")
        #expect(env[BedrockSettingsReader.regionKeys[0]] == "eu-west-1")
        #expect(env[BedrockSettingsReader.accessKeyIDKey] == nil)
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == nil)
    }

    @Test
    func `bedrock config without explicit mode preserves env profile inference`() {
        let config = ProviderConfig(id: .bedrock, region: "us-east-1")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [BedrockSettingsReader.profileKey: "work"],
            provider: .bedrock,
            config: config)
        #expect(env[BedrockSettingsReader.authModeKey] == nil)
        #expect(env[BedrockSettingsReader.profileKey] == "work")
        #expect(BedrockSettingsReader.authMode(environment: env) == .profile)
    }

    @Test
    func `bedrock saved static keys survive base AWS_PROFILE when auth mode is unset`() {
        let config = ProviderConfig(
            id: .bedrock,
            apiKey: "AKIASAVED",
            secretKey: "saved-secret",
            region: "us-east-1")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [BedrockSettingsReader.profileKey: "work"],
            provider: .bedrock,
            config: config)
        // Upgrade path: saved keys win over an inherited AWS_PROFILE, no silent switch.
        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "AKIASAVED")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == "saved-secret")
        #expect(BedrockSettingsReader.authMode(environment: env) == .keys)
    }

    @Test
    func `bedrock profile mode preserves inherited static credentials for environment source profiles`() {
        let config = ProviderConfig(id: .bedrock, awsProfile: "work", awsAuthMode: "profile")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                BedrockSettingsReader.accessKeyIDKey: "AKIAINHERITED",
                BedrockSettingsReader.secretAccessKeyKey: "inherited-secret",
                BedrockSettingsReader.sessionTokenKey: "inherited-token",
            ],
            provider: .bedrock,
            config: config)
        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "AKIAINHERITED")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == "inherited-secret")
        #expect(env[BedrockSettingsReader.sessionTokenKey] == "inherited-token")
        #expect(env[BedrockSettingsReader.profileKey] == "work")
    }

    @Test
    func `bedrock keys mode still projects static credentials`() {
        let config = ProviderConfig(
            id: .bedrock,
            apiKey: "AKIATEST",
            secretKey: "secret",
            region: "us-west-2",
            awsAuthMode: "keys")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .bedrock,
            config: config)
        #expect(env[BedrockSettingsReader.authModeKey] == "keys")
        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "AKIATEST")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == "secret")
        #expect(env[BedrockSettingsReader.profileKey] == nil)
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
    func `applies API key override for deepgram`() {
        let config = ProviderConfig(id: .deepgram, apiKey: "dg-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .deepgram,
            config: config)

        #expect(env[DeepgramSettingsReader.apiKeyEnvironmentKey] == "dg-token")
        #expect(ProviderTokenResolver.deepgramResolution(
            type: .apiKey,
            environment: env)
            == "dg-token")
    }

    @Test
    func `applies Deepgram project ID override from provider config`() {
        let config = ProviderConfig(id: .deepgram, workspaceID: "proj-123")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .deepgram,
            config: config)

        #expect(env[DeepgramSettingsReader.projectIDEnvironmentKey] == "proj-123")
    }

    @Test
    func `Deepgram project ID config overrides environment`() {
        let config = ProviderConfig(id: .deepgram, workspaceID: "config-project")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [DeepgramSettingsReader.projectIDEnvironmentKey: "env-project"],
            provider: .deepgram,
            config: config)

        #expect(env[DeepgramSettingsReader.projectIDEnvironmentKey] == "config-project")
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
