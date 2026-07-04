import Foundation

/// Reads ClinePass (Cline) settings from environment variables.
///
/// ClinePass is Cline's flat-rate subscription that fronts an OpenAI-compatible
/// gateway at `api.cline.bot`. A `CLINE_API_KEY` (created at app.cline.bot →
/// Settings → API Keys) authorizes the account read endpoints CodexBar uses to
/// surface the remaining credit balance. The env var names mirror Cline's own
/// ecosystem (`CLINE_API_KEY`, `CLINE_API_BASE_URL`) so existing Cline users get
/// zero-config detection.
public enum ClinePassSettingsReader {
    /// Environment variable key for the Cline API token.
    public static let envKey = "CLINE_API_KEY"
    /// Environment variable key for an optional API base URL override.
    public static let urlEnvKey = "CLINE_API_BASE_URL"

    /// Returns the API token from environment if present and non-empty.
    public static func apiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.envKey])
    }

    /// Returns the API base URL, defaulting to the production endpoint.
    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.validAPIURL(environment: environment) {
            return override
        }
        return URL(string: "https://api.cline.bot")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.urlEnvKey]) else { return }
        // Loopback HTTP is allowed so the provider can be exercised end-to-end
        // against a locally running gateway during development.
        guard ProviderEndpointOverrideValidator().validatedURLAllowingLoopbackHTTP(raw) == nil else { return }
        throw ClinePassSettingsError.invalidEndpointOverride(self.urlEnvKey)
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
