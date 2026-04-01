import Foundation

public enum CodexIdentity: Codable, Equatable, Sendable {
    case providerAccount(id: String)
    case emailOnly(normalizedEmail: String)
    case unresolved
}

public enum CodexIdentityResolver {
    public static func resolve(accountId: String?, email: String?) -> CodexIdentity {
        if let accountId = normalizeAccountID(accountId) {
            return .providerAccount(id: accountId)
        }
        if let email = Self.normalizeEmail(email) {
            return .emailOnly(normalizedEmail: email)
        }
        return .unresolved
    }

    public static func normalizeEmail(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return nil
        }
        return email.lowercased()
    }

    public static func normalizeAccountID(_ accountId: String?) -> String? {
        guard let accountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines), !accountId.isEmpty else {
            return nil
        }
        return accountId
    }
}

public struct CodexAuthBackedAccount: Equatable, Sendable {
    public let identity: CodexIdentity
    public let email: String?
    public let plan: String?

    public init(identity: CodexIdentity, email: String?, plan: String?) {
        self.identity = identity
        self.email = email
        self.plan = plan
    }
}
