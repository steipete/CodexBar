import Foundation
import Security

public struct CodexCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountID: String?
    public let lastRefresh: Date?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accountID: String? = nil,
        lastRefresh: Date? = nil)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.lastRefresh = lastRefresh
    }

    public var canRefresh: Bool {
        guard let refreshToken else { return false }
        return !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var needsRefresh: Bool {
        guard let lastRefresh, self.canRefresh else { return false }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

public struct ClaudeCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let rateLimitTier: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String] = [],
        rateLimitTier: String? = nil)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.rateLimitTier = rateLimitTier
    }

    public var canRefresh: Bool {
        guard let refreshToken else { return false }
        return !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

public struct ClaudeWebSession: Codable, Equatable, Sendable {
    public let sessionKey: String
    public let createdAt: Date

    public init(sessionKey: String, createdAt: Date = Date()) {
        self.sessionKey = sessionKey
        self.createdAt = createdAt
    }

    public var isValid: Bool {
        !self.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum CredentialsStore {
    private static var service: String {
        if let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleID.isEmpty
        {
            return "\(bundleID).credentials"
        }
        return "CodexBariOS.credentials"
    }

    public static func loadCodex() throws -> CodexCredentials? {
        try self.load(key: "codex", as: CodexCredentials.self)
    }

    public static func saveCodex(_ credentials: CodexCredentials) throws {
        try self.save(credentials, key: "codex")
    }

    public static func deleteCodex() throws {
        try self.delete(key: "codex")
    }

    public static func loadClaude() throws -> ClaudeCredentials? {
        try self.load(key: "claude", as: ClaudeCredentials.self)
    }

    public static func saveClaude(_ credentials: ClaudeCredentials) throws {
        try self.save(credentials, key: "claude")
    }

    public static func deleteClaude() throws {
        try self.delete(key: "claude")
    }

    public static func loadClaudeWebSession() throws -> ClaudeWebSession? {
        try self.load(key: "claude-web-session", as: ClaudeWebSession.self)
    }

    public static func saveClaudeWebSession(_ session: ClaudeWebSession) throws {
        try self.save(session, key: "claude-web-session")
    }

    public static func deleteClaudeWebSession() throws {
        try self.delete(key: "claude-web-session")
    }

    private static func load<T: Decodable>(key: String, as type: T.Type) throws -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func save<T: Encodable>(_ value: T, key: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    private static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
