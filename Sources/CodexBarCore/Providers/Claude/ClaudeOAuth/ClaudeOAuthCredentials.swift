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
    private static let claudeKeychainService = "Claude Code-credentials"
    private static let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
    public static let environmentTokenKey = "CODEXBAR_CLAUDE_OAUTH_TOKEN"
    public static let environmentScopesKey = "CODEXBAR_CLAUDE_OAUTH_SCOPES"

    struct CacheEntry: Codable, Sendable {
        let data: Data
        let storedAt: Date
    }

    private nonisolated(unsafe) static var credentialsURLOverride: URL?
    // In-memory cache (nonisolated for synchronous access)
    private nonisolated(unsafe) static var cachedCredentials: ClaudeOAuthCredentials?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    private static let memoryCacheValidityDuration: TimeInterval = 1800

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ClaudeOAuthCredentials
    {
        if let credentials = self.loadFromEnvironment(environment) {
            return credentials
        }

        // 1. Check in-memory cache first
        if let cached = self.cachedCredentials,
           let timestamp = self.cacheTimestamp,
           Date().timeIntervalSince(timestamp) < self.memoryCacheValidityDuration,
           !cached.isExpired
        {
            return cached
        }

        var lastError: Error?
        var expiredCredentials: ClaudeOAuthCredentials?

        // 2. Try CodexBar's keychain cache (no prompts)
        switch KeychainCacheStore.load(key: self.cacheKey, as: CacheEntry.self) {
        case let .found(entry):
            if let creds = try? ClaudeOAuthCredentials.parse(data: entry.data) {
                if creds.isExpired {
                    expiredCredentials = creds
                } else {
                    self.cachedCredentials = creds
                    self.cacheTimestamp = Date()
                    return creds
                }
            } else {
                KeychainCacheStore.clear(key: self.cacheKey)
            }
        case .invalid:
            KeychainCacheStore.clear(key: self.cacheKey)
        case .missing:
            break
        }

        // 3. Try file (no keychain prompt)
        do {
            let fileData = try self.loadFromFile()
            let creds = try ClaudeOAuthCredentials.parse(data: fileData)
            if creds.isExpired {
                expiredCredentials = creds
            } else {
                self.cachedCredentials = creds
                self.cacheTimestamp = Date()
                self.saveToCacheKeychain(fileData)
                return creds
            }
        } catch let error as ClaudeOAuthCredentialsError {
            if case .notFound = error {
                // Ignore missing file
            } else {
                lastError = error
            }
        } catch {
            lastError = error
        }

        // 4. Fall back to Claude's keychain (may prompt user)
        if let keychainData = try? self.loadFromClaudeKeychain() {
            do {
                let creds = try ClaudeOAuthCredentials.parse(data: keychainData)
                self.cachedCredentials = creds
                self.cacheTimestamp = Date()
                self.saveToCacheKeychain(keychainData)
                return creds
            } catch {
                lastError = error
            }
        }

        if let expiredCredentials {
            return expiredCredentials
        }
        if let lastError { throw lastError }
        throw ClaudeOAuthCredentialsError.notFound
    }

    public static func loadFromFile() throws -> Data {
        let url = self.credentialsURLOverride ?? Self.defaultCredentialsURL()
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
        self.clearCacheKeychain()
    }

    public static func loadFromClaudeKeychain() throws -> Data {
        #if os(macOS)
        if KeychainAccessGate.isDisabled {
            throw ClaudeOAuthCredentialsError.notFound
        }
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

    private static func loadFromEnvironment(_ environment: [String: String]) -> ClaudeOAuthCredentials? {
        guard let token = environment[self.environmentTokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }

        let scopes: [String] = {
            guard let raw = environment[self.environmentScopesKey] else { return ["user:profile"] }
            let parsed = raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parsed.isEmpty ? ["user:profile"] : parsed
        }()

        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: Date.distantFuture,
            scopes: scopes,
            rateLimitTier: nil)
    }

    static func setCredentialsURLOverrideForTesting(_ url: URL?) {
        self.credentialsURLOverride = url
    }

    private static func saveToCacheKeychain(_ data: Data) {
        let entry = CacheEntry(data: data, storedAt: Date())
        KeychainCacheStore.store(key: self.cacheKey, entry: entry)
    }

    private static func clearCacheKeychain() {
        KeychainCacheStore.clear(key: self.cacheKey)
    }

    private static func defaultCredentialsURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(self.credentialsPath)
    }
}
