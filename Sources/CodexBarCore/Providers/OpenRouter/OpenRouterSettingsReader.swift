import Foundation

/// Reads OpenRouter settings from environment variables
public enum OpenRouterSettingsReader {
    /// Environment variable key for OpenRouter API token
    public static let envKey = "OPENROUTER_API_KEY"

    /// Returns the API token from environment if present and non-empty
    public static func apiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.envKey])
    }

    /// Returns the API URL, defaulting to production endpoint
    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["OPENROUTER_API_URL"],
           let url = URL(string: cleaned(override) ?? "")
        {
            return url
        }
        return URL(string: "https://openrouter.ai/api/v1")!
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
