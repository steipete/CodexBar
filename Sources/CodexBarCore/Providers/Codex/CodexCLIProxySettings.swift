import Foundation

public struct CodexCLIProxySettings: Sendable {
    public static let defaultBaseURL = "http://127.0.0.1:8317"
    public static let environmentBaseURLKey = "CODEX_CLIPROXY_BASE_URL"
    public static let environmentManagementKeyKey = "CODEX_CLIPROXY_MANAGEMENT_KEY"
    public static let environmentAuthIndexKey = "CODEX_CLIPROXY_AUTH_INDEX"

    public let baseURL: URL
    public let managementKey: String
    public let authIndex: String?

    public init(baseURL: URL, managementKey: String, authIndex: String?) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.authIndex = authIndex
    }

    public static func resolve(
        providerSettings: ProviderSettingsSnapshot.CodexProviderSettings?,
        environment: [String: String]) -> CodexCLIProxySettings?
    {
        let managementKey = self.cleaned(providerSettings?.cliProxyManagementKey)
            ?? self.cleaned(environment[Self.environmentManagementKeyKey])
        guard let managementKey else { return nil }

        let rawBaseURL = self.cleaned(providerSettings?.cliProxyBaseURL)
            ?? self.cleaned(environment[Self.environmentBaseURLKey])
            ?? Self.defaultBaseURL
        guard let baseURL = self.normalizedURL(rawBaseURL) else { return nil }

        let authIndex = self.cleaned(providerSettings?.cliProxyAuthIndex)
            ?? self.cleaned(environment[Self.environmentAuthIndexKey])

        return CodexCLIProxySettings(baseURL: baseURL, managementKey: managementKey, authIndex: authIndex)
    }

    public static func normalizedURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return URL(string: "http://\(value)")
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
