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
    public let environmentKeysToScrub: [String]
    public let minimumDelayBetweenAccountRefreshes: Duration?
    public let selectedAccountRequiresManualCookieSource: Bool
    public let clearsAPIKeyOnMutation: Bool
    public let showsOrganizationField: Bool
    public let showsTeamModeControls: Bool
    public let primaryAddActionTitle: String?
    private let environmentOverride: @Sendable (String) -> [String: String]?
    private let environmentScrubber: @Sendable (inout [String: String], String) -> Void
    private let cookieHeaderNormalizer: @Sendable (String) -> String

    public init(
        title: String,
        subtitle: String,
        placeholder: String,
        injection: TokenAccountInjection,
        requiresManualCookieSource: Bool,
        cookieName: String?,
        environmentKeysToScrub: [String] = [],
        minimumDelayBetweenAccountRefreshes: Duration? = nil,
        selectedAccountRequiresManualCookieSource: Bool = false,
        clearsAPIKeyOnMutation: Bool = false,
        showsOrganizationField: Bool = false,
        showsTeamModeControls: Bool = false,
        primaryAddActionTitle: String? = nil,
        environmentOverride: (@Sendable (String) -> [String: String]?)? = nil,
        environmentScrubber: (@Sendable (inout [String: String], String) -> Void)? = nil,
        cookieHeaderNormalizer: (@Sendable (String) -> String)? = nil)
    {
        self.title = title
        self.subtitle = subtitle
        self.placeholder = placeholder
        self.injection = injection
        self.requiresManualCookieSource = requiresManualCookieSource
        self.cookieName = cookieName
        self.environmentKeysToScrub = environmentKeysToScrub
        self.minimumDelayBetweenAccountRefreshes = minimumDelayBetweenAccountRefreshes
        self.selectedAccountRequiresManualCookieSource = selectedAccountRequiresManualCookieSource
        self.clearsAPIKeyOnMutation = clearsAPIKeyOnMutation
        self.showsOrganizationField = showsOrganizationField
        self.showsTeamModeControls = showsTeamModeControls
        self.primaryAddActionTitle = primaryAddActionTitle
        self.environmentOverride = environmentOverride ?? { token in
            guard case let .environment(key) = injection else { return nil }
            return [key: token]
        }
        self.environmentScrubber = environmentScrubber ?? { environment, _ in
            guard case let .environment(key) = injection else { return }
            environment.removeValue(forKey: key)
            for key in environmentKeysToScrub {
                environment.removeValue(forKey: key)
            }
        }
        self.cookieHeaderNormalizer = cookieHeaderNormalizer ?? { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let cookieName else { return trimmed }
            let lower = trimmed.lowercased()
            if lower.contains("cookie:") || trimmed.contains("=") {
                return trimmed
            }
            return "\(cookieName)=\(trimmed)"
        }
    }

    public func envOverride(token: String) -> [String: String]? {
        self.environmentOverride(token)
    }

    public func scrubEnvironment(_ environment: inout [String: String], token: String) {
        self.environmentScrubber(&environment, token)
    }

    public func normalizedCookieHeader(token: String) -> String {
        self.cookieHeaderNormalizer(token)
    }
}

public enum TokenAccountSupportCatalog {
    public static func support(for provider: UsageProvider) -> TokenAccountSupport? {
        ProviderDescriptorRegistry.descriptor(for: provider).credentials?.tokenAccountSupport
    }

    public static func envOverride(for provider: UsageProvider, token: String) -> [String: String]? {
        self.support(for: provider)?.envOverride(token: token)
    }

    public static func scrubEnvironmentForSelectedAccount(
        _ environment: inout [String: String],
        provider: UsageProvider,
        token: String)
    {
        self.support(for: provider)?.scrubEnvironment(&environment, token: token)
    }

    public static func normalizedCookieHeader(for provider: UsageProvider, token: String) -> String {
        guard let support = self.support(for: provider) else {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return support.normalizedCookieHeader(token: token)
    }

    public static func isClaudeOAuthToken(_ token: String) -> Bool {
        ClaudeCredentialRouting.resolve(tokenAccountToken: token, manualCookieHeader: nil).isOAuth
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
