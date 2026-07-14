import Foundation

public enum AnyRouterSettingsError: LocalizedError, Equatable, Sendable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            "AnyRouter endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}

/// Reads AnyRouter settings from environment variables.
public enum AnyRouterSettingsReader {
    public static let apiKeyEnvironmentKey = "ANYROUTER_API_KEY"
    public static let baseURLEnvironmentKey = "ANYROUTER_API_URL"
    public static let defaultBaseURL = URL(string: "https://anyrouter.dev/api/v1")!

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        guard let raw = self.cleaned(environment[self.baseURLEnvironmentKey]) else {
            return self.defaultBaseURL
        }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) ?? self.defaultBaseURL
    }

    public static func validateEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.baseURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) != nil else {
            throw AnyRouterSettingsError.invalidEndpointOverride(self.baseURLEnvironmentKey)
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
}
