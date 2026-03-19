import Foundation

/// Reads Grok/xAI settings from environment variables
public struct GrokSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "XAI_API_KEY",
        "GROK_API_KEY",
    ]

    public static let managementKeyEnvironmentKey = "XAI_MANAGEMENT_KEY"
    public static let teamIDEnvironmentKey = "XAI_TEAM_ID"

    /// Returns the API key from environment if present and non-empty
    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiKeyEnvironmentKeys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            let cleaned = Self.cleaned(raw)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    /// Returns the Management API key from environment if present
    public static func managementKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let raw = environment[Self.managementKeyEnvironmentKey],
              !Self.cleaned(raw).isEmpty
        else {
            return nil
        }
        return Self.cleaned(raw)
    }

    /// Returns the team ID, defaulting to "default"
    public static func teamID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        let raw = environment[Self.teamIDEnvironmentKey] ?? ""
        let cleaned = Self.cleaned(raw)
        return cleaned.isEmpty ? "default" : cleaned
    }

    /// Returns the inference API URL, defaulting to production endpoint
    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["XAI_API_URL"],
           let url = URL(string: Self.cleaned(override))
        {
            return url
        }
        return URL(string: "https://api.x.ai/v1")!
    }

    /// Returns the Management API URL
    public static func managementAPIURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = environment["XAI_MANAGEMENT_API_URL"],
           let url = URL(string: Self.cleaned(override))
        {
            return url
        }
        return URL(string: "https://management-api.x.ai/v1")!
    }

    static func cleaned(_ raw: String?) -> String {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return ""
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
