import Foundation

public enum GrokCredentialRouting: Sendable, Equatable {
    case none
    case oauth(accessToken: String)
    case webCookie(header: String)

    public static func resolve(tokenAccountToken: String?, manualCookieHeader: String?) -> Self {
        if let tokenAccountToken, let route = self.resolvePrimaryCredential(tokenAccountToken) {
            return route
        }
        guard let cookieHeader = self.normalizedWebCookie(manualCookieHeader) else {
            return .none
        }
        return .webCookie(header: cookieHeader)
    }

    public var oauthAccessToken: String? {
        guard case let .oauth(accessToken) = self else { return nil }
        return accessToken
    }

    public var manualCookieHeader: String? {
        guard case let .webCookie(header) = self else { return nil }
        return header
    }

    public var sourceMode: ProviderSourceMode? {
        switch self {
        case .oauth: .oauth
        case .webCookie: .web
        case .none: nil
        }
    }

    public static func cookieSettings(
        configuredSource: ProviderCookieSource,
        configuredHeader: String?,
        selectedAccountToken: String?) -> CookieProviderSettings
    {
        if let header = self.resolve(
            tokenAccountToken: selectedAccountToken,
            manualCookieHeader: nil).manualCookieHeader
        {
            return CookieProviderSettings(cookieSource: .manual, manualCookieHeader: header)
        }
        return CookieProviderSettings(
            cookieSource: configuredSource,
            manualCookieHeader: configuredHeader)
    }

    private static func resolvePrimaryCredential(_ raw: String) -> Self? {
        if let accessToken = self.normalizedOAuthToken(raw) {
            return .oauth(accessToken: accessToken)
        }
        if let cookieHeader = self.normalizedWebCookie(raw) {
            return .webCookie(header: cookieHeader)
        }
        return nil
    }

    public static func normalizedOAuthToken(_ raw: String?) -> String? {
        var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !token.isEmpty else { return nil }
        let lower = token.lowercased()
        if lower.hasPrefix("cookie:") {
            return nil
        }
        if lower.hasPrefix("xai-") {
            return nil
        }
        if token.contains("=") {
            return nil
        }
        return token
    }

    public static func normalizedWebCookie(_ raw: String?) -> String? {
        guard let normalized = CookieHeaderNormalizer.normalize(raw),
              normalized.contains("=")
        else {
            return nil
        }
        return normalized
    }
}
