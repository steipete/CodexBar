import Foundation
#if os(macOS)
import Security
#endif

public struct ClaudeOAuthCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let rateLimitTier: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        rateLimitTier: String?)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.rateLimitTier = rateLimitTier
    }

    public var isExpired: Bool {
        guard let expiresAt else { return true }
        return Date() >= expiresAt
    }

    public var expiresIn: TimeInterval? {
        guard let expiresAt else { return nil }
        return expiresAt.timeIntervalSinceNow
    }

    public static func parse(data: Data) throws -> ClaudeOAuthCredentials {
        let decoder = JSONDecoder()
        guard let root = try? decoder.decode(Root.self, from: data) else {
            throw ClaudeOAuthCredentialsError.decodeFailed
        }
        guard let oauth = root.claudeAiOauth else {
            throw ClaudeOAuthCredentialsError.missingOAuth
        }
        let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw ClaudeOAuthCredentialsError.missingAccessToken
        }
        let expiresAt = oauth.expiresAt.map { millis in
            Date(timeIntervalSince1970: millis / 1000.0)
        }
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauth.refreshToken,
            expiresAt: expiresAt,
            scopes: oauth.scopes ?? [],
            rateLimitTier: oauth.rateLimitTier)
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let scopes: [String]?
        let rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case accessToken
            case refreshToken
            case expiresAt
            case scopes
            case rateLimitTier
        }
    }
}

public enum ClaudeOAuthCredentialsError: LocalizedError, Sendable {
    case decodeFailed
    case missingOAuth
    case missingAccessToken
    case notFound
    case keychainError(Int)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .decodeFailed:
            "Claude OAuth credentials are invalid."
        case .missingOAuth:
            "Claude OAuth credentials missing. Run `claude` to authenticate."
        case .missingAccessToken:
            "Claude OAuth access token missing. Run `claude` to authenticate."
        case .notFound:
            "Claude OAuth credentials not found. Run `claude` to authenticate."
        case let .keychainError(status):
            "Claude OAuth keychain error: \(status)"
        case let .readFailed(message):
            "Claude OAuth credentials read failed: \(message)"
        }
    }
}

public enum ClaudeOAuthCredentialsStore {
    private static let credentialsPath = ".claude/.credentials.json"
    // Claude CLI's keychain service (owned by Claude, may prompt on access)
    private static let claudeKeychainService = "Claude Code-credentials"
    // CodexBar's cached copy (owned by CodexBar, no prompts)
    private static let cacheKeychainService = "com.steipete.codexbar.claude-oauth-cache"

    // In-memory cache (nonisolated for synchronous access)
    private nonisolated(unsafe) static var cachedCredentials: ClaudeOAuthCredentials?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    // In-memory cache valid for 30 minutes (keychain cache persists longer)
    private static let memoryCacheValidityDuration: TimeInterval = 1800
    // Refresh from Claude's keychain when token expires within this buffer
    private static let tokenExpiryBuffer: TimeInterval = 300 // 5 minutes

