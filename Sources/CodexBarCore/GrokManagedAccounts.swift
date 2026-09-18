import Foundation

public struct ManagedGrokAccount: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let email: String
    public let userID: String?
    public let managedHomePath: String
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval
    public let lastAuthenticatedAt: TimeInterval?

    public init(
        id: UUID,
        email: String,
        userID: String? = nil,
        managedHomePath: String,
        createdAt: TimeInterval,
        updatedAt: TimeInterval,
        lastAuthenticatedAt: TimeInterval?)
    {
        self.id = id
        self.email = Self.normalizeEmail(email)
        self.userID = Self.normalizeOptional(userID)
        self.managedHomePath = managedHomePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }

    public static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct ManagedGrokAccountSet: Codable, Sendable, Equatable {
    public let version: Int
    public let accounts: [ManagedGrokAccount]

    public init(version: Int, accounts: [ManagedGrokAccount]) {
        self.version = version
        self.accounts = accounts
    }

    public func account(id: UUID) -> ManagedGrokAccount? {
        self.accounts.first { $0.id == id }
    }
}
