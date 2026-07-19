import CodexBarCore
import Testing

struct ProviderConfigEnvironmentTests {
    @Test
    func `applies API key override for amp`() {
        let config = ProviderConfig(id: .amp, apiKey: "sgamp-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .amp,
            config: config)

        #expect(env[AmpSettingsReader.apiTokenKey] == "sgamp-config")
        #expect(ProviderTokenResolver.ampToken(environment: env) == "sgamp-config")
    }

    @Test
    func `applies API key override for zai`() {
        let config = ProviderConfig(id: .zai, apiKey: "z-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .zai,
            config: config)

        #expect(env[ZaiSettingsReader.apiTokenKey] == "z-token")
        #expect(env[ZaiSettingsReader.bigModelOrganizationKey] == nil)
        #expect(env[ZaiSettingsReader.bigModelProjectKey] == nil)
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
    func `preserves doubao ark API key when environment secret key is present`() {
        let config = ProviderConfig(id: .doubao, apiKey: "ark-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "sk-env",
            ],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.apiKeyEnvironmentKeys[0]] == "ark-config")
        #expect(env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] == nil)
        #expect(env[DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]] == nil)
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env) == nil)
        #expect(ProviderTokenResolver.doubaoToken(environment: env) == "ark-config")
    }

    @Test
    func `preserves doubao ark API key when config secret key is present`() {
        let config = ProviderConfig(
            id: .doubao,
            apiKey: "ark-config",
            secretKey: "sk-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.apiKeyEnvironmentKeys[0]] == "ark-config")
        #expect(env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] == nil)
        #expect(env[DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]] == nil)
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env) == nil)
        #expect(ProviderTokenResolver.doubaoToken(environment: env) == "ark-config")
    }

    @Test
    func `doubao ark API key config overrides environment coding plan credentials`() {
        let config = ProviderConfig(id: .doubao, apiKey: "ark-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]: "AKLT-env",
                DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "sk-env",
                DoubaoSettingsReader.regionEnvironmentKeys[0]: "cn-shanghai",
            ],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.apiKeyEnvironmentKeys[0]] == "ark-config")
        #expect(env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] == nil)
        #expect(env[DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]] == nil)
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env) == nil)
        #expect(ProviderTokenResolver.doubaoToken(environment: env) == "ark-config")
    }

    @Test
    func `reads doubao volcengine secret key alias`() {
        let env = [
            DoubaoSettingsReader.accessKeyIDEnvironmentKeys[1]: "AKLT-env",
            "VOLCENGINE_SECRET_KEY": "sk-env",
        ]

        #expect(DoubaoSettingsReader.secretAccessKeyEnvironmentKeys.contains("VOLCENGINE_SECRET_KEY"))
        #expect(DoubaoSettingsReader.secretAccessKey(environment: env) == "sk-env")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.accessKeyID == "AKLT-env")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.secretAccessKey == "sk-env")
    }

    @Test
    func `reads doubao volc sdk credential aliases`() {
        let env = [
            "VOLC_ACCESSKEY": "AKLT-volc",
            "VOLC_SECRETKEY": "sk-volc",
            "VOLC_REGION": "cn-shanghai",
        ]

        #expect(DoubaoSettingsReader.accessKeyIDEnvironmentKeys.contains("VOLC_ACCESSKEY"))
        #expect(DoubaoSettingsReader.secretAccessKeyEnvironmentKeys.contains("VOLC_SECRETKEY"))
        #expect(DoubaoSettingsReader.regionEnvironmentKeys.contains("VOLC_REGION"))
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.accessKeyID == "AKLT-volc")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.secretAccessKey == "sk-volc")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.region == "cn-shanghai")
    }

    @Test
    func `does not project incomplete doubao access key as ark API key`() {
        let config = ProviderConfig(id: .doubao, apiKey: "AKLT-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] == nil)
        #expect(env[DoubaoSettingsReader.apiKeyEnvironmentKeys[0]] == nil)
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env) == nil)
        #expect(ProviderTokenResolver.doubaoToken(environment: env) == nil)
    }

    @Test
    func `keeps base doubao ark API key when config access key lacks secret`() {
        let config = ProviderConfig(id: .doubao, apiKey: "AKLT-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                DoubaoSettingsReader.apiKeyEnvironmentKeys[0]: "ark-env",
            ],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] == nil)
        #expect(env[DoubaoSettingsReader.apiKeyEnvironmentKeys[0]] == "ark-env")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env) == nil)
        #expect(ProviderTokenResolver.doubaoToken(environment: env) == "ark-env")
    }

    @Test
    func `applies volcengine access key override for doubao coding plan`() {
        let config = ProviderConfig(
            id: .doubao,
            apiKey: "AKLT-config",
            secretKey: "sk-config",
            region: "cn-shanghai")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] == "AKLT-config")
        #expect(env[DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]] == "sk-config")
        #expect(env[DoubaoSettingsReader.regionEnvironmentKeys[0]] == "cn-shanghai")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.accessKeyID == "AKLT-config")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.secretAccessKey == "sk-config")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.region == "cn-shanghai")
    }

    @Test
    func `merges doubao config access key with environment secret key`() {
        let config = ProviderConfig(
            id: .doubao,
            apiKey: "AKLT-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]: "sk-env",
                DoubaoSettingsReader.regionEnvironmentKeys[2]: "cn-shanghai",
            ],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] == "AKLT-config")
        #expect(env[DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]] == "sk-env")
        #expect(env[DoubaoSettingsReader.regionEnvironmentKeys[0]] == "cn-shanghai")
        #expect(env[DoubaoSettingsReader.apiKeyEnvironmentKeys[0]] == nil)
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.accessKeyID == "AKLT-config")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.secretAccessKey == "sk-env")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.region == "cn-shanghai")
    }

    @Test
    func `merges doubao environment access key with config secret key`() {
        let config = ProviderConfig(
            id: .doubao,
            secretKey: "sk-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]: "AKLT-env",
                DoubaoSettingsReader.regionEnvironmentKeys[1]: "cn-beijing",
            ],
            provider: .doubao,
            config: config)

        #expect(env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] == "AKLT-env")
        #expect(env[DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]] == "sk-config")
        #expect(env[DoubaoSettingsReader.regionEnvironmentKeys[0]] == "cn-beijing")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.accessKeyID == "AKLT-env")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.secretAccessKey == "sk-config")
        #expect(DoubaoSettingsReader.codingPlanCredentials(environment: env)?.region == "cn-beijing")
    }

    @Test
    func `applies cookie header override for sakana`() {
        let config = ProviderConfig(id: .sakana, cookieHeader: "Cookie: session=abc")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .sakana,
            config: config)

        #expect(env[SakanaSettingsReader.cookieHeaderKey] == "Cookie: session=abc")
        #expect(SakanaSettingsReader.cookieHeader(environment: env) == "session=abc")
    }

    @Test
    func `applies cookie header override for longcat`() {
        let config = ProviderConfig(
            id: .longcat,
            cookieHeader: "Cookie: passport_token=abc; uid=42",
            cookieSource: .manual)
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .longcat,
            config: config)

        #expect(env[LongCatSettingsReader.cookieHeaderKey] == "Cookie: passport_token=abc; uid=42")
        #expect(LongCatSettingsReader.cookieHeader(environment: env) == "Cookie: passport_token=abc; uid=42")
    }

    @Test
    func `does not expose stored longcat cookie outside manual mode`() {
        for source in [ProviderCookieSource.auto, .off] {
            let config = ProviderConfig(id: .longcat, cookieHeader: "stale=1", cookieSource: source)
            let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
                base: [:],
                provider: .longcat,
                config: config)

            #expect(env[LongCatSettingsReader.cookieHeaderKey] == nil)
        }
    }

    @Test
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
    func `applies Kimi API key and base URL config overrides`() throws {
        let config = ProviderConfig(
            id: .kimi,
            apiKey: "kimi-api-token",
            enterpriseHost: "https://proxy.example.com/kimi")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .kimi,
            config: config)

        #expect(env["KIMI_CODE_API_KEY"] == "kimi-api-token")
        #expect(env["KIMI_API_KEY"] == nil)
        #expect(env[KimiSettingsReader.codeAPIBaseURLEnvironmentKey] == "https://proxy.example.com/kimi")
        #expect(ProviderTokenResolver.kimiAPIToken(environment: env) == "kimi-api-token")
        #expect(try KimiSettingsReader.codeAPIBaseURL(environment: env).absoluteString ==
            "https://proxy.example.com/kimi")
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
    func `applies API key override for NeuralWatt`() {
        let config = ProviderConfig(id: .neuralwatt, apiKey: "sk-neuralwatt-config")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .neuralwatt,
            config: config)

        #expect(env[NeuralWattSettingsReader.apiKeyEnvironmentKey] == "sk-neuralwatt-config")
        #expect(ProviderTokenResolver.neuralWattToken(environment: env) == "sk-neuralwatt-config")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .neuralwatt))
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
    func `applies LiteLLM config overrides`() {
        let config = ProviderConfig(
            id: .litellm,
            apiKey: "litellm-token",
            enterpriseHost: "https://litellm.example.com/v1")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .litellm,
            config: config)

        #expect(env[LiteLLMSettingsReader.apiKeyEnvironmentKey] == "litellm-token")
        #expect(env[LiteLLMSettingsReader.baseURLEnvironmentKey] == "https://litellm.example.com/v1")
        #expect(ProviderTokenResolver.liteLLMToken(environment: env) == "litellm-token")
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
    func `bedrock merged static credentials win over inherited AWS_PROFILE`() {
        let config = ProviderConfig(
            id: .bedrock,
            secretKey: "config-secret",
            region: "eu-central-1")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                BedrockSettingsReader.profileKey: "work",
                BedrockSettingsReader.accessKeyIDKey: "env-access",
            ],
            provider: .bedrock,
            config: config)

        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "env-access")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == "config-secret")
        #expect(env[BedrockSettingsReader.regionKeys[0]] == "eu-central-1")
        #expect(BedrockSettingsReader.authMode(environment: env) == .keys)
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
    func `bedrock env profile mode does not project saved static credentials`() {
        let config = ProviderConfig(
            id: .bedrock,
            apiKey: "AKIASAVED",
            secretKey: "saved-secret")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                BedrockSettingsReader.authModeKey: "profile",
                BedrockSettingsReader.profileKey: "work",
            ],
            provider: .bedrock,
            config: config)

        #expect(env[BedrockSettingsReader.authModeKey] == "profile")
        #expect(env[BedrockSettingsReader.profileKey] == "work")
        #expect(env[BedrockSettingsReader.accessKeyIDKey] == nil)
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == nil)
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
    func `projects the legacy DeepSeek Platform token and stable profile identifier`() {
        let config = ProviderConfig(
            id: .deepseek,
            apiKey: "legacy-api-key",
            cookieHeader: "browser-platform-token",
            deepseekProfileID: "/profiles/Profile 2",
            deepseekProfileScope: "account-id")
        let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .deepseek,
            config: config)

        #expect(env[DeepSeekSettingsReader.apiKeyEnvironmentKey] == nil)
        #expect(env[DeepSeekSettingsReader.platformTokenEnvironmentKey] == "browser-platform-token")
        #expect(env[DeepSeekSettingsReader.profileIDEnvironmentKey] == "chrome:Profile 2")
        #expect(env[DeepSeekSettingsReader.profileScopeEnvironmentKey] == "account-id")
    }

    @Test
    func `normalization preserves a legacy DeepSeek browser token and canonicalizes the profile path`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .deepseek,
                cookieHeader: "browser-platform-token",
                deepseekProfileID: "/profiles/Profile 2",
                deepseekProfileScope: " account-id "),
        ]).normalized()
        let deepseek = try #require(config.providerConfig(for: .deepseek))

        #expect(deepseek.cookieHeader == "browser-platform-token")
        #expect(deepseek.deepseekProfileID == "chrome:Profile 2")
        #expect(deepseek.deepseekProfileScope == "account-id")
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
    func `applies API key override for factory`() {
        let config = ProviderConfig(id: .factory, apiKey: "fk-config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .factory,
            config: config)

        #expect(env[FactorySettingsReader.apiTokenKey] == "fk-config-token")
        #expect(FactorySettingsReader.apiKey(environment: env) == "fk-config-token")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .factory))
    }

    @Test
    func `factory config api key wins over existing FACTORY_API_KEY`() {
        let config = ProviderConfig(id: .factory, apiKey: "fk-config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [FactorySettingsReader.apiTokenKey: "fk-env-token"],
            provider: .factory,
            config: config)

        #expect(env[FactorySettingsReader.apiTokenKey] == "fk-config-token")
        #expect(FactorySettingsReader.apiKey(environment: env) == "fk-config-token")
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

    @Test
    func `applies API key override for poe`() {
        let config = ProviderConfig(id: .poe, apiKey: "poe-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .poe,
            config: config)

        #expect(env[PoeSettingsReader.apiKeyEnvironmentKey] == "poe-token")
        #expect(ProviderTokenResolver.poeToken(environment: env) == "poe-token")
    }

    @Test
    func `poe supports API key override`() {
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .poe) == true)
    }
}
