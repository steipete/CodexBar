import Foundation

public enum AiAndSettingsReader {
    public static let apiKeyEnvironmentKey = "AIAND_API_KEY"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }
}
