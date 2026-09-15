import Foundation

public enum PoeSettingsReader {
    public static let apiKeyEnvironmentKey = "POE_API_KEY"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }
}
