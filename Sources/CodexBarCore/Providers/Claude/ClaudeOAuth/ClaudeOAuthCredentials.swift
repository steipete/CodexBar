import Dispatch
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

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

public enum ClaudeOAuthCredentialOwner: String, Codable, Sendable {
    case claudeCLI
    case codexbar
    case environment
}

public enum ClaudeOAuthCredentialSource: String, Sendable {
    case environment
    case memoryCache
    case cacheKeychain
    case credentialsFile
    case claudeKeychain
}

public struct ClaudeOAuthCredentialRecord: Sendable {
    public let credentials: ClaudeOAuthCredentials
    public let owner: ClaudeOAuthCredentialOwner
    public let source: ClaudeOAuthCredentialSource

    public init(
        credentials: ClaudeOAuthCredentials,
        owner: ClaudeOAuthCredentialOwner,
        source: ClaudeOAuthCredentialSource)
    {
        self.credentials = credentials
        self.owner = owner
        self.source = source
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
    case refreshDelegatedToClaudeCLI

    public var errorDescription: String? {
        switch self {
        case .decodeFailed:
            return "Claude OAuth credentials are invalid."
        case .missingOAuth:
            return "Claude OAuth credentials missing. Run `claude` to authenticate."
        case .missingAccessToken:
            return "Claude OAuth access token missing. Run `claude` to authenticate."
        case .notFound:
            return "Claude OAuth credentials not found. Run `claude` to authenticate."
        case let .keychainError(status):
            #if os(macOS)
            if status == Int(errSecUserCanceled)
                || status == Int(errSecAuthFailed)
                || status == Int(errSecInteractionNotAllowed)
                || status == Int(errSecNoAccessForItem)
            {
                return "Claude Keychain access was denied. CodexBar won’t ask again for 6 hours in Auto mode. "
                    + "Switch Claude Usage source to Web/CLI, or allow access in Keychain Access."
            }
            #endif
            return "Claude OAuth keychain error: \(status)"
        case let .readFailed(message):
            return "Claude OAuth credentials read failed: \(message)"
        case let .refreshFailed(message):
            return "Claude OAuth token refresh failed: \(message)"
        case .noRefreshToken:
            return "Claude OAuth refresh token missing. Run `claude` to authenticate."
        case .refreshDelegatedToClaudeCLI:
            return "Claude OAuth refresh is delegated to Claude CLI."
        }
    }
}

// swiftlint:disable type_body_length
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
    private static let tokenRefreshEndpoint = "https://platform.claude.com/v1/oauth/token"

