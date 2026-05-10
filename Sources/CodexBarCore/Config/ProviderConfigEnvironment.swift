import Foundation

public enum ProviderConfigEnvironment {
    public static func applyAPIKeyOverride(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        guard let apiKey = config?.sanitizedAPIKey, !apiKey.isEmpty else { return base }
        var env = base
        switch provider {
        case .zai:
            env[ZaiSettingsReader.apiTokenKey] = apiKey
        case .copilot:
            env["COPILOT_API_TOKEN"] = apiKey
        case .minimax:
            env[MiniMaxAPISettingsReader.apiTokenKey] = apiKey
        case .alibaba:
            env[AlibabaCodingPlanSettingsReader.apiTokenKey] = apiKey
        case .kilo:
            env[KiloSettingsReader.apiTokenKey] = apiKey
        case .kimik2:
            if let key = KimiK2SettingsReader.apiKeyEnvironmentKeys.first {
                env[key] = apiKey
            }
        case .synthetic:
            env[SyntheticSettingsReader.apiKeyKey] = apiKey
        case .warp:
            if let key = WarpSettingsReader.apiKeyEnvironmentKeys.first {
                env[key] = apiKey
            }
        case .openrouter:
            env[OpenRouterSettingsReader.envKey] = apiKey
        case .venice:
            env[VeniceSettingsReader.apiKeyEnvironmentKey] = apiKey
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
        default:
            break
        }
        return env
    }
}
