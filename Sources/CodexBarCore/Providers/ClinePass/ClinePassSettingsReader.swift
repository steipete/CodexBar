import Foundation

public enum ClinePassSettingsReader {
    public static let apiKeyEnvironmentKey = "CLINE_API_KEY"
    public static let alternateAPIKeyEnvironmentKey = "CLINEPASS_API_KEY"
    public static let apiKeyEnvironmentKeys = [
        Self.apiKeyEnvironmentKey,
        Self.alternateAPIKeyEnvironmentKey,
    ]

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiKeyEnvironmentKeys {
            if let value = SettingsValue.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }
}
