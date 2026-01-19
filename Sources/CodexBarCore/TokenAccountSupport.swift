import Foundation

public enum TokenAccountInjection: Sendable {
    case cookieHeader
    case environment(key: String)
}

public struct TokenAccountSupport: Sendable {
    public let title: String
    public let subtitle: String
    public let placeholder: String
    public let injection: TokenAccountInjection
    public let requiresManualCookieSource: Bool
    public let cookieName: String?

    public init(
        title: String,
        subtitle: String,
        placeholder: String,
        injection: TokenAccountInjection,
        requiresManualCookieSource: Bool,
        cookieName: String?)
    {
        self.title = title
        self.subtitle = subtitle
        self.placeholder = placeholder
        self.injection = injection
        self.requiresManualCookieSource = requiresManualCookieSource
        self.cookieName = cookieName
    }
}

public enum TokenAccountSupportCatalog {
    public static func support(for provider: UsageProvider) -> TokenAccountSupport? {
        supportByProvider[provider]
    }

    public static func envOverride(for provider: UsageProvider, token: String) -> [String: String]? {
        guard let support = self.support(for: provider) else { return nil }
        switch support.injection {
        case let .environment(key):
            return [key: token]
        case .cookieHeader:
            if provider == .claude,
               let normalized = self.normalizedClaudeOAuthToken(token),
               self.isClaudeOAuthToken(normalized)
            {
                return [ClaudeOAuthCredentialsStore.environmentTokenKey: normalized]
            }
            return nil
        }
    }

    public static func normalizedCookieHeader(for provider: UsageProvider, token: String) -> String {
        guard let support = self.support(for: provider) else {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return self.normalizedCookieHeader(token, support: support)
    }

    public static func isClaudeOAuthToken(_ token: String) -> Bool {
        guard let trimmed = self.normalizedClaudeOAuthToken(token) else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("cookie:") || trimmed.contains("=") {
            return false
        }
        return lower.hasPrefix("sk-ant-oat")
    }

    private static func normalizedClaudeOAuthToken(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("bearer ") {
            return trimmed.dropFirst("bearer ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    public static func normalizedCookieHeader(_ token: String, support: TokenAccountSupport) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cookieName = support.cookieName else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.contains("cookie:") || trimmed.contains("=") {
            return trimmed
        }
        return "\(cookieName)=\(trimmed)"
    }
}
