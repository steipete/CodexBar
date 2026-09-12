import CodexBarCore
import Foundation

extension UsageStore {
    func clearCodexFetchErrorAfterWithheldPublication(
        success: ProviderFetchResult,
        expectedGuard: CodexAccountScopedRefreshGuard,
        generation: UInt64)
    {
        guard !Task.isCancelled,
              !Self.isCodexPATResult(success),
              self.isCurrentProviderRefreshGeneration(.codex, generation: generation),
              self.shouldApplyCodexUsageResult(expectedGuard: expectedGuard, usage: success.usage.scoped(to: .codex))
        else { return }
        let visibleAccounts = self.freshCodexVisibleAccountsForSnapshotHydration()
        let matches = visibleAccounts.filter {
            $0.isActive && Self.codexScopedRefreshGuardsMatchAccount(
                expectedGuard, Self.codexScopedRefreshGuard(for: $0))
        }
        guard matches.count == 1, let account = matches.first else { return }

        self.recordCodexWithheldFetchSuccess()
        if let index = self.codexAccountSnapshots.firstIndex(where: {
            $0.id == account.id && Self.codexScopedRefreshGuardsMatchAccount(
                expectedGuard, Self.codexScopedRefreshGuard(for: $0.account))
        }) {
            self.codexAccountSnapshots[index] = Self.clearingCodexConnectivityError(self.codexAccountSnapshots[index])
        }

        // Single-account refresh empties the in-memory rows; amend disk without losing preserved data or siblings.
        guard let snapshotStore = self.codexAccountUsageSnapshotStore else { return }
        var persisted = snapshotStore.load(for: visibleAccounts)
        guard let index = persisted.firstIndex(where: {
            $0.id == account.id && Self.codexScopedRefreshGuardsMatchAccount(
                expectedGuard, Self.codexScopedRefreshGuard(for: $0.account))
        }), let error = persisted[index].error,
        Self.shouldPreserveCodexAccountSnapshotOnFailure(error)
        else { return }
        persisted[index] = Self.clearingCodexConnectivityError(persisted[index])
        snapshotStore.store(persisted)
    }

    func recordCodexWithheldFetchSuccess() {
        // Failure suppression tracks successful fetches, even when quota publication is withheld.
        self.failureGates[.codex]?.recordSuccess()
        if let error = self.errors[.codex], Self.shouldPreserveCodexAccountSnapshotOnFailure(error) {
            self.errors[.codex] = nil
        }
    }

    static func clearingCodexConnectivityError(_ record: CodexAccountUsageSnapshot) -> CodexAccountUsageSnapshot {
        guard let error = record.error, shouldPreserveCodexAccountSnapshotOnFailure(error) else { return record }
        return CodexAccountUsageSnapshot(
            account: record.account,
            snapshot: record.snapshot,
            error: nil,
            sourceLabel: record.sourceLabel,
            credits: record.credits,
            weeklyResetCandidate: record.weeklyResetCandidate)
    }
}
