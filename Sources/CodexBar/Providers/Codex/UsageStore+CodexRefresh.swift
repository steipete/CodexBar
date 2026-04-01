import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    nonisolated static let codexSnapshotWaitTimeoutSeconds: TimeInterval = 6
    nonisolated static let codexRefreshStartGraceSeconds: TimeInterval = 0.25
    nonisolated static let codexSnapshotPollIntervalNanoseconds: UInt64 = 100_000_000

    func codexCreditsFetcher() -> UsageFetcher {
        // Credits are remote Codex account state, so they need the same managed-home routing as the
        // primary Codex usage fetch. Local token-cost scanning intentionally stays ambient-system scoped.
        self.makeFetchContext(provider: .codex, override: nil).fetcher
    }

    func refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: Date? = nil) async {
        guard self.isEnabled(.codex) else { return }
        var expectedGuard = self.currentCodexAccountScopedRefreshGuard()
        if expectedGuard.accountKey == nil,
           let minimumSnapshotUpdatedAt,
           case .liveSystem = expectedGuard.source
        {
            _ = await self.waitForCodexSnapshotOrRefreshCompletion(minimumUpdatedAt: minimumSnapshotUpdatedAt)
            expectedGuard = self.currentCodexAccountScopedRefreshGuard()
        }
        guard expectedGuard.accountKey != nil else { return }
        do {
            let credits = try await self.loadLatestCodexCredits()
            guard self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard) else { return }
            await MainActor.run {
                self.credits = credits
                self.lastCreditsError = nil
                self.lastCreditsSnapshot = credits
                self.lastCreditsSnapshotAccountKey = expectedGuard.accountKey
                self.creditsFailureStreak = 0
                self.lastCodexAccountScopedRefreshGuard = expectedGuard
            }
            let codexSnapshot = await MainActor.run {
                self.snapshots[.codex]
            }
            if let minimumSnapshotUpdatedAt,
               codexSnapshot == nil || codexSnapshot?.updatedAt ?? .distantPast < minimumSnapshotUpdatedAt
            {
                self.scheduleCodexPlanHistoryBackfill(
                    minimumSnapshotUpdatedAt: minimumSnapshotUpdatedAt)
                return
            }

            self.cancelCodexPlanHistoryBackfill()
            guard let codexSnapshot else { return }
            await self.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: codexSnapshot,
                now: codexSnapshot.updatedAt)
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("data not available yet") {
                guard self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard) else { return }
                await MainActor.run {
                    if let cached = self.lastCreditsSnapshot,
                       self.lastCreditsSnapshotAccountKey == expectedGuard.accountKey
                    {
                        self.credits = cached
                        self.lastCreditsError = nil
                        self.lastCodexAccountScopedRefreshGuard = expectedGuard
                    } else {
                        self.credits = nil
                        self.lastCreditsError = "Codex credits are still loading; will retry shortly."
                    }
                }
                return
            }

            guard self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard) else { return }
            await MainActor.run {
                self.creditsFailureStreak += 1
                if let cached = self.lastCreditsSnapshot,
                   self.lastCreditsSnapshotAccountKey == expectedGuard.accountKey
                {
                    self.credits = cached
                    let stamp = cached.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    self.lastCreditsError =
                        "Last Codex credits refresh failed: \(message). Cached values from \(stamp)."
                    self.lastCodexAccountScopedRefreshGuard = expectedGuard
                } else {
                    self.lastCreditsError = message
                    self.credits = nil
                }
            }
        }
    }

    private func loadLatestCodexCredits() async throws -> CreditsSnapshot {
        if let override = self._test_codexCreditsLoaderOverride {
            return try await override()
        }
        return try await self.codexCreditsFetcher().loadLatestCredits(
            keepCLISessionsAlive: self.settings.debugKeepCLISessionsAlive)
    }

    func waitForCodexSnapshot(minimumUpdatedAt: Date) async -> UsageSnapshot? {
        let deadline = Date().addingTimeInterval(Self.codexSnapshotWaitTimeoutSeconds)

        while Date() < deadline {
            if Task.isCancelled { return nil }
            if let snapshot = await MainActor.run(body: { self.snapshots[.codex] }),
               snapshot.updatedAt >= minimumUpdatedAt
            {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: Self.codexSnapshotPollIntervalNanoseconds)
        }

        return nil
    }

    func waitForCodexSnapshotOrRefreshCompletion(minimumUpdatedAt: Date) async -> UsageSnapshot? {
        let deadline = Date().addingTimeInterval(Self.codexSnapshotWaitTimeoutSeconds)
        let refreshStartDeadline = Date().addingTimeInterval(Self.codexRefreshStartGraceSeconds)

        while Date() < deadline {
            if Task.isCancelled { return nil }
            let state = await MainActor.run {
                (
                    snapshot: self.snapshots[.codex],
                    isRefreshing: self.refreshingProviders.contains(.codex),
                    hasAttempts: !(self.lastFetchAttempts[.codex] ?? []).isEmpty,
                    hasError: self.errors[.codex] != nil)
            }
            if let snapshot = state.snapshot, snapshot.updatedAt >= minimumUpdatedAt {
                return snapshot
            }
            if !state.isRefreshing, state.hasAttempts || state.hasError {
                return nil
            }
            if !state.isRefreshing,
               !state.hasAttempts,
               !state.hasError,
               Date() >= refreshStartDeadline
            {
                return nil
            }
            try? await Task.sleep(nanoseconds: Self.codexSnapshotPollIntervalNanoseconds)
        }

        return nil
    }

    func scheduleCodexPlanHistoryBackfill(
        minimumSnapshotUpdatedAt: Date)
    {
        self.cancelCodexPlanHistoryBackfill()
        self.codexPlanHistoryBackfillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = await self.waitForCodexSnapshot(minimumUpdatedAt: minimumSnapshotUpdatedAt) else {
                return
            }
            await self.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                now: snapshot.updatedAt)
            self.codexPlanHistoryBackfillTask = nil
        }
    }

    func cancelCodexPlanHistoryBackfill() {
        self.codexPlanHistoryBackfillTask?.cancel()
        self.codexPlanHistoryBackfillTask = nil
    }
}

