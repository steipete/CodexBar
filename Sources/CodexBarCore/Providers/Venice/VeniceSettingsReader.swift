import Foundation

public struct VeniceSettingsReader: Sendable {
    public static let apiKeyEnvironmentKey = "VENICE_API_KEY"
    public static let apiKeyEnvironmentKeys = [Self.apiKeyEnvironmentKey, "VENICE_KEY"]

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
