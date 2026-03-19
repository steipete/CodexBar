import Foundation

/// Reads Grok/xAI settings from environment variables
public struct GrokSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = ["XAI_API_KEY"]

    public static let managementKeyEnvironmentKey = "XAI_MANAGEMENT_API_KEY"
    public static let teamIDEnvironmentKey = "XAI_TEAM_ID"

    /// Returns the API key from environment if present and non-empty
    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiKeyEnvironmentKeys {
            if let token = self.cleaned(environment[key]) { return token }
        }
        return nil
    }

    /// Returns the Management API key from environment if present
    public static func managementKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[Self.managementKeyEnvironmentKey])
    }

    /// Returns the team ID, defaulting to "default"
    public static func teamID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        guard let id = self.cleaned(environment[Self.teamIDEnvironmentKey]) else {
            return "default"
        }
        return id
    }

    /// Returns the inference API URL, defaulting to production endpoint
    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.cleaned(environment["XAI_API_URL"]),
           let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://api.x.ai/v1")!
    }

    /// Returns the Management API URL
    public static func managementAPIURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = self.cleaned(environment["XAI_MANAGEMENT_API_URL"]),
           let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://management-api.x.ai/v1")!
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

/// Errors related to Grok settings
public enum GrokSettingsError: LocalizedError, Sendable {
    case missingToken
    case missingManagementKey

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "xAI API key not configured. Set XAI_API_KEY environment variable or configure in Settings."
        case .missingManagementKey:
            "xAI Management key not configured. Set XAI_MANAGEMENT_API_KEY or configure in Settings."
        }
    }
}
