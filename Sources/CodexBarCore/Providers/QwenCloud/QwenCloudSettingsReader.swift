import Foundation

public struct QwenCloudSettingsReader: Sendable {
    public static let cookieHeaderKey = "QWEN_CLOUD_COOKIE"
    public static let hostKey = "QWEN_CLOUD_HOST"
    public static let quotaURLKey = "QWEN_CLOUD_QUOTA_URL"

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        SettingsValue.cleaned(environment[self.cookieHeaderKey])
    }

    public static func hostOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let raw = SettingsValue.cleaned(environment[self.hostKey]) else { return nil }
        // Accept full https:// URLs and normalize bare hosts (e.g. "qwen-cloud.test"
        // or "qwen-cloud.test:8443") to HTTPS, so dashboardURL / defaultQuotaURL
        // always build valid URLs. Mirrors the shared endpoint-override rules used
        // by the Alibaba token-plan host override.
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)?.absoluteString
    }

    public static func quotaURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = SettingsValue.cleaned(environment[self.quotaURLKey]) else { return nil }
        if let url = URL(string: raw), let scheme = url.scheme {
            return scheme.lowercased() == "https" ? url : nil
        }
        return URL(string: "https://\(raw)")
    }
}

public enum QwenCloudSettingsError: LocalizedError, Sendable {
    case missingCookie(details: String? = nil)
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case let .missingCookie(details):
            let base = "No Qwen Cloud session cookies found in browsers. " +
                "Sign in to Qwen Cloud in a supported browser, then Refresh to authorize cookie access, " +
                "or paste a manual Cookie header."
            guard let details, !details.isEmpty else { return base }
            return "\(base) \(details)"
        case .invalidCookie:
            return "Qwen Cloud cookie header is invalid."
        }
    }
}
