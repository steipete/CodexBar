import Foundation

public struct OpenCodeWorkspaceAccount: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let tokenAccountID: UUID
    public let workspaceID: String
    public var label: String
    public var ownerLabel: String?
    public let createdAt: TimeInterval
    public var updatedAt: TimeInterval

    public init?(
        tokenAccountID: UUID,
        workspaceID: String,
        label: String,
        ownerLabel: String? = nil,
        now: Date = Date())
    {
        guard let normalizedWorkspaceID = Self.normalizeWorkspaceID(workspaceID) else { return nil }
        self.id = Self.canonicalID(tokenAccountID: tokenAccountID, workspaceID: normalizedWorkspaceID)
        self.tokenAccountID = tokenAccountID
        self.workspaceID = normalizedWorkspaceID
        self.label = Self.cleanLabel(label, fallback: normalizedWorkspaceID)
        self.ownerLabel = Self.cleanOptionalLabel(ownerLabel)
        self.createdAt = now.timeIntervalSince1970
        self.updatedAt = now.timeIntervalSince1970
    }

    public static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 {
            return trimmed
        }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"),
               parts.count > index + 1
            {
                let candidate = parts[index + 1]
                if candidate.hasPrefix("wrk_"), candidate.count > 4 {
                    return candidate
                }
            }
        }
        if let match = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    public static func canonicalID(tokenAccountID: UUID, workspaceID: String) -> String {
        "\(tokenAccountID.uuidString.lowercased())/\(workspaceID)"
    }

    private static func cleanLabel(_ raw: String, fallback: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private static func cleanOptionalLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tokenAccountID
        case workspaceID
        case label
        case ownerLabel
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tokenAccountID = try container.decode(UUID.self, forKey: .tokenAccountID)
        let rawWorkspaceID = try container.decode(String.self, forKey: .workspaceID)
        guard let workspaceID = Self.normalizeWorkspaceID(rawWorkspaceID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .workspaceID,
                in: container,
                debugDescription: "Invalid OpenCode workspace ID.")
        }
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? Self.canonicalID(tokenAccountID: tokenAccountID, workspaceID: workspaceID)
        self.tokenAccountID = tokenAccountID
        self.workspaceID = workspaceID
        self.label = Self.cleanLabel(
            try container.decode(String.self, forKey: .label),
            fallback: workspaceID)
        self.ownerLabel = Self.cleanOptionalLabel(
            try container.decodeIfPresent(String.self, forKey: .ownerLabel))
        self.createdAt = try container.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
        self.updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? self.createdAt
    }
}

public enum OpenCodeWorkspaceAccountMutationResult: Equatable, Sendable {
    case saved
    case duplicate
    case missingReusableCredential
    case invalidWorkspaceID
    case discoveryFailed(String)
}

public struct OpenCodeWorkspaceAccounts: Codable, Equatable, Sendable {
    public private(set) var accounts: [OpenCodeWorkspaceAccount]
    public private(set) var activeID: String?

    public init(accounts: [OpenCodeWorkspaceAccount] = [], activeID: String? = nil) {
        var deduplicated: [OpenCodeWorkspaceAccount] = []
        var ids: Set<String> = []
        for account in accounts where ids.insert(account.id).inserted {
            deduplicated.append(account)
        }
        self.accounts = deduplicated
        self.activeID = activeID.flatMap { ids.contains($0) ? $0 : nil } ?? deduplicated.first?.id
    }

    public var active: OpenCodeWorkspaceAccount? {
        guard let activeID = self.activeID else { return nil }
        return self.accounts.first(where: { $0.id == activeID })
    }

    @discardableResult
    public mutating func upsert(_ account: OpenCodeWorkspaceAccount) -> OpenCodeWorkspaceAccountMutationResult {
        guard !self.accounts.contains(where: { $0.id == account.id }) else {
            return .duplicate
        }
        self.accounts.append(account)
        if self.activeID == nil {
            self.activeID = account.id
        }
        return .saved
    }

    @discardableResult
    public mutating func add(
        tokenAccountID: UUID?,
        workspaceID: String?,
        label: String,
        ownerLabel: String? = nil,
        now: Date = Date()) -> OpenCodeWorkspaceAccountMutationResult
    {
        guard let tokenAccountID else { return .missingReusableCredential }
        guard let workspaceID,
              let account = OpenCodeWorkspaceAccount(
                  tokenAccountID: tokenAccountID,
                  workspaceID: workspaceID,
                  label: label,
                  ownerLabel: ownerLabel,
                  now: now)
        else {
            return .invalidWorkspaceID
        }
        return self.upsert(account)
    }

    @discardableResult
    public mutating func selectActive(id: String) -> Bool {
        guard self.accounts.contains(where: { $0.id == id }) else { return false }
        self.activeID = id
        return true
    }

    public mutating func prune(validTokenAccountIDs: Set<UUID>) {
        self.accounts.removeAll { !validTokenAccountIDs.contains($0.tokenAccountID) }
        guard let activeID = self.activeID,
              self.accounts.contains(where: { $0.id == activeID })
        else {
            self.activeID = self.accounts.first?.id
            return
        }
    }
}
