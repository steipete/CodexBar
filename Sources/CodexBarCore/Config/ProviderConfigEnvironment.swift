import Foundation

public enum ProviderConfigEnvironment {
    public static func applyAPIKeyOverride(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        var env = base

        // Grok needs special handling: management key and team ID from config fields
        if provider == .grok, let config {
            if let mgmtKey = config.sanitizedCookieHeader, !mgmtKey.isEmpty {
                env[GrokSettingsReader.managementKeyEnvironmentKey] = mgmtKey
            }
            if let teamID = config.workspaceID, !teamID.isEmpty {
                env[GrokSettingsReader.teamIDEnvironmentKey] = teamID
            }
        }

        guard let apiKey = config?.sanitizedAPIKey, !apiKey.isEmpty else { return env }
        switch provider {
        case .zai:
            env[ZaiSettingsReader.apiTokenKey] = apiKey
        case .copilot:
            env["COPILOT_API_TOKEN"] = apiKey
        case .minimax:
            env[MiniMaxAPISettingsReader.apiTokenKey] = apiKey
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
        case .grok:
            if let key = GrokSettingsReader.apiKeyEnvironmentKeys.first {
                env[key] = apiKey
            }
        default:
            break
        }
        return env
    }
}
