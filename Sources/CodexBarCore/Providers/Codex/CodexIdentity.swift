import Foundation

public enum CodexIdentity: Codable, Equatable, Sendable {
    case providerAccount(id: String)
    // Normal OAuth auth should resolve to a provider account ID. Email-only identity is kept as a
    // migration/hardening fallback for partial auth payloads, not as the primary steady-state path.
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

/// Locally decoded owner evidence from Codex's existing native ID-token claims.
///
/// This is consistency evidence from a trusted local credential source, not independent signature verification.
enum CodexNativeCredentialOwnerIdentity {
    static func normalizedEmail(fromIDToken idToken: String?) -> String? {
        guard let idToken, let payload = UsageFetcher.parseJWT(idToken) else { return nil }
        let profileValue = payload["https://api.openai.com/profile"]
        guard profileValue == nil || profileValue is [String: Any] else { return nil }
        let profile = profileValue as? [String: Any]

        var candidates: [String] = []
        for value in [payload["email"], profile?["email"]] {
            guard let value else { continue }
            guard let email = value as? String,
                  let normalized = CodexIdentityResolver.normalizeEmail(email)
            else { return nil }
            candidates.append(normalized)
        }
        guard let owner = candidates.first, candidates.allSatisfy({ $0 == owner }) else { return nil }
        return owner
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
