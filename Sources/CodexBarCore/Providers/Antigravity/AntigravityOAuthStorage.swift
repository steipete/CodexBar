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
    struct KeychainClient: @unchecked Sendable {
        let add: @Sendable ([String: Any]) -> OSStatus
        let update: @Sendable ([String: Any], [String: Any]) -> OSStatus
        let copyMatchingData: @Sendable ([String: Any]) -> (status: OSStatus, data: Data?)
        let delete: @Sendable ([String: Any]) -> OSStatus
        let exists: @Sendable ([String: Any]) -> Bool

        static let live = KeychainClient(
            add: { query in
                SecItemAdd((query as NSDictionary) as CFDictionary, nil)
            },
            update: { query, attributes in
                SecItemUpdate(
                    (query as NSDictionary) as CFDictionary,
                    (attributes as NSDictionary) as CFDictionary)
            },
            copyMatchingData: { query in
                var result: AnyObject?
                let status = SecItemCopyMatching((query as NSDictionary) as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data else {
                    return (status, nil)
                }
                return (status, data)
            },
            delete: { query in
                SecItemDelete((query as NSDictionary) as CFDictionary)
            },
            exists: { query in
                SecItemCopyMatching((query as NSDictionary) as CFDictionary, nil) == errSecSuccess
            })
    }

    private let serviceName: String
    private let keychainClient: KeychainClient
    private static let accountName = "antigravity-tokens"
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    public init(serviceName: String = "com.codexbar.antigravity-oauth") {
        self.init(serviceName: serviceName, keychainClient: .live)
    }

    init(serviceName: String, keychainClient: KeychainClient) {
        self.serviceName = serviceName
        self.keychainClient = keychainClient
    }

    /// Persist tokens to the macOS Keychain.
    public func saveTokens(_ tokens: AntigravityOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let itemQuery = self.baseQuery()
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = self.keychainClient.update(itemQuery, updateAttributes)
        switch updateStatus {
        case errSecSuccess:
            Self.log.debug("Antigravity OAuth tokens updated in Keychain")
        case errSecItemNotFound:
            var addQuery = itemQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let addStatus = self.keychainClient.add(addQuery)
            guard addStatus == errSecSuccess else {
                Self.log.error("Keychain write failed", metadata: ["status": "\(addStatus)"])
                throw AntigravityOAuthError.keychainWriteFailed(addStatus)
            }
            Self.log.debug("Antigravity OAuth tokens saved to Keychain")
        default:
            let status = updateStatus
            Self.log.error("Keychain write failed", metadata: ["status": "\(status)"])
            throw AntigravityOAuthError.keychainWriteFailed(status)
        }
    }

    /// Load tokens from the macOS Keychain. Returns `nil` when no tokens are stored.
    public func loadTokens() -> AntigravityOAuthTokens? {
        var query = self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = self.keychainClient.copyMatchingData(query)
        guard result.status == errSecSuccess, let data = result.data else {
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
        let status = self.keychainClient.delete(self.baseQuery())
        if status == errSecSuccess {
            Self.log.debug("Antigravity OAuth tokens deleted from Keychain")
        }
        return status == errSecSuccess
    }

    /// Check whether tokens exist without loading them.
    public func hasTokens() -> Bool {
        var query = self.baseQuery()
        query[kSecReturnData as String] = false
        return self.keychainClient.exists(query)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: Self.accountName,
        ]
    }
}
