import Foundation

public enum XAICredentialRouting: Sendable, Equatable {
    case none
    case managementAPI
    case oauth(accessToken: String)
    case webCookie(header: String)

    public static func resolve(tokenAccountToken: String?, manualCookieHeader: String?) -> Self {
        if let tokenAccountToken, let route = self.resolvePrimaryCredential(tokenAccountToken) {
            return route
        }
        guard let manualCookieHeader = self.normalizedWebCookie(manualCookieHeader) else {
            return .none
        }
        return .webCookie(header: manualCookieHeader)
    }

    public var oauthAccessToken: String? {
        guard case let .oauth(accessToken) = self else { return nil }
        return accessToken
    }

    public var manualCookieHeader: String? {
        guard case let .webCookie(header) = self else { return nil }
        return header
    }

    public var isOAuth: Bool {
        if case .oauth = self { return true }
        return false
    }

    private static func resolvePrimaryCredential(_ raw: String) -> Self? {
        if self.isManagementAPIKey(raw) {
            return .managementAPI
        }
        if let accessToken = self.normalizedOAuthToken(raw) {
            return .oauth(accessToken: accessToken)
        }
        if let cookieHeader = self.normalizedWebCookie(raw) {
            return .webCookie(header: cookieHeader)
        }
        return nil
    }

    static func isManagementAPIKey(_ raw: String?) -> Bool {
        guard let trimmed = self.cleaned(raw) else { return false }
        let token = self.strippingBearerPrefix(trimmed)
        let lower = token.lowercased()
        if lower.contains("cookie:") || token.contains("=") {
            return false
        }
        return lower.hasPrefix("xai-")
    }

    static func normalizedOAuthToken(_ raw: String?) -> String? {
        guard let trimmed = self.cleaned(raw) else { return nil }
        if trimmed.lowercased().contains("cookie:") || trimmed.contains("=") {
            return nil
        }
        let token = self.strippingBearerPrefix(trimmed)
        guard !token.isEmpty, !self.isManagementAPIKey(token) else { return nil }
        return token
    }

    static func normalizedWebCookie(_ raw: String?) -> String? {
        CookieHeaderNormalizer.normalize(raw)
    }

    private static func strippingBearerPrefix(_ raw: String) -> String {
        let lower = raw.lowercased()
        guard lower.hasPrefix("bearer ") else { return raw }
        return raw.dropFirst("bearer ".count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleaned(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
