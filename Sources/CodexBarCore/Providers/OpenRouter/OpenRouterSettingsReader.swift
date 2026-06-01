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
        if self.hasExplicitNonHTTPSURL(environment["OPENROUTER_API_URL"]) {
            throw OpenRouterSettingsError.invalidEndpointOverride("OPENROUTER_API_URL")
        }
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
        if let scheme = self.explicitURLScheme(raw) {
            return scheme == "https" ? URL(string: raw) : nil
        }
        return URL(string: "https://\(raw)")
    }

    private static func hasExplicitNonHTTPSURL(_ raw: String?) -> Bool {
        guard let cleaned = self.cleaned(raw),
              let scheme = self.explicitURLScheme(cleaned)
        else { return false }
        return scheme != "https"
    }

    private static func explicitURLScheme(_ raw: String) -> String? {
        guard let schemeSeparator = raw.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression)
        else { return nil }
        return raw[..<schemeSeparator.upperBound].dropLast(3).lowercased()
    }
}
