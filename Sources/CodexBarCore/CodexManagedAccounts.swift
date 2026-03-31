import Foundation

public struct ManagedCodexAccount: Codable, Identifiable, Sendable {
    public let id: UUID
    public let email: String
    public let workspaceLabel: String?
    public let workspaceAccountID: String?
    public let managedHomePath: String
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval
    public let lastAuthenticatedAt: TimeInterval?

    public init(
        id: UUID,
        email: String,
        workspaceLabel: String? = nil,
        workspaceAccountID: String? = nil,
        managedHomePath: String,
        createdAt: TimeInterval,
        updatedAt: TimeInterval,
        lastAuthenticatedAt: TimeInterval?)
    {
        self.id = id
        self.email = Self.normalizeEmail(email)
        self.workspaceLabel = Self.normalizeWorkspaceLabel(workspaceLabel)
        self.workspaceAccountID = Self.normalizeWorkspaceAccountID(workspaceAccountID)
        self.managedHomePath = managedHomePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }

    static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    public static func identityKey(
        email: String,
        workspaceAccountID: String? = nil,
        workspaceLabel: String? = nil) -> String
    {
        let normalizedEmail = self.normalizeEmail(email)
        if let normalizedWorkspaceAccountID = self.normalizeWorkspaceAccountID(workspaceAccountID) {
            return "\(normalizedEmail)\naccount:\(normalizedWorkspaceAccountID)"
        }
        guard let normalizedWorkspace = self.normalizeWorkspaceLabel(workspaceLabel)?.lowercased() else {
            return normalizedEmail
        }
        return "\(normalizedEmail)\n\(normalizedWorkspace)"
    }

    public var identityKey: String {
        Self.identityKey(
            email: self.email,
            workspaceAccountID: self.workspaceAccountID,
            workspaceLabel: self.workspaceLabel)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            email: container.decode(String.self, forKey: .email),
            workspaceLabel: container.decodeIfPresent(String.self, forKey: .workspaceLabel),
            workspaceAccountID: container.decodeIfPresent(String.self, forKey: .workspaceAccountID),
            managedHomePath: container.decode(String.self, forKey: .managedHomePath),
            createdAt: container.decode(TimeInterval.self, forKey: .createdAt),
            updatedAt: container.decode(TimeInterval.self, forKey: .updatedAt),
            lastAuthenticatedAt: container.decodeIfPresent(TimeInterval.self, forKey: .lastAuthenticatedAt))
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

    public func account(
        email: String,
        workspaceAccountID: String? = nil,
        workspaceLabel: String? = nil) -> ManagedCodexAccount?
    {
        let identityKey = ManagedCodexAccount.identityKey(
            email: email,
            workspaceAccountID: workspaceAccountID,
            workspaceLabel: workspaceLabel)
        return self.accounts.first { $0.identityKey == identityKey }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            accounts: container.decode([ManagedCodexAccount].self, forKey: .accounts))
    }

    private static func sanitizedAccounts(_ accounts: [ManagedCodexAccount]) -> [ManagedCodexAccount] {
        var seenIDs: Set<UUID> = []
        var seenIdentityKeys: Set<String> = []
        var sanitized: [ManagedCodexAccount] = []
        sanitized.reserveCapacity(accounts.count)

        for account in accounts {
            guard seenIDs.insert(account.id).inserted else { continue }
            guard seenIdentityKeys.insert(account.identityKey).inserted else { continue }
            sanitized.append(account)
        }

        return sanitized
    }
}
