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
    private static let keychainService = "Claude Code-credentials"

    // Cache to avoid repeated keychain prompts (nonisolated for synchronous access)
    private nonisolated(unsafe) static var cachedCredentials: ClaudeOAuthCredentials?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    private static let cacheValidityDuration: TimeInterval = 60 // 1 minute cache

    public static func load() throws -> ClaudeOAuthCredentials {
        // Check cache first to avoid repeated keychain access
        if let cached = self.cachedCredentials,
           let timestamp = self.cacheTimestamp,
           Date().timeIntervalSince(timestamp) < self.cacheValidityDuration
        {
            return cached
        }

        // Prefer Keychain (CLI writes there on macOS), but fall back to the JSON file when missing.
        var lastError: Error?
        if let keychainData = try? self.loadFromKeychain() {
            do {
                let creds = try ClaudeOAuthCredentials.parse(data: keychainData)
                self.cachedCredentials = creds
                self.cacheTimestamp = Date()
                return creds
            } catch {
                // Keep the Keychain parse error so we can surface it if the file is also invalid.
                lastError = error
            }
        }
        do {
            let fileData = try self.loadFromFile()
            let creds = try ClaudeOAuthCredentials.parse(data: fileData)
            self.cachedCredentials = creds
            self.cacheTimestamp = Date()
            return creds
        } catch {
            if let lastError { throw lastError }
            throw error
        }
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
    }

    public static func loadFromKeychain() throws -> Data {
        #if os(macOS)
        if case .interactionRequired = KeychainAccessPreflight
            .checkGenericPassword(service: self.keychainService, account: nil)
        {
            KeychainPromptHandler.handler?(KeychainPromptContext(
                kind: .claudeOAuth,
                service: self.keychainService,
                account: nil))
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
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
}
