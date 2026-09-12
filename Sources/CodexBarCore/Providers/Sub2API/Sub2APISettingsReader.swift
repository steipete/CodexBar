import Foundation

public enum Sub2APISettingsError: LocalizedError, Equatable, Sendable {
    case invalidBaseURL

    public var errorDescription: String? {
        "sub2api base URL must use HTTPS, or loopback HTTP for local development, without embedded credentials."
    }
}

public enum Sub2APISettingsReader {
    public static let apiKeyEnvironmentKey = "SUB2API_API_KEY"
    public static let baseURLEnvironmentKey = "SUB2API_BASE_URL"
    public static let missingCredentialsMessage =
        "Missing sub2api API key. Add a group API key in Settings or set SUB2API_API_KEY."
    public static let missingBaseURLMessage =
        "Missing or invalid sub2api base URL. Add one in Settings or set SUB2API_BASE_URL."

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) else { return nil }
        let validator = ProviderEndpointOverrideValidator()
        guard let url = validator.validatedURLAllowingLoopbackHTTP(raw),
              url.query == nil,
              url.fragment == nil
        else { return nil }
        return url
    }

    public static func validateBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard self.baseURL(environment: environment) != nil else {
            throw Sub2APISettingsError.invalidBaseURL
        }
    }
}
