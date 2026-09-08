import Crypto
import Foundation

public struct ManagedCodexAccount: Codable, Identifiable, Sendable {
    public let id: UUID
    public let email: String
    public let providerAccountID: String?
    public let workspaceLabel: String?
    public let workspaceAccountID: String?
    public let authFingerprint: String?
    public let managedHomePath: String
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval
    public let lastAuthenticatedAt: TimeInterval?

    public init(
        id: UUID,
        email: String,
        providerAccountID: String? = nil,
        workspaceLabel: String? = nil,
        workspaceAccountID: String? = nil,
        authFingerprint: String? = nil,
        managedHomePath: String,
        createdAt: TimeInterval,
        updatedAt: TimeInterval,
        lastAuthenticatedAt: TimeInterval?)
    {
        self.id = id
        self.email = Self.normalizeEmail(email)
        self.providerAccountID = Self.normalizeProviderAccountID(providerAccountID)
        self.workspaceLabel = Self.normalizeWorkspaceLabel(workspaceLabel)
        self.workspaceAccountID = Self.normalizeWorkspaceAccountID(workspaceAccountID)
        self.authFingerprint = CodexAuthFingerprint.normalize(authFingerprint)
        self.managedHomePath = managedHomePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }

    static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizeProviderAccountID(_ providerAccountID: String?) -> String? {
        self.normalizeWorkspaceAccountID(providerAccountID)
    }

    public static func normalizeWorkspaceLabel(_ workspaceLabel: String?) -> String? {
        guard let trimmed = workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static func normalizeWorkspaceAccountID(_ workspaceAccountID: String?) -> String? {
        guard let trimmed = workspaceAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    /// The remote workspace CodexBar selected for this managed account.
    ///
    /// New records store the explicit workspace separately. Older provider-backed records used
    /// `providerAccountID` for the same purpose. The managed auth file can name a different default
    /// workspace, so callers deciding remote ownership must prefer this app-owned selection.
    public var effectiveWorkspaceAccountID: String? {
        Self.normalizeWorkspaceAccountID(self.workspaceAccountID ?? self.providerAccountID)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            email: container.decode(String.self, forKey: .email),
            providerAccountID: container.decodeIfPresent(String.self, forKey: .providerAccountID),
            workspaceLabel: container.decodeIfPresent(String.self, forKey: .workspaceLabel),
            workspaceAccountID: container.decodeIfPresent(String.self, forKey: .workspaceAccountID),
            authFingerprint: container.decodeIfPresent(String.self, forKey: .authFingerprint),
            managedHomePath: container.decode(String.self, forKey: .managedHomePath),
            createdAt: container.decode(TimeInterval.self, forKey: .createdAt),
            updatedAt: container.decode(TimeInterval.self, forKey: .updatedAt),
            lastAuthenticatedAt: container.decodeIfPresent(TimeInterval.self, forKey: .lastAuthenticatedAt))
    }
}

public enum CodexAuthFingerprint {
    public static func authFileURL(homePath: String) -> URL {
        URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    public static func fingerprint(homePath: String, fileManager: FileManager = .default) -> String? {
        let url = self.authFileURL(homePath: homePath)
        guard CodexCredentialFileAccess.fileExists(at: url, fileManager: fileManager),
              let data = try? CodexCredentialFileAccess.read(at: url)
        else {
            return nil
        }
        return self.fingerprint(data: data)
    }

    public static func fingerprint(env: [String: String], fileManager: FileManager = .default) -> String? {
        self.fingerprint(
            homePath: CodexHomeScope.ambientHomeURL(env: env, fileManager: fileManager).path,
            fileManager: fileManager)
    }

    public static func fingerprint(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalize(_ fingerprint: String?) -> String? {
        guard let trimmed = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

public struct ManagedCodexAccountSet: Codable, Sendable {
    public let version: Int
    public let accounts: [ManagedCodexAccount]

    public init(version: Int, accounts: [ManagedCodexAccount]) {
        self.version = version
        self.accounts = Self.sanitizedAccounts(accounts)
    }

    public func account(id: UUID) -> ManagedCodexAccount? {
        self.accounts.first { $0.id == id }
    }

    public func account(email: String, providerAccountID: String? = nil) -> ManagedCodexAccount? {
        let normalizedEmail = ManagedCodexAccount.normalizeEmail(email)
        if let normalizedWorkspaceAccountID = ManagedCodexAccount.normalizeWorkspaceAccountID(providerAccountID),
           let exactMatch = self.accounts.first(where: {
               $0.email == normalizedEmail && $0.effectiveWorkspaceAccountID == normalizedWorkspaceAccountID
           })
        {
            return exactMatch
        }
        return self.accounts.first {
            $0.email == normalizedEmail && $0.effectiveWorkspaceAccountID == nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.accounts = try container.decode([ManagedCodexAccount].self, forKey: .accounts)
    }

    private static func sanitizedAccounts(_ accounts: [ManagedCodexAccount]) -> [ManagedCodexAccount] {
        var seenIDs: Set<UUID> = []
        var seenWorkspaceAccountKeys: Set<String> = []
        var seenLegacyEmails: Set<String> = []
        var sanitized: [ManagedCodexAccount] = []
        sanitized.reserveCapacity(accounts.count)

        for account in accounts {
            guard seenIDs.insert(account.id).inserted else { continue }
            if let workspaceAccountID = account.effectiveWorkspaceAccountID {
                guard seenWorkspaceAccountKeys.insert("\(account.email)\u{0}\(workspaceAccountID)").inserted else {
                    continue
                }
            } else {
                guard seenLegacyEmails.insert(account.email).inserted else { continue }
            }
            sanitized.append(account)
        }

        return sanitized
    }
}