    private static var oauthClientID: String {
        ProcessInfo.processInfo.environment[self.environmentClientIDKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? self.defaultOAuthClientID
    }

    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static let fileFingerprintKey = "ClaudeOAuthCredentialsFileFingerprintV1"
    private static let claudeKeychainPromptLock = NSLock()
    private static let claudeKeychainFingerprintKey = "ClaudeOAuthClaudeKeychainFingerprintV2"
    private static let claudeKeychainFingerprintLegacyKey = "ClaudeOAuthClaudeKeychainFingerprintV1"
    private static let claudeKeychainChangeCheckLock = NSLock()
    private nonisolated(unsafe) static var lastClaudeKeychainChangeCheckAt: Date?
    private static let claudeKeychainChangeCheckMinimumInterval: TimeInterval = 60
    private static let reauthenticateHint = "Run `claude` to re-authenticate."

    struct ClaudeKeychainFingerprint: Codable, Equatable, Sendable {
        let modifiedAt: Int?
        let createdAt: Int?
        let persistentRefHash: String?
    }

    #if DEBUG
    private nonisolated(unsafe) static var keychainAccessOverride: Bool?
    private nonisolated(unsafe) static var claudeKeychainDataOverride: Data?
    private nonisolated(unsafe) static var claudeKeychainFingerprintOverride: ClaudeKeychainFingerprint?
    @TaskLocal private static var taskClaudeKeychainDataOverride: Data?
    @TaskLocal private static var taskClaudeKeychainFingerprintOverride: ClaudeKeychainFingerprint?
    final class ClaudeKeychainFingerprintStore: @unchecked Sendable {
        var fingerprint: ClaudeKeychainFingerprint?

        init(fingerprint: ClaudeKeychainFingerprint? = nil) {
            self.fingerprint = fingerprint
        }
    }

    @TaskLocal private static var taskClaudeKeychainFingerprintStoreOverride: ClaudeKeychainFingerprintStore?
    static func setKeychainAccessOverrideForTesting(_ disabled: Bool?) {
        self.keychainAccessOverride = disabled
    }

    static func setClaudeKeychainDataOverrideForTesting(_ data: Data?) {
        self.claudeKeychainDataOverride = data
    }

    static func setClaudeKeychainFingerprintOverrideForTesting(_ fingerprint: ClaudeKeychainFingerprint?) {
        self.claudeKeychainFingerprintOverride = fingerprint
    }

    static func withClaudeKeychainOverridesForTesting<T>(
        data: Data?,
        fingerprint: ClaudeKeychainFingerprint?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskClaudeKeychainDataOverride.withValue(data) {
            try self.$taskClaudeKeychainFingerprintOverride.withValue(fingerprint) {
                try operation()
            }
        }
    }

    static func withClaudeKeychainOverridesForTesting<T>(
        data: Data?,
        fingerprint: ClaudeKeychainFingerprint?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskClaudeKeychainDataOverride.withValue(data) {
            try await self.$taskClaudeKeychainFingerprintOverride.withValue(fingerprint) {
                try await operation()
            }
        }
    }

    static func withClaudeKeychainFingerprintStoreOverrideForTesting<T>(
        _ store: ClaudeKeychainFingerprintStore?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskClaudeKeychainFingerprintStoreOverride.withValue(store) {
            try operation()
        }
    }

    static func withClaudeKeychainFingerprintStoreOverrideForTesting<T>(
        _ store: ClaudeKeychainFingerprintStore?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskClaudeKeychainFingerprintStoreOverride.withValue(store) {
            try await operation()
        }
    }
    #endif

    private struct CredentialsFileFingerprint: Codable, Equatable, Sendable {
        let modifiedAt: Int?
        let size: Int
    }

    struct CacheEntry: Codable, Sendable {
        let data: Data
        let storedAt: Date
        let owner: ClaudeOAuthCredentialOwner?

        init(data: Data, storedAt: Date, owner: ClaudeOAuthCredentialOwner? = nil) {
            self.data = data
            self.storedAt = storedAt
            self.owner = owner
        }
    }

    private nonisolated(unsafe) static var credentialsURLOverride: URL?
    // In-memory cache (nonisolated for synchronous access)
    private static let memoryCacheLock = NSLock()
    private nonisolated(unsafe) static var cachedCredentialRecord: ClaudeOAuthCredentialRecord?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    private static let memoryCacheValidityDuration: TimeInterval = 1800

    private static func readMemoryCache() -> (record: ClaudeOAuthCredentialRecord?, timestamp: Date?) {
        self.memoryCacheLock.lock()
        defer { self.memoryCacheLock.unlock() }
        return (self.cachedCredentialRecord, self.cacheTimestamp)
    }

    private static func writeMemoryCache(record: ClaudeOAuthCredentialRecord?, timestamp: Date?) {
        self.memoryCacheLock.lock()
        self.cachedCredentialRecord = record
        self.cacheTimestamp = timestamp
        self.memoryCacheLock.unlock()
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false) throws -> ClaudeOAuthCredentials
    {
        try self.loadRecord(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown).credentials
    }

    // swiftlint:disable:next cyclomatic_complexity
    public static func loadRecord(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false) throws -> ClaudeOAuthCredentialRecord
    {
        // "Silent" keychain probes can still show UI on some macOS configurations. If the caller disallows prompts,
        // always honor the Claude keychain access cooldown gate to prevent prompt storms in Auto-mode paths.
        let shouldRespectKeychainPromptCooldownForSilentProbes = respectKeychainPromptCooldown || !allowKeychainPrompt

        if let credentials = self.loadFromEnvironment(environment) {
            return ClaudeOAuthCredentialRecord(
                credentials: credentials,
                owner: .environment,
                source: .environment)
        }

        _ = self.invalidateCacheIfCredentialsFileChanged()

        let memory = self.readMemoryCache()
        if let cachedRecord = memory.record,
           let timestamp = memory.timestamp,
           Date().timeIntervalSince(timestamp) < self.memoryCacheValidityDuration,
           !cachedRecord.credentials.isExpired
        {
            if let synced = self.syncWithClaudeKeychainIfChanged(
                cached: cachedRecord,
                respectKeychainPromptCooldown: shouldRespectKeychainPromptCooldownForSilentProbes)
            {
                return synced
            }
            return ClaudeOAuthCredentialRecord(
                credentials: cachedRecord.credentials,
                owner: cachedRecord.owner,
                source: .memoryCache)
        }

        var lastError: Error?
        var expiredRecord: ClaudeOAuthCredentialRecord?

        // 2. Try CodexBar's keychain cache (no prompts)
        switch KeychainCacheStore.load(key: self.cacheKey, as: CacheEntry.self) {
        case let .found(entry):
            if let creds = try? ClaudeOAuthCredentials.parse(data: entry.data) {
                // Legacy cache entries (pre-owner field) may contain credentials that were originally sourced from
                // Claude Code (Keychain/file). Treating them as CodexBar-owned would re-enable direct refresh-token
                // rotation here, which risks desyncing Claude Code (it continues to hold the old refresh token).
                // Defaulting to `.claudeCLI` keeps refresh ownership with Claude Code.
                let owner = entry.owner ?? .claudeCLI
                let record = ClaudeOAuthCredentialRecord(
                    credentials: creds,
                    owner: owner,
                    source: .cacheKeychain)
                if creds.isExpired {
                    expiredRecord = record
                } else {
                    if let synced = self.syncWithClaudeKeychainIfChanged(
                        cached: record,
                        respectKeychainPromptCooldown: shouldRespectKeychainPromptCooldownForSilentProbes)
                    {
                        return synced
                    }
                    self.writeMemoryCache(
                        record: ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: owner,
                            source: .memoryCache),
                        timestamp: Date())
                    return record
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
            let record = ClaudeOAuthCredentialRecord(
                credentials: creds,
                owner: .claudeCLI,
                source: .credentialsFile)
            if creds.isExpired {
                expiredRecord = record
            } else {
                self.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .memoryCache),
                    timestamp: Date())
                self.saveToCacheKeychain(fileData, owner: .claudeCLI)
                return record
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
        let promptAllowed =
            allowKeychainPrompt
                && (!respectKeychainPromptCooldown || ClaudeOAuthKeychainAccessGate.shouldAllowPrompt())
        if promptAllowed {
            do {
                self.claudeKeychainPromptLock.lock()
                defer { self.claudeKeychainPromptLock.unlock() }

                // Multiple concurrent callers can all reach this point before the first one populates the cache.
                // Re-check the cache while holding the prompt lock to avoid triggering multiple OS keychain dialogs.
                let memory = self.readMemoryCache()
                if let cachedRecord = memory.record,
                   let timestamp = memory.timestamp,
                   Date().timeIntervalSince(timestamp) < self.memoryCacheValidityDuration,
                   !cachedRecord.credentials.isExpired
                {
                    return ClaudeOAuthCredentialRecord(
                        credentials: cachedRecord.credentials,
                        owner: cachedRecord.owner,
                        source: .memoryCache)
                }
                if case let .found(entry) = KeychainCacheStore.load(key: self.cacheKey, as: CacheEntry.self),
                   let creds = try? ClaudeOAuthCredentials.parse(data: entry.data),
                   !creds.isExpired
                {
                    return ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: entry.owner ?? .claudeCLI,
                        source: .cacheKeychain)
                }

                // Some macOS configurations still show the system keychain prompt even for our "silent" probes.
                // Only show the in-app pre-alert when we have evidence that Keychain interaction is likely.
                if self.shouldShowClaudeKeychainPreAlert() {
                    KeychainPromptHandler.handler?(
                        KeychainPromptContext(
                            kind: .claudeOAuth,
                            service: self.claudeKeychainService,
                            account: nil))
                }
                let keychainData = try self.loadFromClaudeKeychain()
                let creds = try ClaudeOAuthCredentials.parse(data: keychainData)
                let record = ClaudeOAuthCredentialRecord(
                    credentials: creds,
                    owner: .claudeCLI,
                    source: .claudeKeychain)
                self.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .memoryCache),
                    timestamp: Date())
                self.saveToCacheKeychain(keychainData, owner: .claudeCLI)
                return record
            } catch let error as ClaudeOAuthCredentialsError {
                if case .notFound = error {
                    // Ignore missing entry
                } else {
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }

        if let expiredRecord {
            return expiredRecord
        }
        if let lastError { throw lastError }
        throw ClaudeOAuthCredentialsError.notFound
    }

    /// Async version of load that handles expired tokens based on credential ownership.
    /// - Claude CLI-owned credentials delegate refresh to Claude CLI.
    /// - CodexBar-owned credentials refresh directly via token endpoint.
    public static func loadWithAutoRefresh(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false) async throws -> ClaudeOAuthCredentials
    {
        let record = try self.loadRecord(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown)
        let credentials = record.credentials

        // If not expired, return as-is
        guard credentials.isExpired else {
            return credentials
        }

        switch record.owner {
        case .claudeCLI:
            self.log.info(
                "Claude OAuth credentials expired; delegating refresh to Claude CLI",
                metadata: ["source": record.source.rawValue])
            throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
        case .environment:
            self.log.warning("Environment OAuth token expired and cannot be auto-refreshed")
            throw ClaudeOAuthCredentialsError.noRefreshToken
        case .codexbar:
            break
        }

        // Try to refresh if we have a refresh token.
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            self.log.warning("Token expired but no refresh token available")
            throw ClaudeOAuthCredentialsError.noRefreshToken
        }
        self.log.info("Access token expired, attempting auto-refresh")

        do {
            let refreshed = try await self.refreshAccessToken(
                refreshToken: refreshToken,
                existingScopes: credentials.scopes,
                existingRateLimitTier: credentials.rateLimitTier)
            self.log.info("Token refresh successful, expires in \(refreshed.expiresIn ?? 0) seconds")
            return refreshed
        } catch {
            self.log.error("Token refresh failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Save refreshed credentials to CodexBar's keychain cache
    private static func saveRefreshedCredentialsToCache(_ credentials: ClaudeOAuthCredentials) {
        var oauth: [String: Any] = [
            "accessToken": credentials.accessToken,
            "expiresAt": (credentials.expiresAt?.timeIntervalSince1970 ?? 0) * 1000,
            "scopes": credentials.scopes,
        ]

        if let refreshToken = credentials.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let rateLimitTier = credentials.rateLimitTier {
            oauth["rateLimitTier"] = rateLimitTier
        }

        let oauthData: [String: Any] = ["claudeAiOauth": oauth]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: oauthData) else {
            self.log.error("Failed to serialize refreshed credentials for cache")
            return
        }

        self.saveToCacheKeychain(jsonData, owner: .codexbar)
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
        // The credentials file can be stale (or even unrelated) compared to what we’ve already cached from the
        // keychain. Clearing the keychain cache unconditionally can cause us to prefer an expired file over a
        // still-valid cached token.
        //
        // We always drop the in-memory cache. The keychain cache is only cleared when it is older than the
        // credentials file (or the file disappeared), so we still pick up fresh file updates on next load.
        self.writeMemoryCache(record: nil, timestamp: nil)

        var shouldClearKeychainCache = false
        if let current {
            if let modifiedAtSeconds = current.modifiedAt {
                let modifiedAt = Date(timeIntervalSince1970: TimeInterval(modifiedAtSeconds))
                if case let .found(entry) = KeychainCacheStore.load(key: self.cacheKey, as: CacheEntry.self) {
                    if entry.storedAt < modifiedAt {
                        shouldClearKeychainCache = true
                    }
                } else {
                    // If we can’t load the cache entry, there’s nothing meaningful to preserve here.
                    shouldClearKeychainCache = true
                }
            } else {
                // If we can’t compare timestamps, be conservative and clear the keychain cache.
                shouldClearKeychainCache = true
            }
        } else {
            // File was removed; cached values are likely stale (e.g. logout).
            shouldClearKeychainCache = true
        }

        if shouldClearKeychainCache {
            self.clearCacheKeychain()
        }
        return true
    }

    /// Invalidate the credentials cache (call after login/logout)
    public static func invalidateCache() {
        self.writeMemoryCache(record: nil, timestamp: nil)
        self.clearCacheKeychain()
    }

    /// Check if CodexBar has cached credentials (in memory or keychain cache)
    public static func hasCachedCredentials(environment: [String: String] = ProcessInfo.processInfo
        .environment) -> Bool
    {
        func isRefreshableOrValid(_ record: ClaudeOAuthCredentialRecord) -> Bool {
            let creds = record.credentials
            if !creds.isExpired { return true }
            switch record.owner {
            case .claudeCLI:
                // Claude CLI can refresh its own credentials once invoked, even if no refresh token is visible here.
                return true
            case .codexbar:
                let refreshToken = creds.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !refreshToken.isEmpty
            case .environment:
                return false
            }
        }

        if let creds = self.loadFromEnvironment(environment),
           isRefreshableOrValid(ClaudeOAuthCredentialRecord(
               credentials: creds,
               owner: .environment,
               source: .environment))
        {
            return true
        }

        // Check in-memory cache
        let memory = self.readMemoryCache()
        if let timestamp = memory.timestamp,
           let cached = memory.record,
           Date().timeIntervalSince(timestamp) < self.memoryCacheValidityDuration,
           isRefreshableOrValid(cached)
        {
            return true
        }
        // Check keychain cache (must be parseable; may be expired but still refreshable without prompting)
        switch KeychainCacheStore.load(key: self.cacheKey, as: CacheEntry.self) {
        case let .found(entry):
            guard let creds = try? ClaudeOAuthCredentials.parse(data: entry.data) else { return false }
            let record = ClaudeOAuthCredentialRecord(
                credentials: creds,
                owner: entry.owner ?? .claudeCLI,
                source: .cacheKeychain)
            return isRefreshableOrValid(record)
        default:
            break
        }

        // Check credentials file (no prompts)
        if let fileData = try? self.loadFromFile(),
           let creds = try? ClaudeOAuthCredentials.parse(data: fileData),
           isRefreshableOrValid(ClaudeOAuthCredentialRecord(
               credentials: creds,
               owner: .claudeCLI,
               source: .credentialsFile))
        {
            return true
        }
        return false
    }

    public static func hasClaudeKeychainCredentialsWithoutPrompt() -> Bool {
        #if os(macOS)
        if !self.keychainAccessAllowed { return false }

        if !self.claudeKeychainCandidatesWithoutPrompt().isEmpty {
            return true
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        case errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem:
            // Treat denial as "not available" and record a cooldown to avoid prompt storms in Auto mode.
            ClaudeOAuthKeychainAccessGate.recordDenied()
            return false
        default:
            return false
        }
        #else
        return false
        #endif
    }

    private static func syncWithClaudeKeychainIfChanged(
        cached: ClaudeOAuthCredentialRecord,
        respectKeychainPromptCooldown: Bool,
        now: Date = Date()) -> ClaudeOAuthCredentialRecord?
    {
        #if os(macOS)
        if !self.keychainAccessAllowed { return nil }
        if respectKeychainPromptCooldown,
           !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now)
        {
            return nil
        }

        if !self.shouldCheckClaudeKeychainChange(now: now) {
            return nil
        }

        guard let currentFingerprint = self.currentClaudeKeychainFingerprintWithoutPrompt() else {
            return nil
        }
        let storedFingerprint = self.loadClaudeKeychainFingerprint()
        guard currentFingerprint != storedFingerprint else { return nil }

        do {
            guard let data = try self.loadFromClaudeKeychainNonInteractive() else {
                return nil
            }
            guard let keychainCreds = try? ClaudeOAuthCredentials.parse(data: data) else {
                self.saveClaudeKeychainFingerprint(currentFingerprint)
                return nil
            }
            self.saveClaudeKeychainFingerprint(currentFingerprint)

            // Only sync if token actually changed to avoid churn on unrelated keychain metadata updates.
            guard keychainCreds.accessToken != cached.credentials.accessToken else { return nil }
            // Avoid regressing a working cached token if the keychain entry looks invalid/expired.
            if keychainCreds.isExpired, !cached.credentials.isExpired { return nil }

            self.log.info("Claude keychain credentials changed; syncing OAuth cache")
            let synced = ClaudeOAuthCredentialRecord(
                credentials: keychainCreds,
                owner: .claudeCLI,
                source: .claudeKeychain)
            self.writeMemoryCache(
                record: ClaudeOAuthCredentialRecord(
                    credentials: keychainCreds,
                    owner: .claudeCLI,
                    source: .memoryCache),
                timestamp: now)
            self.saveToCacheKeychain(data, owner: .claudeCLI)
            return synced
        } catch let error as ClaudeOAuthCredentialsError {
            if case let .keychainError(status) = error,
               status == Int(errSecUserCanceled)
               || status == Int(errSecAuthFailed)
               || status == Int(errSecInteractionNotAllowed)
               || status == Int(errSecNoAccessForItem)
            {
                // Back off to avoid repeated keychain probes on systems that still show prompts.
                ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
            }
            return nil
        } catch {
            return nil
        }
        #else
        _ = cached
        _ = respectKeychainPromptCooldown
        _ = now
        return nil
        #endif
    }

    private static func shouldCheckClaudeKeychainChange(now: Date = Date()) -> Bool {
        #if DEBUG
        // Unit tests can supply TaskLocal overrides for the Claude keychain data/fingerprint. Those tests often run
        // concurrently with other suites, so the global throttle becomes nondeterministic. When an override is
        // present, bypass the throttle so test expectations don't depend on unrelated activity.
        if self.taskClaudeKeychainFingerprintOverride != nil || self.claudeKeychainFingerprintOverride != nil {
            return true
        }
        #endif

        self.claudeKeychainChangeCheckLock.lock()
        defer { self.claudeKeychainChangeCheckLock.unlock() }
        if let last = self.lastClaudeKeychainChangeCheckAt,
           now.timeIntervalSince(last) < self.claudeKeychainChangeCheckMinimumInterval
        {
            return false
        }
        self.lastClaudeKeychainChangeCheckAt = now
        return true
    }

    private static func loadClaudeKeychainFingerprint() -> ClaudeKeychainFingerprint? {
        #if DEBUG
        if let store = taskClaudeKeychainFingerprintStoreOverride {
            return store.fingerprint
        }
        #endif
        // Proactively remove the legacy V1 key (it included the keychain account string, which can be identifying).
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)

        guard let data = UserDefaults.standard.data(forKey: self.claudeKeychainFingerprintKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeKeychainFingerprint.self, from: data)
    }

