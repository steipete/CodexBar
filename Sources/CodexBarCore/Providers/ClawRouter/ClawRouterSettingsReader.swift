import Foundation

public enum ClawRouterSettingsError: LocalizedError, Equatable, Sendable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            "ClawRouter endpoint override \(key) is invalid. Use an HTTPS URL without embedded credentials."
        }
    }
}

public enum ClawRouterSettingsReader {
    public static let apiKeyEnvironmentKey = "CLAWROUTER_API_KEY"
    public static let baseURLEnvironmentKey = "CLAWROUTER_BASE_URL"
    public static let defaultBaseURL = URL(string: "https://clawrouter.openclaw.ai")!
    public static let missingCredentialsMessage =
        "Missing ClawRouter API key. Add one in Settings or set CLAWROUTER_API_KEY."

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        guard let raw = SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) else {
            return self.defaultBaseURL
        }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) ?? self.defaultBaseURL
    }

    public static func validateEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) != nil else {
            throw ClawRouterSettingsError.invalidEndpointOverride(self.baseURLEnvironmentKey)
        }
    }
}
