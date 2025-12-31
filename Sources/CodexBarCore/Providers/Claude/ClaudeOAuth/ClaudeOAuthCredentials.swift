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

    public static func load() throws -> ClaudeOAuthCredentials {
        // Prefer Keychain (CLI writes there on macOS), but fall back to the JSON file when missing.
        var lastError: Error?
        if let keychainData = try? self.loadFromKeychain() {
            do {
                return try ClaudeOAuthCredentials.parse(data: keychainData)
            } catch {
                // Keep the Keychain parse error so we can surface it if the file is also invalid.
                lastError = error
            }
        }
        do {
            let fileData = try self.loadFromFile()
            return try ClaudeOAuthCredentials.parse(data: fileData)
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

    public static func loadFromKeychain() throws -> Data {
        #if os(macOS)
        // SKIP keychain entirely for "Claude Code-credentials".
        // This keychain item is created by Claude CLI, not CodexBar. Its ACL doesn't include
        // CodexBar, so ANY keychain access (even the preflight check) can trigger macOS prompts.
        // The caller will fall back to ~/.claude/.credentials.json instead.
        throw ClaudeOAuthCredentialsError.notFound
        #else
        throw ClaudeOAuthCredentialsError.notFound
        #endif
    }
}
