import Foundation

public enum CrofSettingsReader {
    public static let apiKeyEnvironmentKeys = ["CROF_API_KEY", "CROFAI_API_KEY"]

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiKeyEnvironmentKeys {
            if let value = SettingsValue.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }
}
