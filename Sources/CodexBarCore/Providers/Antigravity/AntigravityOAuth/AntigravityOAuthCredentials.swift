import Foundation

public struct AntigravityOAuthCredentials: Sendable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let email: String?
    public let scopes: [String]

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        email: String?,
        scopes: [String] = AntigravityOAuthConfig.scopes)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
        self.scopes = scopes
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    public var expiresIn: TimeInterval? {
        guard let expiresAt else { return nil }
        return expiresAt.timeIntervalSinceNow
    }

    public var isRefreshable: Bool {
        guard let refreshToken else { return false }
        return !refreshToken.isEmpty
    }

    public var needsRefresh: Bool {
        guard let expiresAt else { return self.isRefreshable }
        let bufferTime: TimeInterval = 5 * 60
        return expiresAt.timeIntervalSinceNow < bufferTime
    }
}

public enum AntigravityOAuthConfig {
    // Public OAuth client credentials for Antigravity service.
    // These are meant to be embedded in client applications and are distributed with the app.
    // They are visible in OAuth flows to users anyway; the actual security comes from
    // the refresh/access tokens stored in Keychain, not these public client identifiers.
    public static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    public static let clientSecret = "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"
    public static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]
    public static let tokenURL = "https://oauth2.googleapis.com/token"
    public static let authURL = "https://accounts.google.com/o/oauth2/auth"
    public static let userInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"
    public static let callbackHost = "127.0.0.1"
    public static let callbackPortStart = 11451
    public static let callbackPortRange = 100
}

public enum AntigravityOAuthCredentialsError: LocalizedError, Sendable {
    case notFound
    case decodeFailed(String)
    case missingAccessToken
    case refreshFailed(String)
    case invalidGrant
    case networkError(String)
    case keychainError(Int)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Antigravity credentials not found. Sign in with Google to add an OAuth account."
        case let .decodeFailed(message):
            "Failed to decode Antigravity credentials: \(message)"
        case .missingAccessToken:
            "Antigravity access token is missing."
        case let .refreshFailed(message):
            "Failed to refresh Antigravity token: \(message)"
        case .invalidGrant:
            "Antigravity refresh token is invalid. Please re-authorize."
        case let .networkError(message):
            "Antigravity network error: \(message)"
        case let .keychainError(status):
            "Antigravity keychain error: \(status)"
        }
    }
}

public enum AntigravityOAuthCredentialsStore {
    public static let manualTokenPrefix = "manual:"
    private static let log = CodexBarLog.logger(LogCategories.antigravity)
    public static let environmentAccountKey = "CODEXBAR_ANTIGRAVITY_ACCOUNT"
    private static let cacheCategory = "oauth.antigravity"

    public struct ManualTokenPayload: Sendable {
        public let accessToken: String
        public let refreshToken: String?

        public init(accessToken: String, refreshToken: String?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }

    struct CacheEntry: Codable, Sendable {
        let credentials: AntigravityOAuthCredentials
        let storedAt: Date
    }

    private nonisolated(unsafe) static var cachedCredentialsByLabel: [String: AntigravityOAuthCredentials] = [:]
    private nonisolated(unsafe) static var cacheTimestampByLabel: [String: Date] = [:]
    private static let memoryCacheValidityDuration: TimeInterval = 1800

    public static func normalizedLabel(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    public static func manualTokenPayload(from token: String) -> ManualTokenPayload? {
        guard token.hasPrefix(self.manualTokenPrefix) else { return nil }
        let content = String(token.dropFirst(self.manualTokenPrefix.count))
        if let jsonData = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String],
           let accessToken = json["access"],
           !accessToken.isEmpty
        {
            return ManualTokenPayload(accessToken: accessToken, refreshToken: json["refresh"])
        }
        guard !content.isEmpty else { return nil }
        return ManualTokenPayload(accessToken: content, refreshToken: nil)
    }

    public static func manualTokenValue(accessToken: String, refreshToken: String?) -> String {
        let trimmedAccess = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRefresh = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refresh = trimmedRefresh, !refresh.isEmpty {
            let tokenData = ["access": trimmedAccess, "refresh": refresh]
            if let jsonData = try? JSONSerialization.data(withJSONObject: tokenData),
               let jsonString = String(data: jsonData, encoding: .utf8)
            {
                return "\(self.manualTokenPrefix)\(jsonString)"
            }
        }
        return "\(self.manualTokenPrefix)\(trimmedAccess)"
    }

    public static func load(accountLabel: String) -> AntigravityOAuthCredentials? {
        guard let normalized = self.normalizedLabel(accountLabel) else { return nil }
        guard !KeychainAccessGate.isDisabled else { return nil }

        if let cached = self.cachedCredentialsByLabel[normalized],
           let timestamp = self.cacheTimestampByLabel[normalized],
           Date().timeIntervalSince(timestamp) < self.memoryCacheValidityDuration,
           !cached.isExpired
        {
            return cached
        }

        switch KeychainCacheStore.load(key: self.key(for: normalized), as: CacheEntry.self) {
        case let .found(entry):
            if entry.credentials.isExpired, !entry.credentials.isRefreshable {
                self.log.debug("Antigravity cached credentials expired and not refreshable")
                return entry.credentials
            }
            self.cachedCredentialsByLabel[normalized] = entry.credentials
            self.cacheTimestampByLabel[normalized] = Date()
            return entry.credentials
        case .invalid:
            KeychainCacheStore.clear(key: self.key(for: normalized))
            self.cachedCredentialsByLabel.removeValue(forKey: normalized)
            self.cacheTimestampByLabel.removeValue(forKey: normalized)
            return nil
        case .missing:
            return nil
        }
    }

    public static func save(_ credentials: AntigravityOAuthCredentials, accountLabel: String) -> Bool {
        guard let normalized = self.normalizedLabel(accountLabel) else { return false }
        guard !KeychainAccessGate.isDisabled else {
            self.log.error("Antigravity OAuth save failed: keychain access disabled")
            return false
        }

        self.saveToKeychain(credentials, normalizedLabel: normalized)
        return true
    }

    public static func clear(accountLabel: String) {
        guard let normalized = self.normalizedLabel(accountLabel) else { return }
        KeychainCacheStore.clear(key: self.key(for: normalized))
        self.cachedCredentialsByLabel.removeValue(forKey: normalized)
        self.cacheTimestampByLabel.removeValue(forKey: normalized)
        self.log.info("Antigravity credentials cleared", metadata: [
            "label": normalized,
        ])
    }

    public static func invalidateCache() {
        self.cachedCredentialsByLabel.removeAll()
        self.cacheTimestampByLabel.removeAll()
    }

    private static func saveToKeychain(_ credentials: AntigravityOAuthCredentials, normalizedLabel: String) {
        let entry = CacheEntry(credentials: credentials, storedAt: Date())
        KeychainCacheStore.store(key: self.key(for: normalizedLabel), entry: entry)
        self.cachedCredentialsByLabel[normalizedLabel] = credentials
        self.cacheTimestampByLabel[normalizedLabel] = Date()
        self.log.info("Antigravity credentials saved", metadata: [
            "label": normalizedLabel,
            "email": credentials.email ?? "unknown",
            "hasRefreshToken": "\(credentials.isRefreshable)",
        ])
    }

    private static func key(for normalizedLabel: String) -> KeychainCacheStore.Key {
        KeychainCacheStore.Key(category: self.cacheCategory, identifier: normalizedLabel)
    }
}