@MainActor
extension UsageStore {
    private nonisolated static let codexAllAccountsFetchConcurrency = 2

    @discardableResult
    func applyCachedCodexVisibleAccountSnapshotIfAvailable(visibleAccountID: String) -> Bool {
        guard let cached = self.codexAllAccountsSnapshotCache[visibleAccountID],
              let snapshot = cached.snapshot
        else {
            return false
        }

        self.handleSessionQuotaTransition(provider: .codex, snapshot: snapshot)
        self.snapshots[.codex] = snapshot
        self.lastSourceLabels[.codex] = cached.sourceLabel
        self.errors[.codex] = nil
        return true
    }

    func cacheActiveCodexVisibleAccountSnapshot(snapshot: UsageSnapshot, sourceLabel: String?) {
        guard let visibleAccountID = self.settings.codexVisibleAccountProjection.activeVisibleAccountID else { return }
        let entry = CodexVisibleAccountUsageSnapshot(
            visibleAccountID: visibleAccountID,
            snapshot: snapshot,
            error: nil,
            sourceLabel: sourceLabel)
        self.codexAllAccountsSnapshotCache[visibleAccountID] = entry
    }

    func refreshCodexAllAccountsMenuState(
        selectedDidUpdate: (@MainActor () -> Void)? = nil,
        didFinish: (@MainActor () -> Void)? = nil)
    {
        self.codexAllAccountsRefreshTask?.cancel()

        let accounts = self.settings.codexVisibleAccountProjection.visibleAccounts
        guard self.settings.codexMenuDisplayMode == .all, accounts.count > 1 else {
            self.codexAllAccountsRefreshInFlight = false
            self.codexAllAccountsRefreshTask = nil
            return
        }

        let activeVisibleAccountID = self.settings.codexVisibleAccountProjection.activeVisibleAccountID ?? accounts
            .first?.id
        self.codexAllAccountsRefreshInFlight = true
        self.codexAllAccountsRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.codexAllAccountsRefreshInFlight = false
                self.codexAllAccountsRefreshTask = nil
                didFinish?()
            }

