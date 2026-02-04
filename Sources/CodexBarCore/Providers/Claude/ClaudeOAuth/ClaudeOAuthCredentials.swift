import Foundation

#if os(macOS)
    import LocalAuthentication
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
        rateLimitTier: String?
    ) {
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
    case refreshFailed(String)
    case noRefreshToken

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
        case .keychainError(let status):
            "Claude OAuth keychain error: \(status)"
        case .readFailed(let message):
            "Claude OAuth credentials read failed: \(message)"
        case .refreshFailed(let message):
            "Claude OAuth token refresh failed: \(message). Run `claude` to re-authenticate."
        case .noRefreshToken:
            "Claude OAuth refresh token missing. Run `claude` to authenticate."
        }
    }
}

public enum ClaudeOAuthCredentialsStore {
    private static let credentialsPath = ".claude/.credentials.json"
    private static let claudeKeychainService = "Claude Code-credentials"
    private static let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
    public static let environmentTokenKey = "CODEXBAR_CLAUDE_OAUTH_TOKEN"
    public static let environmentScopesKey = "CODEXBAR_CLAUDE_OAUTH_SCOPES"

    // Claude CLI's OAuth client ID - this is a public identifier (not a secret).
    // It's the same client ID used by Claude Code CLI for OAuth PKCE flow.
    // Can be overridden via environment variable if Anthropic ever changes it.
    public static let defaultOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let environmentClientIDKey = "CODEXBAR_CLAUDE_OAUTH_CLIENT_ID"
    private static let tokenRefreshEndpoint = "https://console.anthropic.com/v1/oauth/token"

    private static var oauthClientID: String {
        ProcessInfo.processInfo.environment[self.environmentClientIDKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? self.defaultOAuthClientID
    }

    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static let fileFingerprintKey = "ClaudeOAuthCredentialsFileFingerprintV1"

    #if DEBUG
        private nonisolated(unsafe) static var keychainAccessOverride: Bool?
        static func setKeychainAccessOverrideForTesting(_ disabled: Bool?) {
            self.keychainAccessOverride = disabled
        }
    #endif

    private struct CredentialsFileFingerprint: Codable, Equatable, Sendable {
        let modifiedAt: Int?
        let size: Int
    }

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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true
    ) throws -> ClaudeOAuthCredentials {
        if let credentials = self.loadFromEnvironment(environment) {
            return credentials
        }

        _ = self.invalidateCacheIfCredentialsFileChanged()
        _ = self.invalidateCacheIfClaudeKeychainChanged()

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
        case .found(let entry):
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

        // 4. Fall back to Claude's keychain (may prompt user if allowed)
        if allowKeychainPrompt {
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
        } else {
            // Try without prompting
            if let keychainData = try? self.loadFromClaudeKeychainWithoutPrompt() {
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
        }

        if let expiredCredentials {
            return expiredCredentials
        }
        if let lastError { throw lastError }
        throw ClaudeOAuthCredentialsError.notFound
    }

    /// Async version of load that automatically refreshes expired tokens.
    /// This is the preferred method - it will refresh tokens using the refresh token
    /// and update CodexBar's keychain cache, so users won't be prompted again
    /// unless they switch accounts.
    public static func loadWithAutoRefresh(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true
    ) async throws -> ClaudeOAuthCredentials {
        let credentials = try self.load(environment: environment, allowKeychainPrompt: allowKeychainPrompt)

        // If not expired, return as-is
        guard credentials.isExpired else {
            return credentials
        }

        // Try to refresh if we have a refresh token
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            self.log.warning("Token expired but no refresh token available")
            throw ClaudeOAuthCredentialsError.noRefreshToken
        }

        self.log.info("Access token expired, attempting auto-refresh")

        do {
            let refreshed = try await self.refreshAccessToken(
                refreshToken: refreshToken,
                existingScopes: credentials.scopes,
                existingRateLimitTier: credentials.rateLimitTier
            )
            self.log.info("Token refresh successful, expires in \(refreshed.expiresIn ?? 0) seconds")
            return refreshed
        } catch {
            self.log.error("Token refresh failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Refresh the access token using a refresh token.
    /// Updates CodexBar's keychain cache with the new credentials.
    public static func refreshAccessToken(
        refreshToken: String,
        existingScopes: [String],
        existingRateLimitTier: String?
    ) async throws -> ClaudeOAuthCredentials {
        guard let url = URL(string: self.tokenRefreshEndpoint) else {
            throw ClaudeOAuthCredentialsError.refreshFailed("Invalid token endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": self.oauthClientID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthCredentialsError.refreshFailed("Invalid response")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            if http.statusCode == 401 || http.statusCode == 400 {
                // Refresh token is invalid/expired - user needs to re-authenticate
                self.invalidateCache()
                throw ClaudeOAuthCredentialsError.refreshFailed("Refresh token expired (\(http.statusCode))")
            }
            throw ClaudeOAuthCredentialsError.refreshFailed("HTTP \(http.statusCode): \(body)")
        }

        // Parse the token response
        let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)

        let expiresAt = Date(timeIntervalSinceNow: TimeInterval(tokenResponse.expiresIn))

        let newCredentials = ClaudeOAuthCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expiresAt: expiresAt,
            scopes: existingScopes,
            rateLimitTier: existingRateLimitTier
        )

        // Save to CodexBar's keychain cache (not Claude's keychain)
        self.saveRefreshedCredentialsToCache(newCredentials)

        // Update in-memory cache
        self.cachedCredentials = newCredentials
        self.cacheTimestamp = Date()

        return newCredentials
    }

    /// Save refreshed credentials to CodexBar's keychain cache
    private static func saveRefreshedCredentialsToCache(_ credentials: ClaudeOAuthCredentials) {
        // Build the same JSON structure that Claude CLI uses
        let oauthData: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": credentials.accessToken,
                "refreshToken": credentials.refreshToken as Any,
                "expiresAt": (credentials.expiresAt?.timeIntervalSince1970 ?? 0) * 1000,
                "scopes": credentials.scopes,
                "rateLimitTier": credentials.rateLimitTier as Any,
            ],
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: oauthData) else {
            self.log.error("Failed to serialize refreshed credentials for cache")
            return
        }

        self.saveToCacheKeychain(jsonData)
        self.log.debug("Saved refreshed credentials to CodexBar keychain cache")
    }

