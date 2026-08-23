import Foundation

public struct QwenCloudSettingsReader: Sendable {
    public static let cookieHeaderKey = "QWEN_CLOUD_COOKIE"
    public static let hostKey = "QWEN_CLOUD_HOST"
    public static let quotaURLKey = "QWEN_CLOUD_QUOTA_URL"

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.cookieHeaderKey])
    }

    public static func hostOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let raw = self.cleaned(environment[self.hostKey]) else { return nil }
        // Accept full https:// URLs and normalize bare hosts (e.g. "qwen-cloud.test"
        // or "qwen-cloud.test:8443") to HTTPS, so dashboardURL / defaultQuotaURL
        // always build valid URLs. Mirrors the shared endpoint-override rules used
        // by the Alibaba token-plan host override.
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)?.absoluteString
    }

    public static func quotaURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[self.quotaURLKey]) else { return nil }
        if let url = URL(string: raw), let scheme = url.scheme {
            return scheme.lowercased() == "https" ? url : nil
        }
        return URL(string: "https://\(raw)")
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

public enum QwenCloudSettingsError: LocalizedError, Sendable {
    case missingCookie(details: String? = nil)
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case let .missingCookie(details):
            // Qwen Cloud cookie import now probes Chrome *and* Brave (per the
            // QwenCloudProviderDescriptor.browserOrder override). The recovery
            // message must name both supported browsers and their respective
            // Safe Storage entries, otherwise a Brave-only user would be told
            // to sign in with Chrome and the fix would be invisible.
            let base = "No Qwen Cloud session cookies found in browsers. " +
                "Sign in to Qwen Cloud in Chrome or Brave, " +
                "allow CodexBar to access the corresponding Safe Storage in Keychain Access " +
                "(Chrome Safe Storage and/or Brave Safe Storage), " +
                "or paste a manual Cookie header."
            guard let details, !details.isEmpty else { return base }
            return "\(base) \(details)"
        case .invalidCookie:
            return "Qwen Cloud cookie header is invalid."
        }
    }
}