            await self.runCodexAllAccountsMenuRefresh(
                accounts: accounts,
                activeVisibleAccountID: activeVisibleAccountID,
                selectedDidUpdate: selectedDidUpdate)
        }
    }

    private func runCodexAllAccountsMenuRefresh(
        accounts: [CodexVisibleAccount],
        activeVisibleAccountID: String?,
        selectedDidUpdate: (@MainActor () -> Void)? = nil) async
    {
        guard !accounts.isEmpty else { return }
        let selectedAccount = accounts.first(where: { $0.id == activeVisibleAccountID }) ?? accounts.first
        let otherAccounts = accounts.filter { $0.id != selectedAccount?.id }

        if let selectedAccount {
            let selectedResult = await self.fetchCodexVisibleAccountUsage(selectedAccount)
            guard !Task.isCancelled else { return }
            self.mergeCodexAllAccountsCache(with: selectedResult)
            await self.applySelectedCodexAllAccountsFetchResultIfCurrent(
                selectedResult,
                expectedVisibleAccountID: selectedAccount.id)
            selectedDidUpdate?()
        }

        guard !otherAccounts.isEmpty else { return }
        let results = await self.fetchCodexVisibleAccountUsageBatch(otherAccounts)
        guard !Task.isCancelled else { return }
        for result in results {
            self.mergeCodexAllAccountsCache(with: result)
        }
    }

    private func applySelectedCodexAllAccountsFetchResultIfCurrent(
        _ result: CodexVisibleAccountUsageSnapshot,
        expectedVisibleAccountID: String) async
    {
        guard self.settings.codexVisibleAccountProjection.activeVisibleAccountID == expectedVisibleAccountID,
              let snapshot = result.snapshot
        else {
            return
        }

        self.handleSessionQuotaTransition(provider: .codex, snapshot: snapshot)
        self.snapshots[.codex] = snapshot
        self.lastSourceLabels[.codex] = result.sourceLabel
        self.errors[.codex] = nil
        self.failureGates[.codex]?.recordSuccess()
        if case .liveSystem = self.settings.codexResolvedActiveSource {
            self.rememberLiveSystemCodexEmailIfNeeded(snapshot.accountEmail(for: .codex))
        }
        self.seedCodexAccountScopedRefreshGuard(
            accountEmail: snapshot.accountEmail(for: .codex),
            workspaceAccountID: snapshot.accountWorkspaceID(for: .codex),
            workspaceLabel: snapshot.accountOrganization(for: .codex))
        await self.recordPlanUtilizationHistorySample(provider: .codex, snapshot: snapshot)
        self.recordCodexHistoricalSampleIfNeeded(snapshot: snapshot)
    }

    private func mergeCodexAllAccountsCache(with result: CodexVisibleAccountUsageSnapshot) {
        if result.snapshot != nil {
            self.codexAllAccountsSnapshotCache[result.visibleAccountID] = result
            return
        }

        guard self.codexAllAccountsSnapshotCache[result.visibleAccountID]?.snapshot == nil else {
            return
        }
        self.codexAllAccountsSnapshotCache[result.visibleAccountID] = result
    }

    private func fetchCodexVisibleAccountUsageBatch(
        _ accounts: [CodexVisibleAccount]) async -> [CodexVisibleAccountUsageSnapshot]
    {
        guard !accounts.isEmpty else { return [] }
        let indexedAccounts = Array(accounts.enumerated())
        let maxConcurrency = min(Self.codexAllAccountsFetchConcurrency, indexedAccounts.count)
        var iterator = indexedAccounts.makeIterator()
        var orderedResults = [CodexVisibleAccountUsageSnapshot?](repeating: nil, count: indexedAccounts.count)

        await withTaskGroup(of: (Int, CodexVisibleAccountUsageSnapshot).self) { group in
            for _ in 0..<maxConcurrency {
                guard let (index, account) = iterator.next() else { break }
                group.addTask { [weak self] in
                    guard let self else {
                        return (
                            index,
                            CodexVisibleAccountUsageSnapshot(
                                visibleAccountID: account.id,
                                snapshot: nil,
                                error: nil,
                                sourceLabel: nil))
                    }
                    let result = await self.fetchCodexVisibleAccountUsage(account)
                    return (index, result)
                }
            }

            while let (index, result) = await group.next() {
                orderedResults[index] = result
                if let (nextIndex, nextAccount) = iterator.next() {
                    group.addTask { [weak self] in
                        guard let self else {
                            return (
                                nextIndex,
                                CodexVisibleAccountUsageSnapshot(
                                    visibleAccountID: nextAccount.id,
                                    snapshot: nil,
                                    error: nil,
                                    sourceLabel: nil))
                        }
                        let nextResult = await self.fetchCodexVisibleAccountUsage(nextAccount)
                        return (nextIndex, nextResult)
                    }
                }
            }
        }

        return orderedResults.compactMap(\.self)
    }

    private func fetchCodexVisibleAccountUsage(_ account: CodexVisibleAccount) async
    -> CodexVisibleAccountUsageSnapshot {
        let outcome = await self.fetchOutcome(
            provider: .codex,
            override: nil,
            codexActiveSourceOverride: account.selectionSource)
        switch outcome.result {
        case let .success(result):
            return CodexVisibleAccountUsageSnapshot(
                visibleAccountID: account.id,
                snapshot: result.usage.scoped(to: .codex),
                error: nil,
                sourceLabel: result.sourceLabel)
        case let .failure(error):
            return CodexVisibleAccountUsageSnapshot(
                visibleAccountID: account.id,
                snapshot: nil,
                error: error.localizedDescription,
                sourceLabel: nil)
        }
    }
}
