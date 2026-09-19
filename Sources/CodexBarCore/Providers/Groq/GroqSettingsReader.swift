import Foundation

public enum GroqSettingsReader {
    public static let apiKeyEnvironmentKey = "GROQ_API_KEY"
    public static let apiURLEnvironmentKey = "GROQ_API_URL"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func apiURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = self.validAPIURL(environment: environment) {
            return override
        }
        return URL(string: "https://api.groq.com/v1")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = SettingsValue.cleaned(environment[self.apiURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) == nil else { return }
        throw GroqSettingsError.invalidEndpointOverride(self.apiURLEnvironmentKey)
    }

    private static func validAPIURL(environment: [String: String]) -> URL? {
        guard let raw = SettingsValue.cleaned(environment[self.apiURLEnvironmentKey]) else { return nil }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
    }
}

public enum GroqSettingsError: LocalizedError, Sendable, Equatable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            "Groq endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
