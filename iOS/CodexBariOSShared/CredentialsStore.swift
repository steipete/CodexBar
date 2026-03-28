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
    private struct SharedCredentialPayload: Codable {
        var codex: CodexCredentials?
        var claude: ClaudeCredentials?
        var claudeWebSession: ClaudeWebSession?
    }

    private static let sharedFilename = "credentials-ios.json"

    private static var service: String {
        if let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleID.isEmpty
        {
            return "\(self.baseBundleIdentifier(from: bundleID)).credentials"
        }
        return "CodexBariOS.credentials"
    }

    public static func loadCodex() throws -> CodexCredentials? {
        let payload = try self.loadSharedPayload()
        if let credentials = payload.codex {
            return credentials
        }
        if let legacy = try self.loadFromKeychain(key: "codex", as: CodexCredentials.self) {
            try? self.saveCodex(legacy)
            return legacy
        }
        return nil
    }

    public static func saveCodex(_ credentials: CodexCredentials) throws {
        try self.updateSharedPayload { payload in
            payload.codex = credentials
        }
        try? self.saveToKeychain(credentials, key: "codex")
    }

    public static func deleteCodex() throws {
        try self.updateSharedPayload { payload in
            payload.codex = nil
        }
        try? self.deleteFromKeychain(key: "codex")
    }

    public static func loadClaude() throws -> ClaudeCredentials? {
        let payload = try self.loadSharedPayload()
        if let credentials = payload.claude {
            return credentials
        }
        if let legacy = try self.loadFromKeychain(key: "claude", as: ClaudeCredentials.self) {
            try? self.saveClaude(legacy)
            return legacy
        }
        return nil
    }

    public static func saveClaude(_ credentials: ClaudeCredentials) throws {
        try self.updateSharedPayload { payload in
            payload.claude = credentials
        }
        try? self.saveToKeychain(credentials, key: "claude")
    }

    public static func deleteClaude() throws {
        try self.updateSharedPayload { payload in
            payload.claude = nil
        }
        try? self.deleteFromKeychain(key: "claude")
    }

    public static func loadClaudeWebSession() throws -> ClaudeWebSession? {
        let payload = try self.loadSharedPayload()
        if let session = payload.claudeWebSession {
            return session
        }
        if let legacy = try self.loadFromKeychain(key: "claude-web-session", as: ClaudeWebSession.self) {
            try? self.saveClaudeWebSession(legacy)
            return legacy
        }
        return nil
    }

    public static func saveClaudeWebSession(_ session: ClaudeWebSession) throws {
        try self.updateSharedPayload { payload in
            payload.claudeWebSession = session
        }
        try? self.saveToKeychain(session, key: "claude-web-session")
    }

    public static func deleteClaudeWebSession() throws {
        try self.updateSharedPayload { payload in
            payload.claudeWebSession = nil
        }
        try? self.deleteFromKeychain(key: "claude-web-session")
    }

    private static func loadSharedPayload() throws -> SharedCredentialPayload {
        guard let url = self.sharedCredentialsURL() else {
            return SharedCredentialPayload()
        }
        guard let data = try? Data(contentsOf: url) else {
            return SharedCredentialPayload()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SharedCredentialPayload.self, from: data)
    }

    private static func updateSharedPayload(_ update: (inout SharedCredentialPayload) -> Void) throws {
        var payload = try self.loadSharedPayload()
        update(&payload)

        guard let url = self.sharedCredentialsURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    private static func sharedCredentialsURL(bundleID: String? = Bundle.main.bundleIdentifier) -> URL? {
        let fm = FileManager.default
        if let groupID = self.groupID(for: bundleID),
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        {
            return container.appendingPathComponent(self.sharedFilename, isDirectory: false)
        }

        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("CodexBariOS", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(self.sharedFilename, isDirectory: false)
    }

    private static func groupID(for bundleID: String?) -> String? {
        if let configuredGroupID = Bundle.main.object(
            forInfoDictionaryKey: WidgetSnapshotStore.appGroupInfoKey) as? String
        {
            let trimmed = configuredGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        guard let bundleID, !bundleID.isEmpty else { return nil }
        return "group.\(self.baseBundleIdentifier(from: bundleID))"
    }

    private static func baseBundleIdentifier(from bundleID: String) -> String {
        var base = bundleID
        let suffixes = [".widget", ".shared", ".tests"]
        for suffix in suffixes where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }
        return base
    }

    private static func loadFromKeychain<T: Decodable>(key: String, as type: T.Type) throws -> T? {
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

    private static func saveToKeychain<T: Encodable>(_ value: T, key: String) throws {
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

    private static func deleteFromKeychain(key: String) throws {
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