    /// Response from the OAuth token refresh endpoint
    private struct TokenRefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    public static func loadFromFile() throws -> Data {
        let url = self.credentialsFileURL()
        do {
            return try Data(contentsOf: url)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                throw ClaudeOAuthCredentialsError.notFound
            }
            throw ClaudeOAuthCredentialsError.readFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public static func invalidateCacheIfCredentialsFileChanged() -> Bool {
        let current = self.currentFileFingerprint()
        let stored = self.loadFileFingerprint()
        guard current != stored else { return false }
        self.saveFileFingerprint(current)
        self.log.info("Claude OAuth credentials file changed; invalidating cache")
        self.invalidateCache()
        return true
    }

    /// Check if Claude's keychain has different credentials than our cache
    /// and invalidate if so (detects account switches when no file exists)
    @discardableResult
    public static func invalidateCacheIfClaudeKeychainChanged() -> Bool {
        // Only check if keychain access is allowed
        #if os(macOS)
            guard self.keychainAccessAllowed else { return false }

            // Check if we would need to prompt the user - if so, skip this check
            // to avoid unexpected prompts during cache validation
            if case .interactionRequired =
                KeychainAccessPreflight
                .checkGenericPassword(service: self.claudeKeychainService, account: nil)
            {
                return false
            }

            // Load cached credentials from CodexBar's keychain
            guard
                case .found(let entry) = KeychainCacheStore.load(
                    key: self.cacheKey, as: CacheEntry.self),
                let cachedCreds = try? ClaudeOAuthCredentials.parse(data: entry.data)
            else {
                return false
            }

            // Load current credentials from Claude's keychain
            guard let keychainData = try? self.loadFromClaudeKeychainWithoutPrompt(),
                let keychainCreds = try? ClaudeOAuthCredentials.parse(data: keychainData)
            else {
                return false
            }

            // Compare access tokens - if different, the user switched accounts
            guard cachedCreds.accessToken != keychainCreds.accessToken else { return false }

            self.log.info(
                "Claude keychain credentials changed (account switch detected); invalidating cache")
            self.invalidateCache()
            return true
        #else
            return false
        #endif
    }

