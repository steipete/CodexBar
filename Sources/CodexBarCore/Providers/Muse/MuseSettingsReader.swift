import Foundation

public enum MuseSettingsReader {
    /// `muse login --help` states "META_API_KEY always takes priority over the account login", and the
    /// Meta Model API SDKs read `MODEL_API_KEY` (https://dev.meta.ai/docs/authentication). Both are
    /// documented; nothing else is.
    public static let apiKeyEnvironmentKeys = ["META_API_KEY", "MODEL_API_KEY"]
    public static let baseURLEnvironmentKey = "MUSE_BASE_URL"
    /// https://dev.meta.ai/docs/overview — also what `muse login` records as `api_base_url`.
    public static let defaultBaseURL = URL(string: "https://api.meta.ai/v1")!

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiKeyEnvironmentKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }

    /// Resolves the endpoint the API key is sent to.
    ///
    /// The key travels to this host as a bearer token, so an override is validated like every other
    /// provider endpoint: HTTPS anywhere, HTTP only for loopback/private-network gateways, never with
    /// embedded credentials. An override that fails validation throws instead of silently falling back
    /// to `api.meta.ai`, so a key meant for a private gateway is never disclosed to Meta.
    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        localAuth: MuseLocalAuth? = nil) throws -> URL
    {
        if let raw = self.cleaned(environment[self.baseURLEnvironmentKey]) {
            guard let url = ProviderEndpointOverrideValidator().validatedURLAllowingPrivateNetworkHTTP(raw) else {
                throw MuseUsageError.invalidEndpointOverride(raw)
            }
            return url
        }
        return localAuth?.apiBaseURL ?? self.defaultBaseURL
    }

    /// True when an override is configured at all, even one that fails validation, so availability
    /// checks still route to the fetch path and surface ``MuseUsageError/invalidEndpointOverride(_:)``
    /// instead of hiding the provider as unconfigured.
    public static func hasBaseURLOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        self.cleaned(environment[self.baseURLEnvironmentKey]) != nil
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

public enum MuseUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidAPIKey
    case invalidEndpointOverride(String)
    case usageUnavailable
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Muse credentials not found. Set META_API_KEY, add an API key for Muse, or run `muse login`."
        case .invalidAPIKey:
            "Muse API key was rejected. Run `muse login` or set a valid META_API_KEY."
        case let .invalidEndpointOverride(raw):
            "MUSE_BASE_URL is not a usable endpoint: \(raw). Use HTTPS, or HTTP only for a private-network host."
        case .usageUnavailable:
            "Muse did not report rate-limit headers for this request."
        case let .networkError(message):
            message
        }
    }
}