    public static func load() throws -> ClaudeOAuthCredentials {
        // 1. Check in-memory cache first
        if let cached = self.cachedCredentials,
           let timestamp = self.cacheTimestamp,
           Date().timeIntervalSince(timestamp) < self.memoryCacheValidityDuration,
           !self.isTokenExpiringSoon(cached)
        {
            return cached
        }

        // 2. Try CodexBar's persistent keychain cache (no prompts)
        #if os(macOS)
        if let cachedData = try? self.loadFromCacheKeychain() {
            if let creds = try? ClaudeOAuthCredentials.parse(data: cachedData),
               !self.isTokenExpiringSoon(creds)
            {
                self.cachedCredentials = creds
                self.cacheTimestamp = Date()
                return creds
            }
            // Cache exists but token is expiring, fall through to refresh
        }
        #endif

        // 3. Try file (no keychain prompt)
        if let fileData = try? self.loadFromFile() {
            if let creds = try? ClaudeOAuthCredentials.parse(data: fileData) {
                self.cachedCredentials = creds
                self.cacheTimestamp = Date()
                #if os(macOS)
                self.saveToCacheKeychain(fileData)
                #endif
                return creds
            }
        }

        // 4. Fall back to Claude's keychain (may prompt user)
        var lastError: Error?
        if let keychainData = try? self.loadFromClaudeKeychain() {
            do {
                let creds = try ClaudeOAuthCredentials.parse(data: keychainData)
                self.cachedCredentials = creds
                self.cacheTimestamp = Date()
                #if os(macOS)
                self.saveToCacheKeychain(keychainData)
                #endif
                return creds
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        throw ClaudeOAuthCredentialsError.notFound
    }

    private static func isTokenExpiringSoon(_ credentials: ClaudeOAuthCredentials) -> Bool {
        guard let expiresAt = credentials.expiresAt else {
            return false // No expiry info, assume valid
        }
        return expiresAt.timeIntervalSinceNow < self.tokenExpiryBuffer
    }

    public static func loadFromFile() throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(self.credentialsPath)
        do {
            return try Data(contentsOf: url)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                throw ClaudeOAuthCredentialsError.notFound
            }
            throw ClaudeOAuthCredentialsError.readFailed(error.localizedDescription)
        }
    }

    /// Invalidate the credentials cache (call after login/logout)
    public static func invalidateCache() {
        self.cachedCredentials = nil
        self.cacheTimestamp = nil
        #if os(macOS)
        self.clearCacheKeychain()
        #endif
    }

    // MARK: - Claude's Keychain (may prompt)

    /// Loads from Claude CLI's keychain item. This may trigger a system keychain prompt
    /// because the item is owned by Claude CLI, not CodexBar.
    public static func loadFromClaudeKeychain() throws -> Data {
        #if os(macOS)
        if case .interactionRequired = KeychainAccessPreflight
            .checkGenericPassword(service: self.claudeKeychainService, account: nil)
        {
            KeychainPromptHandler.handler?(KeychainPromptContext(
                kind: .claudeOAuth,
                service: self.claudeKeychainService,
                account: nil))
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw ClaudeOAuthCredentialsError.readFailed("Keychain item is empty.")
            }
            if data.isEmpty { throw ClaudeOAuthCredentialsError.notFound }
            return data
        case errSecItemNotFound:
            throw ClaudeOAuthCredentialsError.notFound
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
        #else
        throw ClaudeOAuthCredentialsError.notFound
        #endif
    }

    /// Legacy alias for backward compatibility
    public static func loadFromKeychain() throws -> Data {
        try self.loadFromClaudeKeychain()
    }

    // MARK: - CodexBar's Cache Keychain (no prompts)

    #if os(macOS)
    /// Loads from CodexBar's own keychain cache. This never prompts because CodexBar owns this item.
    private static func loadFromCacheKeychain() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.cacheKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw ClaudeOAuthCredentialsError.readFailed("Cache keychain item is empty.")
            }
            return data
        case errSecItemNotFound:
            throw ClaudeOAuthCredentialsError.notFound
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
    }

    /// Saves credentials to CodexBar's own keychain cache.
    private static func saveToCacheKeychain(_ data: Data) {
        // First try to update existing item
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.cacheKeychainService,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]

        var status = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecItemNotFound {
            // Item doesn't exist, create it
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.cacheKeychainService,
                kSecAttrLabel as String: "CodexBar Claude OAuth Cache",
                kSecValueData as String: data,
                // Use ThisDeviceOnly to avoid keychain prompts on code signature changes
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess && status != errSecDuplicateItem {
            // Log error but don't fail - cache is best-effort
            CodexBarLog.logger("claude-oauth").debug(
                "Failed to save to cache keychain: \(status)")
        }
    }

    /// Clears CodexBar's keychain cache.
    private static func clearCacheKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.cacheKeychainService,
        ]
        SecItemDelete(query as CFDictionary)
    }
    #endif
}