    /// Invalidate the credentials cache (call after login/logout)
    public static func invalidateCache() {
        self.cachedCredentials = nil
        self.cacheTimestamp = nil
        self.clearCacheKeychain()
    }

    /// Check if CodexBar has cached credentials (in memory or keychain cache)
    public static func hasCachedCredentials() -> Bool {
        // Check in-memory cache
        if let timestamp = self.cacheTimestamp,
            Date().timeIntervalSince(timestamp) < self.memoryCacheValidityDuration
        {
            return true
        }
        // Check keychain cache
        switch KeychainCacheStore.load(key: self.cacheKey, as: CacheEntry.self) {
        case .found: return true
        default: return false
        }
    }

    public static func loadFromClaudeKeychain() throws -> Data {
        #if os(macOS)
            if !self.keychainAccessAllowed {
                throw ClaudeOAuthCredentialsError.notFound
            }
            if case .interactionRequired =
                KeychainAccessPreflight
                .checkGenericPassword(service: self.claudeKeychainService, account: nil)
            {
                KeychainPromptHandler.handler?(
                    KeychainPromptContext(
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

    /// Load from Claude's keychain without triggering a user prompt.
    /// Returns nil if interaction would be required.
    private static func loadFromClaudeKeychainWithoutPrompt() throws -> Data? {
        #if os(macOS)
            // Use LAContext with interactionNotAllowed to prevent any prompts
            let context = LAContext()
            context.interactionNotAllowed = true

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.claudeKeychainService,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, !data.isEmpty else {
                    return nil
                }
                return data
            case errSecItemNotFound:
                return nil
            case errSecInteractionNotAllowed:
                // Keychain requires user interaction, skip silently
                return nil
            default:
                return nil
            }
        #else
            return nil
        #endif
    }

    private static func loadFromEnvironment(_ environment: [String: String])
        -> ClaudeOAuthCredentials?
    {
        guard
            let token = environment[self.environmentTokenKey]?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }

        let scopes: [String] = {
            guard let raw = environment[self.environmentScopesKey] else { return ["user:profile"] }
            let parsed =
                raw
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

    private static var keychainAccessAllowed: Bool {
        #if DEBUG
            if let override = self.keychainAccessOverride {
                return !override
            }
        #endif
        return !KeychainAccessGate.isDisabled
    }

    private static func credentialsFileURL() -> URL {
        self.credentialsURLOverride ?? Self.defaultCredentialsURL()
    }

    private static func loadFileFingerprint() -> CredentialsFileFingerprint? {
        guard let data = UserDefaults.standard.data(forKey: self.fileFingerprintKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CredentialsFileFingerprint.self, from: data)
    }

    private static func saveFileFingerprint(_ fingerprint: CredentialsFileFingerprint?) {
        guard let fingerprint else {
            UserDefaults.standard.removeObject(forKey: self.fileFingerprintKey)
            return
        }
        if let data = try? JSONEncoder().encode(fingerprint) {
            UserDefaults.standard.set(data, forKey: self.fileFingerprintKey)
        }
    }

    private static func currentFileFingerprint() -> CredentialsFileFingerprint? {
        let url = self.credentialsFileURL()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modifiedAt = (attrs[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) }
        return CredentialsFileFingerprint(modifiedAt: modifiedAt, size: size)
    }

    #if DEBUG
        static func _resetCredentialsFileTrackingForTesting() {
            UserDefaults.standard.removeObject(forKey: self.fileFingerprintKey)
        }
    #endif

    private static func defaultCredentialsURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(self.credentialsPath)
    }
}
