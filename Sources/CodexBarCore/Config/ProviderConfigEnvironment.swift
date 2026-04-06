import Foundation

public enum ProviderConfigEnvironment {
    public static func applyAPIKeyOverride(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        // Bedrock uses multiple independent credential fields, not just a single API key.
        // Apply each field from config when present, regardless of the others.
        if provider == .bedrock {
            var env = base
            if let accessKey = config?.sanitizedAPIKey, !accessKey.isEmpty {
                env[BedrockSettingsReader.accessKeyIDKey] = accessKey
            }
            if let secret = config?.sanitizedCookieHeader, !secret.isEmpty {
                env[BedrockSettingsReader.secretAccessKeyKey] = secret
            }
            if let region = config?.region, !region.isEmpty {
                env[BedrockSettingsReader.regionKeys[0]] = region
            }
            return env
        }

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
        default:
            break
        }
        return env
    }
}
