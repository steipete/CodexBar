import CodexBarCore
import CryptoKit
import Foundation

struct CodexLimitResetOwnerKey: Equatable, Hashable, Sendable {
    let rawValue: String

    init?(identity: CodexIdentity, accountEmail: String?) {
        guard case let .providerAccount(id) = identity,
              let normalizedID = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(id),
              let normalizedEmail = CodexIdentityResolver.normalizeEmail(accountEmail)
        else {
            return nil
        }
        let input = "codex-limit-reset-owner:v2\0\(normalizedID)\0\(normalizedEmail)"
        let digest = SHA256.hash(data: Data(input.utf8))
        self.rawValue = digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct CodexSessionQuotaOwnerKey: Equatable, Sendable {
    let rawValue: String

    init?(refreshGuard: CodexAccountScopedRefreshGuard) {
        let input: String
        switch refreshGuard.identity {
        case let .providerAccount(id):
            guard let normalizedID = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(id),
                  let normalizedEmail = CodexIdentityResolver.normalizeEmail(refreshGuard.accountKey)
            else {
                return nil
            }
            input = "codex-session-quota-owner:v1\0provider\0\(normalizedID)\0\(normalizedEmail)"
        case let .emailOnly(normalizedEmail):
            guard let email = CodexIdentityResolver.normalizeEmail(normalizedEmail) else { return nil }
            if let accountKey = CodexIdentityResolver.normalizeEmail(refreshGuard.accountKey), accountKey != email {
                return nil
            }
            guard let sourceKey = Self.sourceKey(refreshGuard.source) else { return nil }
            // Email-only auth cannot distinguish same-email workspaces. Include the credential fingerprint
            // and deliberately establish a new baseline after rotation rather than risk a cross-account alert.
            guard let fingerprint = CodexAuthFingerprint.normalize(refreshGuard.authFingerprint) else { return nil }
            input = "codex-session-quota-owner:v1\0email\0\(sourceKey)\0\(email)\0\(fingerprint)"
        case .unresolved:
            return nil
        }
        let digest = SHA256.hash(data: Data(input.utf8))
        self.rawValue = digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceKey(_ source: CodexActiveSource) -> String? {
        switch source {
        case .liveSystem:
            "live-system"
        case let .managedAccount(id):
            "managed:\(id.uuidString.lowercased())"
        case let .profileHome(path):
            CodexHomeScope.normalizedHomePath(path).map { "profile:\($0)" }
        }
    }
}

extension UsageStore {
    func codexLimitResetOwnerKey(
        expectedGuard: CodexAccountScopedRefreshGuard,
        visibleAccounts _: [CodexVisibleAccount]) -> CodexLimitResetOwnerKey?
    {
        CodexLimitResetOwnerKey(
            identity: expectedGuard.identity,
            accountEmail: expectedGuard.accountKey)
    }

    func codexLimitResetOwnerKey(
        forVisibleAccount account: CodexVisibleAccount,
        visibleAccounts _: [CodexVisibleAccount]) -> CodexLimitResetOwnerKey?
    {
        guard let workspaceAccountID = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(
            account.workspaceAccountID)
        else { return nil }
        return CodexLimitResetOwnerKey(
            identity: .providerAccount(id: workspaceAccountID),
            accountEmail: account.email)
    }
}
