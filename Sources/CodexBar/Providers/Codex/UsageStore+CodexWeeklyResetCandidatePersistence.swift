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
            $0.isActive &&
                $0.selectionSource == currentGuard.source &&
                CodexIdentityResolver.normalizeEmail($0.email) == currentGuard.accountKey
        }
        guard activeMatches.count == 1, let account = activeMatches.first else { return }

        if let index = self.codexAccountSnapshots.firstIndex(where: { $0.id == account.id }) {
            let existing = self.codexAccountSnapshots[index]
            guard existing.weeklyResetCandidate != nil || candidate != nil else { return }
            self.codexAccountSnapshots[index] = CodexAccountUsageSnapshot(
                account: account,
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
            self.codexAccountSnapshots = [CodexAccountUsageSnapshot(
                account: account,
                snapshot: relabeled,
                error: self.errors[.codex],
                sourceLabel: self.lastSourceLabels[.codex],
                credits: self.credits,
                weeklyResetCandidate: candidate)]
        }
        self.codexAccountUsageSnapshotStore?.store(self.codexAccountSnapshots)
    }
}
