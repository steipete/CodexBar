import CodexBarCore
import Foundation

extension UsageStore {
    func persistCodexWeeklyResetPublicationCandidate(
        _ candidate: CodexWeeklyResetPublicationCandidate?,
        expectedGuard: CodexAccountScopedRefreshGuard?,
        previousSnapshot: UsageSnapshot?)
    {
        guard let expectedGuard else { return }
        let currentGuard = self.freshCodexAccountScopedRefreshGuard()
        guard Self.codexScopedRefreshGuardsMatchAccount(expectedGuard, currentGuard) else { return }

        let visibleAccounts = self.freshCodexVisibleAccountsForSnapshotHydration()
        let activeMatches = visibleAccounts.filter {
            $0.isActive && Self.codexScopedRefreshGuardsMatchAccount(
                currentGuard, Self.codexScopedRefreshGuard(for: $0))
        }
        guard activeMatches.count == 1, let account = activeMatches.first else { return }

        // Single-account refresh clears memory before admission; keep the persisted rows and their credits intact.
        var records = self.codexAccountSnapshots
        let persisted = self.codexAccountUsageSnapshotStore?.load(for: visibleAccounts) ?? []
        records += persisted.filter { row in !records.contains { $0.id == row.id } }
        if let index = records.firstIndex(where: { $0.id == account.id }) {
            let existing = records[index]
            guard Self.codexScopedRefreshGuardsMatchAccount(
                currentGuard, Self.codexScopedRefreshGuard(for: existing.account)) else { return }
            guard existing.weeklyResetCandidate != nil || candidate != nil else { return }
            records[index] = CodexAccountUsageSnapshot(
                account: existing.account,
                snapshot: existing.snapshot,
                error: existing.error,
                sourceLabel: existing.sourceLabel,
                credits: existing.credits,
                weeklyResetCandidate: candidate)
        } else {
            guard let candidate, let previousSnapshot else { return }
            let identity = previousSnapshot.identity(for: .codex)
            let relabeled = previousSnapshot.withIdentity(ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: account.email,
                accountOrganization: identity?.accountOrganization,
                loginMethod: identity?.loginMethod ?? account.workspaceLabel))
            records.append(CodexAccountUsageSnapshot(
                account: account,
                snapshot: relabeled,
                error: self.errors[.codex],
                sourceLabel: self.lastSourceLabels[.codex],
                credits: self.credits,
                weeklyResetCandidate: candidate))
        }
        self.codexAccountSnapshots = records
        self.codexAccountUsageSnapshotStore?.store(records)
    }
}
