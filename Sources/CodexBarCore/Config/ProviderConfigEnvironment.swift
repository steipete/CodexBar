import Foundation

public enum ProviderConfigEnvironment {
    public static func applyAPIKeyOverride(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        if let env = self.applyDedicatedProviderOverrides(base: base, provider: provider, config: config) {
            return env
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

    private static func baseURLEnvironmentKey(for provider: UsageProvider) -> String? {
        switch provider {
        case .llmproxy:
            LLMProxySettingsReader.baseURLEnvironmentKey
        case .litellm:
            LiteLLMSettingsReader.baseURLEnvironmentKey
        case .clawrouter:
            ClawRouterSettingsReader.baseURLEnvironmentKey
        case .sub2api:
            Sub2APISettingsReader.baseURLEnvironmentKey
        case .wayfinder:
            WayfinderSettingsReader.baseURLEnvironmentKey
        default:
            nil
        }
    }

    private static func supportsAPIKeyAndBaseURLOverride(_ provider: UsageProvider) -> Bool {
        self.baseURLEnvironmentKey(for: provider) != nil
    }

    private static func applyDedicatedProviderOverrides(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]?
    {
        if self.supportsAPIKeyAndBaseURLOverride(provider) {
            return self.applyAPIKeyAndBaseURLOverrides(base: base, provider: provider, config: config)
        }
        if let env = self.applyMultiFieldCredentialOverrides(base: base, provider: provider, config: config) {
            return env
        }
        return switch provider {
        case .deepgram:
            self.applyDeepgramOverrides(base: base, config: config)
        case .azureopenai:
            self.applyAzureOpenAIOverrides(base: base, config: config)
        case .kimi:
            self.applyKimiOverrides(base: base, config: config)
        case .doubao:
            self.applyDoubaoOverrides(base: base, config: config)
        case .sakana:
            self.applySakanaOverrides(base: base, config: config)
        default:
            nil
        }
    }

    private static func applyMultiFieldCredentialOverrides(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]?
    {
        switch provider {
        case .openai:
            self.applyOpenAIOverrides(base: base, config: config)
        case .bedrock:
            self.applyBedrockOverrides(base: base, config: config)
        default:
            nil
        }
    }

    private static func directAPIKeyEnvironmentKey(for provider: UsageProvider) -> String? {
        switch provider {
        case .amp:
            AmpSettingsReader.apiTokenKey
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
        case .kimi:
            KimiSettingsReader.apiKeyEnvironmentKeys.first
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
        case .chutes, .poe, .litellm, .crossmodel, .clawrouter, .factory, .sub2api, .zenmux:
            self.additionalAPIKeyEnvironmentKey(for: provider)
        default:
            nil
        }
    }

    private static func additionalAPIKeyEnvironmentKey(for provider: UsageProvider) -> String? {
        switch provider {
        case .chutes:
            ChutesSettingsReader.apiKeyEnvironmentKey
        case .poe:
            PoeSettingsReader.apiKeyEnvironmentKey
        case .litellm:
            LiteLLMSettingsReader.apiKeyEnvironmentKey
        case .crossmodel:
            CrossModelSettingsReader.envKey
        case .clawrouter:
            ClawRouterSettingsReader.apiKeyEnvironmentKey
        case .sub2api:
            Sub2APISettingsReader.apiKeyEnvironmentKey
        case .factory:
            FactorySettingsReader.apiTokenKey
        case .zenmux:
            ZenMuxSettingsReader.managementAPIKeyEnvironmentKey
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
        let configMode = config.sanitizedAWSAuthMode.flatMap(BedrockAuthMode.init(rawValue:))
        if let configMode {
            env[BedrockSettingsReader.authModeKey] = configMode.rawValue
        }
        let baseMode = BedrockSettingsReader
            .cleaned(base[BedrockSettingsReader.authModeKey])
            .flatMap { BedrockAuthMode(rawValue: $0.lowercased()) }

        let mergedAccessKey = config.sanitizedAPIKey ?? BedrockSettingsReader.accessKeyID(environment: base)
        let mergedSecretKey = config.sanitizedSecretKey ?? BedrockSettingsReader.secretAccessKey(environment: base)
        let hasMergedStaticKeys = mergedAccessKey != nil && mergedSecretKey != nil
        let effectiveMode: BedrockAuthMode = if let configMode {
            configMode
        } else if let baseMode {
            baseMode
        } else if hasMergedStaticKeys {
            // Upgrade path: a config saved before auth modes existed keeps using
            // static credentials (including env+config layering) even if AWS_PROFILE
            // is present in the base environment, so existing users are never
            // silently switched to a profile/account.
            .keys
        } else {
            BedrockSettingsReader.authMode(environment: base)
        }

        switch effectiveMode {
        case .profile:
            if let profile = config.sanitizedAWSProfile {
                env[BedrockSettingsReader.profileKey] = profile
            }
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

    private static func applyAPIKeyAndBaseURLOverrides(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        var env = base
        if let apiKey = config?.sanitizedAPIKey,
           let key = self.directAPIKeyEnvironmentKey(for: provider)
        {
            env[key] = apiKey
        }
        if let baseURL = config?.sanitizedEnterpriseHost,
           let key = self.baseURLEnvironmentKey(for: provider)
        {
            env[key] = baseURL
        }
        return env
    }

    private static func applyKimiOverrides(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        guard let config else { return base }
        var env = base
        if let apiKey = config.sanitizedAPIKey,
           let key = KimiSettingsReader.apiKeyEnvironmentKeys.first
        {
            env[key] = apiKey
        }
        if let baseURL = config.sanitizedEnterpriseHost {
            env[KimiSettingsReader.codeAPIBaseURLEnvironmentKey] = baseURL
        }
        return env
    }

    private static func applyDoubaoOverrides(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        guard let config else { return base }
        var env = base
        let apiKey = config.sanitizedAPIKey
        let secretKey = config.sanitizedSecretKey

        if let apiKey, self.doubaoAccessKeyID(from: apiKey) == nil {
            self.clearDoubaoCodingPlanCredentialKeys(in: &env)
            env[DoubaoSettingsReader.apiKeyEnvironmentKeys[0]] = apiKey
            if let region = config.sanitizedRegion {
                env[DoubaoSettingsReader.regionEnvironmentKeys[0]] = region
            }
            return env
        }

        let accessKeyID = self.doubaoAccessKeyID(from: apiKey) ?? DoubaoSettingsReader.accessKeyID(environment: base)
        let secretAccessKey = secretKey ?? DoubaoSettingsReader.secretAccessKey(environment: base)

        if let accessKeyID, let secretAccessKey {
            env[DoubaoSettingsReader.accessKeyIDEnvironmentKeys[0]] = accessKeyID
            env[DoubaoSettingsReader.secretAccessKeyEnvironmentKeys[0]] = secretAccessKey
            if let region = config.sanitizedRegion ?? self.firstDoubaoRegionValue(in: base) {
                env[DoubaoSettingsReader.regionEnvironmentKeys[0]] = region
            }
            return env
        }

        if let region = config.sanitizedRegion {
            env[DoubaoSettingsReader.regionEnvironmentKeys[0]] = region
        }
        return env
    }

    private static func applySakanaOverrides(
        base: [String: String],
        config: ProviderConfig?) -> [String: String]
    {
        guard let config else { return base }
        var env = base
        if let cookieHeader = config.sanitizedCookieHeader {
            env[SakanaSettingsReader.cookieHeaderKey] = cookieHeader
        }
        return env
    }

    private static func doubaoAccessKeyID(from apiKey: String?) -> String? {
        guard let apiKey, apiKey.hasPrefix("AKLT") else { return nil }
        return apiKey
    }

    private static func clearDoubaoCodingPlanCredentialKeys(in environment: inout [String: String]) {
        for key in DoubaoSettingsReader.accessKeyIDEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        for key in DoubaoSettingsReader.secretAccessKeyEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
    }

    private static func firstDoubaoRegionValue(in environment: [String: String]) -> String? {
        for key in DoubaoSettingsReader.regionEnvironmentKeys {
            guard let value = DoubaoSettingsReader.cleaned(environment[key]) else { continue }
            return value
        }
        return nil
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
