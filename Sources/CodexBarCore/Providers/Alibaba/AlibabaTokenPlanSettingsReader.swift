import Foundation

public struct AlibabaTokenPlanSettingsReader: Sendable {
    public static let cookieHeaderKey = "ALIBABA_TOKEN_PLAN_COOKIE"
    public static let hostKey = "ALIBABA_TOKEN_PLAN_HOST"
    public static let quotaURLKey = "ALIBABA_TOKEN_PLAN_QUOTA_URL"

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.cookieHeaderKey])
    }

    public static func hostOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let raw = self.cleaned(environment[self.hostKey]) else { return nil }
        if let scheme = URL(string: raw)?.scheme {
            return scheme.lowercased() == "https" ? raw : nil
        }
        return raw
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
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum AlibabaTokenPlanSettingsError: LocalizedError, Sendable {
    case missingCookie(details: String? = nil)
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case let .missingCookie(details):
            let base = "No Alibaba Token Plan session cookies found in browsers. " +
                "Sign in to Bailian in Chrome, allow CodexBar to access Chrome Safe Storage in Keychain Access, " +
                "or paste a manual Cookie header."
            guard let details, !details.isEmpty else { return base }
            return "\(base) \(details)"
        case .invalidCookie:
            return "Alibaba Token Plan cookie header is invalid."
        }
    }
}
