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
        if let override = self.validAPIURL(environment: environment) {
            return override
        }
        return URL(string: "https://openrouter.ai/api/v1")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment["OPENROUTER_API_URL"]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) == nil else { return }
        throw OpenRouterSettingsError.invalidEndpointOverride("OPENROUTER_API_URL")
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func validAPIURL(environment: [String: String]) -> URL? {
        guard let raw = self.cleaned(environment["OPENROUTER_API_URL"]) else { return nil }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
    }
}
