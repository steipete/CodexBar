import Foundation

public enum AIHubMixSettingsReader {
    public static let apiKeyEnvironmentKey = "AIHUBMIX_ACCESS_KEY"
    public static let tokenEnvironmentKey = "AIHUBMIX_TOKEN"
    public static let apiKeyEnvironmentKeys = [
        Self.apiKeyEnvironmentKey,
        Self.tokenEnvironmentKey,
    ]
    public static let apiURLEnvironmentKey = "AIHUBMIX_API_URL"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiKeyEnvironmentKeys {
            guard let token = self.cleaned(environment[key]) else { continue }
            return token
        }
        return nil
    }

    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.validAPIURL(environment: environment) {
            return override
        }
        return URL(string: "https://aihubmix.com")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.apiURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) == nil else { return }
        throw AIHubMixSettingsError.invalidEndpointOverride(self.apiURLEnvironmentKey)
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

public enum AIHubMixSettingsError: LocalizedError, Sendable, Equatable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            "AIHubMix endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
