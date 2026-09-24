import Foundation

public enum AixySettingsReader {
    public static let apiKeyEnvironmentKey = "AIXY_API_KEY"
    public static let baseURLEnvironmentKey = "AIXY_BASE_URL"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        let raw = SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) ?? "https://api.aixy-gateway.com"
        // The API key is sent to this URL, so validate it like every other provider override. HTTP
        // stays allowed for loopback and private-network gateways; public hosts must use HTTPS, and no
        // endpoint may carry embedded credentials.
        guard let url = ProviderEndpointOverrideValidator().validatedURLAllowingPrivateNetworkHTTP(raw),
              url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }
}
