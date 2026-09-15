import Foundation

public struct FireworksSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "FIREWORKS_API_KEY",
        "FIREWORKS_KEY",
    ]
    public static let accountSlugEnvironmentKey = "FIREWORKS_ACCOUNT_SLUG"
    public static let configAPIKeyEnvironmentKey = "CODEXBAR_FIREWORKS_API_KEY"
    public static let configAccountSlugEnvironmentKey = "CODEXBAR_FIREWORKS_ACCOUNT_SLUG"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in [self.configAPIKeyEnvironmentKey] + self.apiKeyEnvironmentKeys {
            if let value = SettingsValue.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }

    public static func accountSlug(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in [self.configAccountSlugEnvironmentKey, self.accountSlugEnvironmentKey] {
            if let value = SettingsValue.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }
}
