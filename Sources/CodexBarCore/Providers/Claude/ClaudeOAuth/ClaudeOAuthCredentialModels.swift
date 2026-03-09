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

extension ClaudeOAuthCredentials {
    func diagnosticsMetadata(now: Date = Date()) -> [String: String] {
        let hasRefreshToken = !(self.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasUserProfileScope = self.scopes.contains("user:profile")

        var metadata: [String: String] = [
            "hasRefreshToken": "\(hasRefreshToken)",
            "scopesCount": "\(self.scopes.count)",
            "hasUserProfileScope": "\(hasUserProfileScope)",
        ]

        if let expiresAt = self.expiresAt {
            let expiresAtMs = Int(expiresAt.timeIntervalSince1970 * 1000.0)
            let expiresInSec = Int(expiresAt.timeIntervalSince(now).rounded())
            metadata["expiresAtMs"] = "\(expiresAtMs)"
            metadata["expiresInSec"] = "\(expiresInSec)"
            metadata["isExpired"] = "\(now >= expiresAt)"
        } else {
            metadata["expiresAtMs"] = "nil"
            metadata["expiresInSec"] = "nil"
            metadata["isExpired"] = "true"
        }

        return metadata
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
                return "Claude Keychain access was denied. CodexBar will back off in the background until you retry "
                    + "via a user action (menu open / manual refresh). "
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
