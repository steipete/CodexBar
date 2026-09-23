import Foundation

public enum LLMManSettingsReader {
    /// The key the `llmman` CLI itself presents to `llmman serve`.
    public static let apiKeyEnvironmentKey = "LLMMAN_API_KEY"
    /// The address `llmman serve` listens on, as the daemon itself reads it.
    public static let hostEnvironmentKey = "LLMMAN_HOST"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:17434")!

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    /// The daemon origin, or nil when an override is not a safe place to send the API key.
    ///
    /// Like `LLMMAN_HOST`, a bare `host:port` means plain HTTP. HTTP is limited to loopback and
    /// private-network hosts; public hosts must use HTTPS, and no URL may embed credentials.
    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = SettingsValue.cleaned(environment[self.hostEnvironmentKey]) else {
            return self.defaultBaseURL
        }
        return ProviderEndpointOverrideValidator()
            .validatedURLAllowingPrivateNetworkHTTP(raw.contains("://") ? raw : "http://\(raw)")
    }
}

public enum LLMManUsageError: LocalizedError, Sendable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            "llmman address \(key) is invalid. Use an HTTPS URL, or plain HTTP for " +
                "loopback or private-network addresses and .local hosts, without embedded credentials."
        }
    }
}
