import Foundation

public enum ProviderConfigEnvironment {
    public static func applyAPIKeyOverride(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        if provider == .openai {
            return self.applyOpenAIOverrides(base: base, config: config)
        }
        if provider == .bedrock {
            return self.applyBedrockOverrides(base: base, config: config)
        }
        if provider == .deepgram {
            return self.applyDeepgramOverrides(base: base, config: config)
        }
        if provider == .llmproxy {
            return self.applyLLMProxyOverrides(base: base, config: config)
        }
        if provider == .azureopenai {
            return self.applyAzureOpenAIOverrides(base: base, config: config)
        }
        guard let apiKey = config?.sanitizedAPIKey, !apiKey.isEmpty else { return base }
        var env = base
        if let key = self.directAPIKeyEnvironmentKey(for: provider) {
            env[key] = apiKey
            return env
        }

        switch provider {
        case .copilot:
            env["COPILOT_API_TOKEN"] = apiKey
        case .kimik2:
            if let key = KimiK2SettingsReader.apiKeyEnvironmentKeys.first {
                env[key] = apiKey
            }
        case .warp:
            if let key = WarpSettingsReader.apiKeyEnvironmentKeys.first {
                env[key] = apiKey
            }
        case .codebuff:
            // Preserve a token already present in the process environment so that
            // runtime/CI overrides win over a key saved in Settings (matches the
            // precedence used by `ProviderTokenResolver.codebuffResolution`).
            if CodebuffSettingsReader.apiKey(environment: base) == nil {
                env[CodebuffSettingsReader.apiTokenKey] = apiKey
            }
        case .crof:
            if CrofSettingsReader.apiKey(environment: base) == nil,
               let key = CrofSettingsReader.apiKeyEnvironmentKeys.first
            {
                env[key] = apiKey
            }
        case .doubao:
            if let key = DoubaoSettingsReader.apiKeyEnvironmentKeys.first {
                env[key] = apiKey
            }
        default:
            break
        }
        return env
    }

    public static func supportsAPIKeyOverride(for provider: UsageProvider) -> Bool {
        if self.directAPIKeyEnvironmentKey(for: provider) != nil { return true }
        switch provider {
        case .copilot, .kimik2, .warp, .codebuff, .crof, .doubao:
            return true
        case .azureopenai:
            return true
        default:
            return false
        }
    }

    private static func directAPIKeyEnvironmentKey(for provider: UsageProvider) -> String? {
        switch provider {
        case .openai:
            OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey
        case .azureopenai:
            AzureOpenAISettingsReader.apiKeyEnvironmentKey
        case .claude:
            ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey
        case .zai:
            ZaiSettingsReader.apiTokenKey
        case .minimax:
            MiniMaxAPISettingsReader.apiTokenKey
        case .alibaba:
            AlibabaCodingPlanSettingsReader.apiTokenKey
        case .kilo:
            KiloSettingsReader.apiTokenKey
        case .synthetic:
            SyntheticSettingsReader.apiKeyKey
        case .openrouter:
            OpenRouterSettingsReader.envKey
        case .elevenlabs:
            ElevenLabsSettingsReader.apiKeyEnvironmentKey
        case .moonshot:
            MoonshotSettingsReader.apiKeyEnvironmentKeys.first
        case .ollama:
            OllamaAPISettingsReader.apiKeyEnvironmentKeys.first
        case .venice:
            VeniceSettingsReader.apiKeyEnvironmentKey
        case .deepgram:
            DeepgramSettingsReader.apiKeyEnvironmentKey
        case .groq:
            GroqSettingsReader.apiKeyEnvironmentKey
        case .llmproxy:
            LLMProxySettingsReader.apiKeyEnvironmentKey
        default:
            nil
        }
    }

