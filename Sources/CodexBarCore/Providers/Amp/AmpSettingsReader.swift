import Foundation

public enum AmpSettingsReader {
    public static let apiTokenKey = "AMP_API_KEY"

    public static func apiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        SettingsValue.cleaned(environment[self.apiTokenKey])
    }
}
