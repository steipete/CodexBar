import Foundation

public struct DeepInfraSettingsReader: Sendable {
    public static let apiKeyEnvironmentKey = "DEEPINFRA_API_KEY"
    public static let apiKeyEnvironmentKeys = [Self.apiKeyEnvironmentKey, "DEEPINFRA_TOKEN"]

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
