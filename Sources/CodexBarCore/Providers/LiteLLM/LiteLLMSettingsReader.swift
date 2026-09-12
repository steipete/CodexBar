import Foundation

public enum LiteLLMSettingsReader {
    public static let apiKeyEnvironmentKey = "LITELLM_API_KEY"
    public static let baseURLEnvironmentKey = "LITELLM_BASE_URL"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) else { return nil }
        // The API key is sent to this URL as a bearer token, so validate it like every other
        // provider override. HTTP stays allowed for loopback and private-network proxies; public
        // hosts must use HTTPS, and no endpoint may carry embedded credentials.
        return ProviderEndpointOverrideValidator().validatedURLAllowingPrivateNetworkHTTP(raw)
    }

    /// True when a base URL is configured at all, even if it fails validation.
    ///
    /// Availability checks use this so a rejected override still reaches the fetch path and
    /// surfaces ``LiteLLMUsageError/invalidEndpointOverride(_:)`` instead of silently hiding
    /// the provider as unconfigured.
    public static func hasBaseURLOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) != nil
    }
}
