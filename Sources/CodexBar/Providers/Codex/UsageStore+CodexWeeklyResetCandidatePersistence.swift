import CodexBarCore
import Foundation

extension UsageStore {
    @discardableResult
    func persistCodexWeeklyResetPublicationCandidate(
        _ candidate: CodexWeeklyResetPublicationCandidate?,
        expectedGuard: CodexAccountScopedRefreshGuard?,
        previousSnapshot: UsageSnapshot?) -> CodexWeeklyResetPersistenceDecision
    {
        guard let expectedGuard else {
            return Self.recordCodexWeeklyResetPersistenceDecision(.missingExpectedGuard)
        }
        let currentGuard = self.freshCodexAccountScopedRefreshGuard()
        guard Self.codexScopedRefreshGuardsMatchAccount(expectedGuard, currentGuard) else {
            return Self.recordCodexWeeklyResetPersistenceDecision(.accountChanged)
        }

        let visibleAccounts = self.freshCodexVisibleAccountsForSnapshotHydration()
        let activeMatches = visibleAccounts.filter {
            $0.isActive && Self.codexScopedRefreshGuardsMatchAccount(
                currentGuard, Self.codexScopedRefreshGuard(for: $0))
        }
        guard activeMatches.count == 1, let account = activeMatches.first else {
            return Self.recordCodexWeeklyResetPersistenceDecision(.ambiguousActiveAccount)
        }

        // Runtime rows may be unavailable; keep persisted rows and their credits intact during admission.
        var records = self.codexAccountSnapshots
        let persisted = self.codexAccountUsageSnapshotStore?.load(for: visibleAccounts) ?? []
        records += persisted.filter { row in !records.contains { $0.id == row.id } }
        if let index = records.firstIndex(where: { $0.id == account.id }) {
            let existing = records[index]
            guard Self.codexScopedRefreshGuardsMatchAccount(
                currentGuard, Self.codexScopedRefreshGuard(for: existing.account))
            else {
                return Self.recordCodexWeeklyResetPersistenceDecision(.existingAccountChanged)
            }
            guard existing.weeklyResetCandidate != nil || candidate != nil else {
                return Self.recordCodexWeeklyResetPersistenceDecision(.noCandidateChange)
            }
            records[index] = CodexAccountUsageSnapshot(
                account: existing.account,
                snapshot: existing.snapshot,
                error: existing.error,
                sourceLabel: existing.sourceLabel,
                credits: existing.credits,
                weeklyResetCandidate: candidate)
        } else {
            guard let candidate, let previousSnapshot else {
                return Self.recordCodexWeeklyResetPersistenceDecision(.missingCandidateOrBaseline)
            }
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
        self.scheduleCodexWeeklyResetFollowUp(for: account, candidate: candidate)
        // The store has a Void contract and handles disk errors internally; this is not a write-success claim.
        return Self.recordCodexWeeklyResetPersistenceDecision(
            self.codexAccountUsageSnapshotStore == nil ? .storeUnavailable : .storeRequested)
    }

    func scheduleCodexWeeklyResetFollowUp(
        for account: CodexVisibleAccount,
        candidate: CodexWeeklyResetPublicationCandidate?)
    {
        // One autonomous attempt per candidate; a follow-up must not start another retry chain.
        guard CodexWeeklyResetConfirmation.followUpAccount == nil else { return }
        for (id, pending) in self.codexWeeklyResetFollowUps {
            let current = self.codexAccountSnapshots.first { $0.id == id }?.weeklyResetCandidate
            guard current?.createdAt != pending.createdAt else { continue }
            pending.task.cancel()
            self.codexWeeklyResetFollowUps.removeValue(forKey: id)
        }
        let now = CodexWeeklyResetConfirmation.observationDate
        guard let candidate, self.codexWeeklyResetFollowUps[account.id] == nil,
              CodexWeeklyResetConfirmation.delayedCandidateRejection(candidate, observedAt: now) == nil
        else { return }
        let age = now.timeIntervalSince(candidate.createdAt)
        let delay = max(0, CodexWeeklyResetConfirmation.delayedCandidateMinimumAge - age)
        #if DEBUG
        let sleep = CodexWeeklyResetConfirmation.followUpSleepOverride ?? { try await Task.sleep(for: $0) }
        #else
        let sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        #endif
        let task = Task { @MainActor [weak self] in
            var attempted = false
            defer {
                if self?.codexWeeklyResetFollowUps[account.id]?.createdAt == candidate.createdAt,
                   Task.isCancelled || !attempted ||
                   self?.codexAccountSnapshots.first(where: { $0.id == account.id })?
                   .weeklyResetCandidate?.createdAt != candidate.createdAt
                {
                    self?.codexWeeklyResetFollowUps.removeValue(forKey: account.id)
                }
            }
            do { try await sleep(.seconds(delay)) } catch { return }
            // Do not replace another account's in-flight request or retain the store while waiting.
            while let pending = self?.providerRefreshCoordinator.coalescingState(for: .codex) {
                await pending.waitForTaskCompletion()
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled, let self,
                  self.codexAccountSnapshots.first(where: { $0.id == account.id })?
                      .weeklyResetCandidate?.createdAt == candidate.createdAt,
                      CodexWeeklyResetConfirmation.delayedCandidateRejection(
                          candidate, observedAt: CodexWeeklyResetConfirmation.observationDate) == nil,
                      self.codexWeeklyResetFollowUpMatchesCurrentScope(
                          account, projection: self.freshCodexVisibleAccountProjectionForAccountRefresh())
            else { return }
            attempted = true
            await ProviderInteractionContext.$current.withValue(.background) {
                await CodexWeeklyResetConfirmation.$followUpAccount.withValue(account) {
                    await self.refreshProvider(.codex, codexAccountIDs: [account.id])
                }
            }
        }
        self.codexWeeklyResetFollowUps[account.id] = (candidate.createdAt, task)
    }

    func codexWeeklyResetFollowUpMatchesCurrentScope(
        _ account: CodexVisibleAccount,
        projection: CodexVisibleAccountProjection) -> Bool
    {
        (self.settings.codexUsageDataSource == .auto || self.settings.codexUsageDataSource == .oauth)
            && self.providerSpecs[.codex]?.isEnabled() == true
            && !self.shouldUseAmbientCodexPATForUsage()
            && Self.currentCodexVisibleAccount(
                matching: account,
                projection: projection,
                allowProviderAccountAuthFingerprintMismatch: false) != nil
    }

    private static func recordCodexWeeklyResetPersistenceDecision(
        _ decision: CodexWeeklyResetPersistenceDecision) -> CodexWeeklyResetPersistenceDecision
    {
        CodexBarLog.logger(LogCategories.provider(.codex, scope: "weekly-reset-publication")).debug(
            "Codex weekly reset candidate persistence decision", metadata: decision.diagnosticMetadata)
        return decision
    }
}
