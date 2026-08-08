import Foundation

/// Reads OpenRouter settings from environment variables
public enum OpenRouterSettingsReader {
    /// Environment variable key for OpenRouter API token
    public static let envKey = "OPENROUTER_API_KEY"
    public static let apiURLEnvironmentKey = "OPENROUTER_API_URL"
    public static let httpRefererEnvironmentKey = "OPENROUTER_HTTP_REFERER"
    public static let clientTitleEnvironmentKey = "OPENROUTER_X_TITLE"
    public static let defaultClientTitle = "CodexBar"

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
        guard let raw = self.cleaned(environment[self.apiURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) == nil else { return }
        throw OpenRouterSettingsError.invalidEndpointOverride(self.apiURLEnvironmentKey)
    }

    public static func httpReferer(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.httpRefererEnvironmentKey])
    }

    public static func clientTitle(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        self.cleaned(environment[self.clientTitleEnvironmentKey]) ?? self.defaultClientTitle
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
        guard let raw = self.cleaned(environment[self.apiURLEnvironmentKey]) else { return nil }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
    }
}
