import Foundation

public enum CommandCodeSettingsReader {
    public static let apiKeyEnvironmentKey = "COMMAND_CODE_API_KEY"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }
}