    private static func saveClaudeKeychainFingerprint(_ fingerprint: ClaudeKeychainFingerprint?) {
        #if DEBUG
        if let store = taskClaudeKeychainFingerprintStoreOverride {
            store.fingerprint = fingerprint
            return
        }
        #endif
        // Proactively remove the legacy V1 key (it included the keychain account string, which can be identifying).
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)

        guard let fingerprint else {
            UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintKey)
            return
        }
        if let data = try? JSONEncoder().encode(fingerprint) {
            UserDefaults.standard.set(data, forKey: self.claudeKeychainFingerprintKey)
        }
    }

    private static func currentClaudeKeychainFingerprintWithoutPrompt() -> ClaudeKeychainFingerprint? {
        #if DEBUG
        if let override = taskClaudeKeychainFingerprintOverride { return override }
        if let override = self.claudeKeychainFingerprintOverride { return override }
        #endif
        #if os(macOS)
        if !self.keychainAccessAllowed {
            return nil
        }

        let newest: ClaudeKeychainCandidate? = self.claudeKeychainCandidatesWithoutPrompt().first
            ?? self.claudeKeychainLegacyCandidateWithoutPrompt()
        guard let newest else { return nil }

        let modifiedAt = newest.modifiedAt.map { Int($0.timeIntervalSince1970) }
        let createdAt = newest.createdAt.map { Int($0.timeIntervalSince1970) }
        let persistentRefHash = Self.sha256Prefix(newest.persistentRef)
        return ClaudeKeychainFingerprint(
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            persistentRefHash: persistentRefHash)
        #else
        return nil
        #endif
    }

    static func currentClaudeKeychainFingerprintWithoutPromptForAuthGate() -> ClaudeKeychainFingerprint? {
        self.currentClaudeKeychainFingerprintWithoutPrompt()
    }

    static func currentCredentialsFileFingerprintWithoutPromptForAuthGate() -> String? {
        guard let fingerprint = self.currentFileFingerprint() else { return nil }
        let modifiedAt = fingerprint.modifiedAt ?? 0
        return "\(modifiedAt):\(fingerprint.size)"
    }

    private static func sha256Prefix(_ data: Data) -> String? {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
        #else
        _ = data
        return nil
        #endif
    }

    private static func loadFromClaudeKeychainNonInteractive() throws -> Data? {
        #if DEBUG
        if let override = taskClaudeKeychainDataOverride { return override }
        if let override = self.claudeKeychainDataOverride { return override }
        #endif
        #if os(macOS)
        if !self.keychainAccessAllowed {
            return nil
        }

        // Keep semantics aligned with fingerprinting: if there are multiple entries, we only ever consult the newest
        // candidate (same as currentClaudeKeychainFingerprintWithoutPrompt()) to avoid syncing from a different item.
        let candidates = self.claudeKeychainCandidatesWithoutPrompt()
        if let newest = candidates.first {
            if let data = try self.loadClaudeKeychainData(candidate: newest, allowKeychainPrompt: false),
               !data.isEmpty
            {
                return data
            }
            return nil
        }

        if let data = try self.loadClaudeKeychainLegacyData(allowKeychainPrompt: false),
           !data.isEmpty
        {
            return data
        }
        return nil
        #else
        return nil
        #endif
    }

    public static func loadFromClaudeKeychain() throws -> Data {
        #if DEBUG
        if let override = self.claudeKeychainDataOverride { return override }
        #endif
        #if os(macOS)
        if !self.keychainAccessAllowed {
            throw ClaudeOAuthCredentialsError.notFound
        }
        let candidates = self.claudeKeychainCandidatesWithoutPrompt()
        if let newest = candidates.first {
            do {
                if let data = try self.loadClaudeKeychainData(candidate: newest, allowKeychainPrompt: true),
                   !data.isEmpty
                {
                    // Store fingerprint after a successful interactive read so we don't immediately try to
                    // "sync" in the background (which can still show UI on some systems).
                    let modifiedAt = newest.modifiedAt.map { Int($0.timeIntervalSince1970) }
                    let createdAt = newest.createdAt.map { Int($0.timeIntervalSince1970) }
                    let persistentRefHash = Self.sha256Prefix(newest.persistentRef)
                    self.saveClaudeKeychainFingerprint(
                        ClaudeKeychainFingerprint(
                            modifiedAt: modifiedAt,
                            createdAt: createdAt,
                            persistentRefHash: persistentRefHash))
                    return data
                }
            } catch let error as ClaudeOAuthCredentialsError {
                if case .keychainError = error {
                    ClaudeOAuthKeychainAccessGate.recordDenied()
                }
                throw error
            }
        }

        // Fallback: legacy query (may pick an arbitrary duplicate).
        do {
            if let data = try self.loadClaudeKeychainLegacyData(allowKeychainPrompt: true),
               !data.isEmpty
            {
                // Same as above: store fingerprint after interactive read to avoid background "sync" reads.
                self.saveClaudeKeychainFingerprint(self.currentClaudeKeychainFingerprintWithoutPrompt())
                return data
            }
        } catch let error as ClaudeOAuthCredentialsError {
            if case .keychainError = error {
                ClaudeOAuthKeychainAccessGate.recordDenied()
            }
            throw error
        }
        throw ClaudeOAuthCredentialsError.notFound
        #else
        throw ClaudeOAuthCredentialsError.notFound
        #endif
    }

    /// Legacy alias for backward compatibility
    public static func loadFromKeychain() throws -> Data {
        try self.loadFromClaudeKeychain()
    }

    #if os(macOS)
    private struct ClaudeKeychainCandidate: Sendable {
        let persistentRef: Data
        let account: String?
        let modifiedAt: Date?
        let createdAt: Date?
    }

    private static func claudeKeychainCandidatesWithoutPrompt() -> [ClaudeKeychainCandidate] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        guard let rows = result as? [[String: Any]], !rows.isEmpty else { return [] }

        let candidates: [ClaudeKeychainCandidate] = rows.compactMap { row in
            guard let persistentRef = row[kSecValuePersistentRef as String] as? Data else { return nil }
            return ClaudeKeychainCandidate(
                persistentRef: persistentRef,
                account: row[kSecAttrAccount as String] as? String,
                modifiedAt: row[kSecAttrModificationDate as String] as? Date,
                createdAt: row[kSecAttrCreationDate as String] as? Date)
        }

        return candidates.sorted { lhs, rhs in
            let lhsDate = lhs.modifiedAt ?? lhs.createdAt ?? Date.distantPast
            let rhsDate = rhs.modifiedAt ?? rhs.createdAt ?? Date.distantPast
            return lhsDate > rhsDate
        }
    }

    private static func claudeKeychainLegacyCandidateWithoutPrompt() -> ClaudeKeychainCandidate? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        guard let row = result as? [String: Any] else { return nil }
        guard let persistentRef = row[kSecValuePersistentRef as String] as? Data else { return nil }
        return ClaudeKeychainCandidate(
            persistentRef: persistentRef,
            account: row[kSecAttrAccount as String] as? String,
            modifiedAt: row[kSecAttrModificationDate as String] as? Date,
            createdAt: row[kSecAttrCreationDate as String] as? Date)
    }

    private static func loadClaudeKeychainData(
        candidate: ClaudeKeychainCandidate,
        allowKeychainPrompt: Bool) throws -> Data?
    {
        self.log.debug(
            "Claude keychain data read start",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "process": ProcessInfo.processInfo.processName,
            ])

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: candidate.persistentRef,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        if !allowKeychainPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }

        var result: AnyObject?
        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        self.log.debug(
            "Claude keychain data read result",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "status": "\(status)",
                "duration_ms": String(format: "%.2f", durationMs),
                "process": ProcessInfo.processInfo.processName,
            ])
        switch status {
        case errSecSuccess:
            if let data = result as? Data {
                return data
            }
            return nil
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            if allowKeychainPrompt {
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(Int(status))
            }
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        case errSecNoAccessForItem:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
    }

    private static func loadClaudeKeychainLegacyData(allowKeychainPrompt: Bool) throws -> Data? {
        self.log.debug(
            "Claude keychain legacy data read start",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "process": ProcessInfo.processInfo.processName,
            ])

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        if !allowKeychainPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }

        var result: AnyObject?
        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        self.log.debug(
            "Claude keychain legacy data read result",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "status": "\(status)",
                "duration_ms": String(format: "%.2f", durationMs),
                "process": ProcessInfo.processInfo.processName,
            ])
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            if allowKeychainPrompt {
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(Int(status))
            }
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        case errSecNoAccessForItem:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
    }
    #endif

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

    private static func saveToCacheKeychain(_ data: Data, owner: ClaudeOAuthCredentialOwner? = nil) {
        let entry = CacheEntry(data: data, storedAt: Date(), owner: owner)
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
        self.credentialsURLOverride ?? self.defaultCredentialsURL()
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

    static func _resetClaudeKeychainChangeTrackingForTesting() {
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintKey)
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)
        self.setClaudeKeychainDataOverrideForTesting(nil)
        self.setClaudeKeychainFingerprintOverrideForTesting(nil)
        self.claudeKeychainChangeCheckLock.lock()
        self.lastClaudeKeychainChangeCheckAt = nil
        self.claudeKeychainChangeCheckLock.unlock()
    }

    static func _resetClaudeKeychainChangeThrottleForTesting() {
        self.claudeKeychainChangeCheckLock.lock()
        self.lastClaudeKeychainChangeCheckAt = nil
        self.claudeKeychainChangeCheckLock.unlock()
    }
    #endif

    private static func defaultCredentialsURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(self.credentialsPath)
    }
}

