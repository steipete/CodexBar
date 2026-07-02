import Foundation

/// Reads CrossModel settings from environment variables.
public enum CrossModelSettingsReader {
    /// Environment variable key for the CrossModel API token.
    public static let envKey = "CROSSMODEL_API_KEY"
    /// Environment variable key for an optional API base URL override.
    public static let urlEnvKey = "CROSSMODEL_API_URL"

    /// Returns the API token from environment if present and non-empty.
    public static func apiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.envKey])
    }

    /// Returns the API base URL, defaulting to the production endpoint.
    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.validAPIURL(environment: environment) {
            return override
        }
        return URL(string: "https://api.crossmodel.ai/v1")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.urlEnvKey]) else { return }
        // Loopback HTTP is allowed so the provider can be exercised end-to-end
        // against a locally running gateway during development.
        guard ProviderEndpointOverrideValidator().validatedURLAllowingLoopbackHTTP(raw) == nil else { return }
        throw CrossModelSettingsError.invalidEndpointOverride(self.urlEnvKey)
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
        guard let raw = self.cleaned(environment[self.urlEnvKey]) else { return nil }
        return ProviderEndpointOverrideValidator().validatedURLAllowingLoopbackHTTP(raw)
    }
}
