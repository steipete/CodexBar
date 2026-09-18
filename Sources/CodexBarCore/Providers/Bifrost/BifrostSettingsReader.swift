import Foundation

public enum BifrostSettingsReader {
    public static let apiKeyEnvironmentKey = "BIFROST_API_KEY"
    public static let baseURLEnvironmentKey = "BIFROST_BASE_URL"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) else { return nil }
        // The virtual key is sent to this URL, so validate it like every other provider override. HTTP
        // stays allowed for loopback and private-network gateways; public hosts must use HTTPS, and no
        // endpoint may carry embedded credentials.
        return ProviderEndpointOverrideValidator().validatedURLAllowingPrivateNetworkHTTP(raw)
    }

    /// True when a base URL is configured at all, even if it fails validation.
    ///
    /// Availability checks use this so a rejected override still reaches the fetch path and
    /// surfaces ``BifrostUsageError/invalidEndpointOverride(_:)`` instead of silently hiding
    /// the provider as unconfigured.
    public static func hasBaseURLOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) != nil
    }
}