// swiftlint:enable type_body_length

extension ClaudeOAuthCredentialsStore {
    /// After delegated Claude CLI refresh, re-load the Claude keychain entry without prompting and sync it into
    /// CodexBar's caches. This is used to avoid triggering a second OS keychain dialog during the OAuth retry.
    @discardableResult
    static func syncFromClaudeKeychainWithoutPrompt(now: Date = Date()) -> Bool {
        #if os(macOS)
        if !self.keychainAccessAllowed { return false }

        #if DEBUG
        // Test hook: allow unit tests to simulate a "silent" keychain read without touching the real Keychain.
        if let override = self.taskClaudeKeychainDataOverride ?? self.claudeKeychainDataOverride,
           !override.isEmpty,
           let creds = try? ClaudeOAuthCredentials.parse(data: override),
           !creds.isExpired
        {
            let fingerprint = self.currentClaudeKeychainFingerprintWithoutPrompt()
            self.saveClaudeKeychainFingerprint(fingerprint)
            self.writeMemoryCache(
                record: ClaudeOAuthCredentialRecord(
                    credentials: creds,
                    owner: .claudeCLI,
                    source: .memoryCache),
                timestamp: now)
            self.saveToCacheKeychain(override, owner: .claudeCLI)
            return true
        }
        #endif

        let candidates = self.claudeKeychainCandidatesWithoutPrompt()
        for candidate in candidates {
            if let data = try? self.loadClaudeKeychainData(candidate: candidate, allowKeychainPrompt: false),
               !data.isEmpty,
               let creds = try? ClaudeOAuthCredentials.parse(data: data),
               !creds.isExpired
            {
                let modifiedAt = candidate.modifiedAt.map { Int($0.timeIntervalSince1970) }
                let createdAt = candidate.createdAt.map { Int($0.timeIntervalSince1970) }
                let persistentRefHash = Self.sha256Prefix(candidate.persistentRef)
                self.saveClaudeKeychainFingerprint(
                    ClaudeKeychainFingerprint(
                        modifiedAt: modifiedAt,
                        createdAt: createdAt,
                        persistentRefHash: persistentRefHash))

                self.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .memoryCache),
                    timestamp: now)
                self.saveToCacheKeychain(data, owner: .claudeCLI)
                return true
            }
        }

        if let data = try? self.loadClaudeKeychainLegacyData(allowKeychainPrompt: false),
           !data.isEmpty,
           let creds = try? ClaudeOAuthCredentials.parse(data: data),
           !creds.isExpired
        {
            let fingerprint = self.currentClaudeKeychainFingerprintWithoutPrompt()
            self.saveClaudeKeychainFingerprint(fingerprint)
            self.writeMemoryCache(
                record: ClaudeOAuthCredentialRecord(
                    credentials: creds,
                    owner: .claudeCLI,
                    source: .memoryCache),
                timestamp: now)
            self.saveToCacheKeychain(data, owner: .claudeCLI)
            return true
        }

        return false
        #else
        _ = now
        return false
        #endif
    }

    private static func shouldShowClaudeKeychainPreAlert() -> Bool {
        switch KeychainAccessPreflight.checkGenericPassword(service: self.claudeKeychainService, account: nil) {
        case .interactionRequired:
            true
        case .failure:
            // If preflight fails, we can't be sure whether interaction is required (or if the preflight itself
            // is impacted by a misbehaving Keychain configuration). Be conservative and show the pre-alert.
            true
        case .allowed, .notFound:
            false
        }
    }

    /// Refresh the access token using a refresh token.
    /// Updates CodexBar's keychain cache with the new credentials.
    public static func refreshAccessToken(
        refreshToken: String,
        existingScopes: [String],
        existingRateLimitTier: String?) async throws -> ClaudeOAuthCredentials
    {
        let newCredentials = try await self.refreshAccessTokenCore(
            refreshToken: refreshToken,
            existingScopes: existingScopes,
            existingRateLimitTier: existingRateLimitTier)

        // Save to CodexBar's keychain cache (not Claude's keychain)
        self.saveRefreshedCredentialsToCache(newCredentials)

        // Update in-memory cache
        self.writeMemoryCache(
            record: ClaudeOAuthCredentialRecord(
                credentials: newCredentials,
                owner: .codexbar,
                source: .memoryCache),
            timestamp: Date())
        ClaudeOAuthRefreshFailureGate.recordSuccess()

        return newCredentials
    }

    /// Core refresh logic (network + error disposition + failure gating).
    /// Does not update any caches or keychain items.
    private static func refreshAccessTokenCore(
        refreshToken: String,
        existingScopes: [String],
        existingRateLimitTier: String?) async throws -> ClaudeOAuthCredentials
    {
        guard ClaudeOAuthRefreshFailureGate.shouldAttempt() else {
            let status = ClaudeOAuthRefreshFailureGate.currentBlockStatus()
            let message = switch status {
            case .terminal:
                "Claude OAuth refresh blocked until auth changes. \(self.reauthenticateHint)"
            case .transient:
                "Claude OAuth refresh temporarily backed off due to prior failures; will retry automatically."
            case nil:
                "Claude OAuth refresh temporarily suppressed due to prior failures; will retry automatically."
            }
            throw ClaudeOAuthCredentialsError.refreshFailed(message)
        }

        guard let url = URL(string: self.tokenRefreshEndpoint) else {
            throw ClaudeOAuthCredentialsError.refreshFailed("Invalid token endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: self.oauthClientID),
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthCredentialsError.refreshFailed("Invalid response")
        }

        guard http.statusCode == 200 else {
            if let disposition = self.refreshFailureDisposition(statusCode: http.statusCode, data: data) {
                let oauthError = self.extractOAuthErrorCode(from: data)
                self.log.info(
                    "Claude OAuth refresh rejected",
                    metadata: [
                        "httpStatus": "\(http.statusCode)",
                        "oauthError": oauthError ?? "nil",
                        "disposition": disposition.rawValue,
                    ])

                switch disposition {
                case .terminalInvalidGrant:
                    ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure()
                    self.invalidateCache()
                    throw ClaudeOAuthCredentialsError.refreshFailed(
                        "HTTP \(http.statusCode) invalid_grant. \(self.reauthenticateHint)")
                case .transientBackoff:
                    ClaudeOAuthRefreshFailureGate.recordTransientFailure()
                    let suffix = oauthError.map { " (\($0))" } ?? ""
                    throw ClaudeOAuthCredentialsError.refreshFailed("HTTP \(http.statusCode)\(suffix)")
                }
            }
            throw ClaudeOAuthCredentialsError.refreshFailed("HTTP \(http.statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        let expiresAt = Date(timeIntervalSinceNow: TimeInterval(tokenResponse.expiresIn))

        return ClaudeOAuthCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expiresAt: expiresAt,
            scopes: existingScopes,
            rateLimitTier: existingRateLimitTier)
    }

    private enum RefreshFailureDisposition: String, Sendable {
        case terminalInvalidGrant
        case transientBackoff
    }

    private static func extractOAuthErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String
    }

    private static func refreshFailureDisposition(statusCode: Int, data: Data) -> RefreshFailureDisposition? {
        guard statusCode == 400 || statusCode == 401 else { return nil }
        if let error = self.extractOAuthErrorCode(from: data)?.lowercased(), error == "invalid_grant" {
            return .terminalInvalidGrant
        }
        return .transientBackoff
    }

    #if DEBUG
    static func extractOAuthErrorCodeForTesting(from data: Data) -> String? {
        self.extractOAuthErrorCode(from: data)
    }

    static func refreshFailureDispositionForTesting(statusCode: Int, data: Data) -> String? {
        self.refreshFailureDisposition(statusCode: statusCode, data: data)?.rawValue
    }
    #endif
}
