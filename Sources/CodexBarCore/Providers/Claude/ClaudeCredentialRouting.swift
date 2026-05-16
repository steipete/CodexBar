import Foundation

public enum ClaudeCredentialRouting: Sendable, Equatable {
    case none
    case oauth(accessToken: String)
    case webCookie(header: String)
    case adminAPIKey(String)

    public static func resolve(tokenAccountToken: String?, manualCookieHeader: String?) -> Self {
        if let tokenAccountToken,
           let route = self.resolvePrimaryCredential(tokenAccountToken)
        {
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

    public var adminAPIKey: String? {
        guard case let .adminAPIKey(key) = self else { return nil }
        return key
    }

    private static func resolvePrimaryCredential(_ raw: String) -> Self? {
        if let adminKey = self.normalizedAdminAPIKey(raw) {
            return .adminAPIKey(adminKey)
        }
        if let accessToken = self.normalizedOAuthToken(raw) {
            return .oauth(accessToken: accessToken)
        }
        if let cookieHeader = self.normalizedWebCookie(raw) {
            return .webCookie(header: cookieHeader)
        }
        return nil
    }

    private static func normalizedOAuthToken(_ raw: String?) -> String? {
        guard let trimmed = self.cleaned(raw) else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("cookie:") || trimmed.contains("=") {
            return nil
        }
        if lower.hasPrefix("bearer ") {
            let bearerTrimmed = trimmed.dropFirst("bearer ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bearerTrimmed.isEmpty else { return nil }
            let lowerBearerTrimmed = bearerTrimmed.lowercased()
            return lowerBearerTrimmed.hasPrefix("sk-ant-oat") ? bearerTrimmed : nil
        }
        return lower.hasPrefix("sk-ant-oat") ? trimmed : nil
    }

    private static func normalizedAdminAPIKey(_ raw: String?) -> String? {
        guard let trimmed = self.cleaned(raw) else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("cookie:") || trimmed.contains("=") {
            return nil
        }
        if lower.hasPrefix("bearer ") {
            let bearerTrimmed = trimmed.dropFirst("bearer ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bearerTrimmed.isEmpty else { return nil }
            return bearerTrimmed.lowercased().hasPrefix("sk-ant-admin") ? bearerTrimmed : nil
        }
        return lower.hasPrefix("sk-ant-admin") ? trimmed : nil
    }

    private static func normalizedWebCookie(_ raw: String?) -> String? {
        guard let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        if normalized.contains("=") {
            return normalized
        }
        return "sessionKey=\(normalized)"
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
