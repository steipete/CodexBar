import Foundation
import Security

// MARK: - Token Model

public struct AntigravityOAuthTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let email: String?
    public let projectId: String?

    /// Returns `true` when the token is expired or within 5 minutes of expiry.
    public var isExpired: Bool {
        Date() >= self.expiresAt.addingTimeInterval(-5 * 60)
    }

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        email: String?,
        projectId: String?)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
        self.projectId = projectId
    }
}

// MARK: - Error

public enum AntigravityOAuthError: LocalizedError, Sendable {
    case keychainWriteFailed(OSStatus)
    case tokenRefreshFailed(String)
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .keychainWriteFailed(status):
            "Failed to save Antigravity tokens to Keychain (OSStatus: \(status))"
        case let .tokenRefreshFailed(message):
            "Antigravity token refresh failed: \(message)"
        case let .authenticationFailed(message):
            "Antigravity authentication failed: \(message)"
        }
    }
}

// MARK: - Keychain Storage

public struct AntigravityOAuthStorage: Sendable {
    private let serviceName: String
    private static let accountName = "antigravity-tokens"
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    public init(serviceName: String = "com.codexbar.antigravity-oauth") {
        self.serviceName = serviceName
    }

    /// Persist tokens to the macOS Keychain.
    public func saveTokens(_ tokens: AntigravityOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)

        // Remove any existing entry first.
        self.deleteTokens()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: Self.accountName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Self.log.error("Keychain write failed", metadata: ["status": "\(status)"])
            throw AntigravityOAuthError.keychainWriteFailed(status)
        }

        Self.log.debug("Antigravity OAuth tokens saved to Keychain")
    }

    /// Load tokens from the macOS Keychain. Returns `nil` when no tokens are stored.
    public func loadTokens() -> AntigravityOAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: Self.accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        do {
            return try JSONDecoder().decode(AntigravityOAuthTokens.self, from: data)
        } catch {
            Self.log.warning("Failed to decode Antigravity tokens from Keychain", metadata: [
                "error": "\(error)",
            ])
            return nil
        }
    }

    /// Delete stored tokens from Keychain.
    @discardableResult
    public func deleteTokens() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: Self.accountName,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            Self.log.debug("Antigravity OAuth tokens deleted from Keychain")
        }
        return status == errSecSuccess
    }

    /// Check whether tokens exist without loading them.
    public func hasTokens() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: Self.accountName,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
