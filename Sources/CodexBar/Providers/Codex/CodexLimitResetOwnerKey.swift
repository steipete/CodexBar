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