    private static func applyOpenAIOverrides(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        guard let config else { return base }
        var env = base
        if let apiKey = config.sanitizedAPIKey {
            env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] = apiKey
        }
        if let projectID = config.sanitizedWorkspaceID {
            env[OpenAIAPISettingsReader.projectIDEnvironmentKey] = projectID
        }
        return env
    }

    private static func applyBedrockOverrides(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        guard let config else { return base }
        var env = base

        // Only project an explicit auth-mode selection. When the config does not
        // specify one, leave the base environment untouched so an env-driven setup
        // (AWS_PROFILE or CODEXBAR_BEDROCK_AUTH_MODE from the launch environment) is
        // still inferred by BedrockSettingsReader instead of being forced to `keys`.
        let explicitMode = config.sanitizedAWSAuthMode.flatMap(BedrockAuthMode.init(rawValue:))
        if let explicitMode {
            env[BedrockSettingsReader.authModeKey] = explicitMode.rawValue
        }

        let hasSavedStaticKeys = config.sanitizedAPIKey != nil && config.sanitizedSecretKey != nil
        let effectiveMode: BedrockAuthMode = if let explicitMode {
            explicitMode
        } else if hasSavedStaticKeys {
            // Upgrade path: a config saved before auth modes existed keeps using its
            // static keys even if AWS_PROFILE is present in the base environment, so
            // existing users are never silently switched to a profile/account.
            .keys
        } else {
            BedrockSettingsReader.authMode(environment: base)
        }

        switch effectiveMode {
        case .profile:
            if let profile = config.sanitizedAWSProfile {
                env[BedrockSettingsReader.profileKey] = profile
            }
            // Static credential env vars take precedence over a profile in the AWS
            // CLI, so drop any inherited ones to ensure the chosen profile is used
            // for both Cost Explorer signing and `aws configure export-credentials`.
            env[BedrockSettingsReader.accessKeyIDKey] = nil
            env[BedrockSettingsReader.secretAccessKeyKey] = nil
            env[BedrockSettingsReader.sessionTokenKey] = nil
        case .keys:
            if let accessKeyID = config.sanitizedAPIKey {
                env[BedrockSettingsReader.accessKeyIDKey] = accessKeyID
            }
            if let secretAccessKey = config.sanitizedSecretKey {
                env[BedrockSettingsReader.secretAccessKeyKey] = secretAccessKey
            }
        }

        if let region = config.sanitizedRegion {
            env[BedrockSettingsReader.regionKeys[0]] = region
        }

        return env
    }

    private static func applyDeepgramOverrides(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        guard let config else { return base }

        var env = base

        if let apiKey = config.sanitizedAPIKey {
            env[DeepgramSettingsReader.apiKeyEnvironmentKey] = apiKey
        }

        if let projectID = config.sanitizedWorkspaceID {
            env[DeepgramSettingsReader.projectIDEnvironmentKey] = projectID
        }

        return env
    }

    private static func applyLLMProxyOverrides(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        var env = base
        if let apiKey = config?.sanitizedAPIKey {
            env[LLMProxySettingsReader.apiKeyEnvironmentKey] = apiKey
        }
        if let baseURL = config?.sanitizedEnterpriseHost {
            env[LLMProxySettingsReader.baseURLEnvironmentKey] = baseURL
        }
        return env
    }

    private static func applyAzureOpenAIOverrides(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        guard let config else { return base }
        var env = base
        if let apiKey = config.sanitizedAPIKey {
            env[AzureOpenAISettingsReader.apiKeyEnvironmentKey] = apiKey
        }
        if let endpoint = config.sanitizedEnterpriseHost {
            env[AzureOpenAISettingsReader.endpointEnvironmentKey] = endpoint
        }
        if let deploymentName = config.sanitizedWorkspaceID {
            env[AzureOpenAISettingsReader.deploymentNameEnvironmentKey] = deploymentName
        }
        return env
    }

    public static func applyProviderConfigOverrides(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        self.applyAPIKeyOverride(base: base, provider: provider, config: config)
    }
}
