import Foundation

public enum ProviderConfigEnvironment {
    public static func applyAPIKeyOverride(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        var env = base
        if provider == .cliproxyapi {
            if let managementKey = config?.sanitizedManagementKey {
                env[CLIProxyAPISettingsReader.managementKeyKey] = managementKey
            }
            if let managementURL = config?.sanitizedManagementURL {
                env[CLIProxyAPISettingsReader.managementURLKey] = managementURL
            }
            return env
        }
        guard let apiKey = config?.sanitizedAPIKey, !apiKey.isEmpty else { return base }
        switch provider {
        case .zai:
            env[ZaiSettingsReader.apiTokenKey] = apiKey
        case .copilot:
            env["COPILOT_API_TOKEN"] = apiKey
        case .minimax:
            env[MiniMaxAPISettingsReader.apiTokenKey] = apiKey
        case .kimik2:
            if let key = KimiK2SettingsReader.apiKeyEnvironmentKeys.first {
                env[key] = apiKey
            }
        case .synthetic:
            env[SyntheticSettingsReader.apiKeyKey] = apiKey
        default:
            break
        }
        return env
    }
}
