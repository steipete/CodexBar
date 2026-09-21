import Foundation

public enum V0SettingsReader {
    public static let apiKeyEnvironmentKey = "V0_API_KEY"
    public static let scopeEnvironmentKey = "V0_SCOPE"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func scope(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        SettingsValue.cleaned(environment[self.scopeEnvironmentKey])
    }
}
