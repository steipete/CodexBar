import Foundation

public struct ChutesSettingsReader: Sendable {
    public static let apiKeyEnvironmentKey = "CHUTES_API_KEY"
    public static let apiURLEnvironmentKey = "CHUTES_API_URL"

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
        return URL(string: "https://api.chutes.ai")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = SettingsValue.cleaned(environment[self.apiURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) == nil else { return }
        throw ChutesSettingsError.invalidEndpointOverride(self.apiURLEnvironmentKey)
    }

    private static func validAPIURL(environment: [String: String]) -> URL? {
        guard let raw = SettingsValue.cleaned(environment[self.apiURLEnvironmentKey]) else { return nil }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
    }
}

public enum ChutesSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Chutes API key not found. Set apiKey in ~/.codexbar/config.json or CHUTES_API_KEY."
        case let .invalidEndpointOverride(key):
            "Chutes endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
