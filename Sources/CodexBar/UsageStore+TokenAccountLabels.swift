import CodexBarCore
import Foundation

extension UsageStore {
    func applyAccountLabel(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> UsageSnapshot
    {
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return snapshot }
        let existing = snapshot.identity(for: provider.instanceID)
        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? label : email
        let identity = ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: resolvedEmail,
            accountOrganization: existing?.accountOrganization,
            loginMethod: existing?.loginMethod)
        return snapshot.withIdentity(identity)
    }

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
