import CodexBarCore
import Foundation

extension UsageStore {
    /// Provider-specific by design: Codex's visible account supplies workspace identity absent from token accounts.
    func applyCodexVisibleAccountLabel(_ snapshot: UsageSnapshot, account: CodexVisibleAccount) -> UsageSnapshot {
        let existing = snapshot.identity(for: .codex)
        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? account.email : email
        let loginMethod = existing?.loginMethod ?? account.workspaceLabel
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: resolvedEmail,
            accountOrganization: existing?.accountOrganization,
            loginMethod: loginMethod)
        return snapshot.withIdentity(identity)
    }
}
