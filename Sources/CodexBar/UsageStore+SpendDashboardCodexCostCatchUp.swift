import CodexBarCore
import Foundation

private struct SpendDashboardCodexCostCatchUpContext {
    let token: UUID
    let accounts: [CodexSpendScanRequest]
    let historyDays: Int
    let scopeSignature: String
    let providerConfigRevision: UInt64
    let costUsageSettingsRevision: UInt64
}

extension UsageStore {
    func synchronizeSpendDashboardCodexCostCatchUp(accounts: [CodexSpendScanRequest]) {
        let mode = self.spendDashboardCodexCostCatchUpTask == nil
            ? .automatic
            : self.spendDashboardCodexCostCatchUpMode
        self.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: mode)
    }

    func startSpendDashboardCodexCostCatchUpIfNeeded(
        accounts: [CodexSpendScanRequest],
        mode: CodexCostCatchUpMode = .automatic)
    {
        let accounts = Self.uniqueSpendDashboardCodexAccounts(accounts)
        guard !accounts.isEmpty,
              self.settings.isCostUsageEffectivelyEnabled(for: .codex),
              self.isEnabled(.codex)
        else {
            self.cancelSpendDashboardCodexCostCatchUp()
            return
        }

        let scopeSignature = accounts
            .map { "\($0.id)|\($0.cacheIdentity)" }
            .joined(separator: "\u{0}")
        if self.spendDashboardCodexCostCatchUpTask != nil,
           self.spendDashboardCodexCostCatchUpScopeSignature == scopeSignature
        {
            guard self.spendDashboardCodexCostCatchUpMode != mode else { return }
            self.spendDashboardCodexCostCatchUpMode = mode
            // A bounded parser pass may be committing a resume checkpoint. Let it finish and
            // apply the new mode before scheduling the next account instead of cancelling it.
            if self.spendDashboardCodexCostCatchUpPassIsRunning {
                return
            }
        }

        self.cancelSpendDashboardCodexCostCatchUp()
        let token = UUID()
        let context = SpendDashboardCodexCostCatchUpContext(
            token: token,
            accounts: accounts,
            historyDays: SpendDashboardSource.scanDays,
            scopeSignature: scopeSignature,
            providerConfigRevision: self.settings.providerConfigRevision(for: .codex),
            costUsageSettingsRevision: self.settings.costUsageSettingsRevision)
        self.spendDashboardCodexCostCatchUpToken = token
        self.spendDashboardCodexCostCatchUpScopeSignature = scopeSignature
        self.spendDashboardCodexCostCatchUpMode = mode
        self.spendDashboardCodexCostCatchUpStopRequested = false
        self.spendDashboardCodexCostCatchUpPassIsRunning = false
        let priority: TaskPriority = mode == .accelerated ? .utility : .background
        self.spendDashboardCodexCostCatchUpTask = Task(priority: priority) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.spendDashboardCodexCostCatchUpToken == token {
                    self.spendDashboardCodexCostCatchUpTask = nil
                    self.spendDashboardCodexCostCatchUpToken = nil
                    self.spendDashboardCodexCostCatchUpScopeSignature = nil
                }
            }
            await self.runSpendDashboardCodexCostCatchUp(context: context)
        }
    }

    func stopSpendDashboardCodexCostCatchUp() {
        guard self.spendDashboardCodexCostCatchUpTask != nil else { return }
        self.spendDashboardCodexCostCatchUpStopRequested = true
        guard !self.spendDashboardCodexCostCatchUpPassIsRunning else { return }
        if let activity = self.spendDashboardCodexCostCatchUpActivity {
            self.spendDashboardCodexCostCatchUpActivity = CodexCostCatchUpActivity(
                phase: .paused,
                mode: activity.mode,
                processedBytes: activity.processedBytes,
                totalBytes: activity.totalBytes,
                completedFiles: activity.completedFiles,
                totalFiles: activity.totalFiles,
                pauseReason: .user,
                staleSnapshotUpdatedAt: activity.staleSnapshotUpdatedAt)
        }
        self.spendDashboardCodexCostCatchUpTask?.cancel()
        self.spendDashboardCodexCostCatchUpTask = nil
        self.spendDashboardCodexCostCatchUpToken = nil
        self.spendDashboardCodexCostCatchUpScopeSignature = nil
    }

    func cancelSpendDashboardCodexCostCatchUp() {
        self.spendDashboardCodexCostCatchUpTask?.cancel()
        self.spendDashboardCodexCostCatchUpTask = nil
        self.spendDashboardCodexCostCatchUpToken = nil
        self.spendDashboardCodexCostCatchUpScopeSignature = nil
        self.spendDashboardCodexCostCatchUpStopRequested = false
        self.spendDashboardCodexCostCatchUpPassIsRunning = false
        self.spendDashboardCodexCostCatchUpActivity = nil
    }

    // This is an intentional async state machine: account fairness, cancellation, retry, and
    // publication transitions share ordering-sensitive state across each bounded pass.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func runSpendDashboardCodexCostCatchUp(
        context: SpendDashboardCodexCostCatchUpContext) async
    {
        var statuses = await self.loadSpendDashboardCodexCostCatchUpStatuses(context.accounts)
            .mapValues { $0.requiringTransientRetry() }
        guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
        self.publishSpendDashboardCodexCostCatchUpActivity(
            statuses: statuses,
            context: context,
            phase: Self.spendDashboardCodexCatchUpIsPending(statuses) ? .indexing : .complete)

        var didChangeCache = false
        var previousActiveDuration: TimeInterval?
        var stalledCacheIdentities: Set<String> = []
        var transientNoProgressKeys: [String: String] = [:]
        var deferredCacheIdentitiesThisSweep: Set<String> = []
        var attemptedCacheIdentitiesThisSweep: Set<String> = []
        var unavailableRefreshLockRetryCounts: [String: Int] = [:]
        var terminalUnavailableRefreshLockCacheIdentities: Set<String> = []
        while Self.spendDashboardCodexCatchUpIsPending(statuses) {
            do {
                guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
                if self.spendDashboardCodexCostCatchUpStopRequested {
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: .user)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    return
                }

                guard let account = context.accounts.first(where: {
                    statuses[$0.cacheIdentity]?.pending == true
                        && !stalledCacheIdentities.contains($0.cacheIdentity)
                        && !terminalUnavailableRefreshLockCacheIdentities.contains($0.cacheIdentity)
                        && !deferredCacheIdentitiesThisSweep.contains($0.cacheIdentity)
                        && !attemptedCacheIdentitiesThisSweep.contains($0.cacheIdentity)
                }) else {
                    let hasRunnablePendingAccount = context.accounts.contains {
                        statuses[$0.cacheIdentity]?.pending == true
                            && !stalledCacheIdentities.contains($0.cacheIdentity)
                            && !terminalUnavailableRefreshLockCacheIdentities.contains($0.cacheIdentity)
                    }
                    if hasRunnablePendingAccount {
                        // Every pending account gets one turn per sweep, including healthy
                        // accounts that remain pending for many slices. Back off once when a
                        // sweep observed transient contention or no progress.
                        attemptedCacheIdentitiesThisSweep.removeAll(keepingCapacity: true)
                        let needsBackoff = !deferredCacheIdentitiesThisSweep.isEmpty
                        deferredCacheIdentitiesThisSweep.removeAll(keepingCapacity: true)
                        if needsBackoff {
                            try await self.sleepBetweenSpendDashboardCodexCostCatchUpPasses(seconds: 1)
                        }
                        continue
                    }
                    let pauseReason: CodexCostCatchUpPauseReason =
                        terminalUnavailableRefreshLockCacheIdentities.isEmpty
                            ? .noProgress
                            : .error(
                                CostUsageFetcher.CodexScanCatchUpStatus
                                    .refreshLockUnavailableErrorMessage)
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: pauseReason)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    if terminalUnavailableRefreshLockCacheIdentities.isEmpty {
                        CodexBarLog.logger(LogCategories.tokenCost).warning(
                            "Spend Dashboard Codex cost catch-up stopped because all pending account caches stalled")
                    } else {
                        CodexBarLog.logger(LogCategories.tokenCost).warning(
                            "Spend Dashboard Codex cost catch-up stopped after refresh-lock errors")
                    }
                    return
                }

                let decision = self.spendDashboardCodexCostCatchUpDecision(
                    mode: self.spendDashboardCodexCostCatchUpMode,
                    previousActiveDuration: previousActiveDuration)
                switch decision.action {
                case let .pause(delay, reason):
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: reason)
                    try await self.sleepBetweenSpendDashboardCodexCostCatchUpPasses(seconds: delay)
                    continue
                case let .runAfter(delay):
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .indexing)
                    try await self.sleepBetweenSpendDashboardCodexCostCatchUpPasses(seconds: delay)
                }

                try Task.checkCancellation()
                guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
                if self.spendDashboardCodexCostCatchUpStopRequested {
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: .user)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    return
                }

                let previousStatus = statuses[account.cacheIdentity]
                let passStartedAt = ContinuousClock.now
                self.spendDashboardCodexCostCatchUpPassIsRunning = true
                let loadedStatus: CostUsageFetcher.CodexScanCatchUpStatus
                do {
                    loadedStatus = try await self.advanceSpendDashboardCodexCostCatchUp(
                        account: account,
                        now: Date(),
                        historyDays: context.historyDays)
                    self.spendDashboardCodexCostCatchUpPassIsRunning = false
                } catch {
                    self.spendDashboardCodexCostCatchUpPassIsRunning = false
                    throw error
                }
                let nextStatus = loadedStatus.requiresTransientRetry
                    ? loadedStatus.requiringTransientRetry()
                    : loadedStatus
                previousActiveDuration = Self.spendDashboardCodexCatchUpDuration(
                    since: passStartedAt)
                attemptedCacheIdentitiesThisSweep.insert(account.cacheIdentity)
                didChangeCache = didChangeCache || nextStatus.progressKey != previousStatus?.progressKey
                statuses[account.cacheIdentity] = nextStatus
                var shouldDeferUntilNextSweep = false
                if nextStatus.refreshLockUnavailable {
                    let retryCount = unavailableRefreshLockRetryCounts[account.cacheIdentity, default: 0]
                    if retryCount >= 1 {
                        // This account cannot create its refresh-lock domain. Stop retrying it
                        // for this run, but let independent sibling caches finish before the
                        // dashboard publishes the terminal error.
                        unavailableRefreshLockRetryCounts.removeValue(forKey: account.cacheIdentity)
                        terminalUnavailableRefreshLockCacheIdentities.insert(account.cacheIdentity)
                        transientNoProgressKeys.removeValue(forKey: account.cacheIdentity)
                        stalledCacheIdentities.remove(account.cacheIdentity)
                    } else {
                        unavailableRefreshLockRetryCounts[account.cacheIdentity] = retryCount + 1
                        terminalUnavailableRefreshLockCacheIdentities.remove(account.cacheIdentity)
                        transientNoProgressKeys.removeValue(forKey: account.cacheIdentity)
                        stalledCacheIdentities.remove(account.cacheIdentity)
                        shouldDeferUntilNextSweep = true
                    }
                } else if nextStatus.deferredByConcurrentWriter {
                    unavailableRefreshLockRetryCounts.removeValue(forKey: account.cacheIdentity)
                    terminalUnavailableRefreshLockCacheIdentities.remove(account.cacheIdentity)
                    transientNoProgressKeys.removeValue(forKey: account.cacheIdentity)
                    stalledCacheIdentities.remove(account.cacheIdentity)
                    shouldDeferUntilNextSweep = true
                } else if nextStatus.pending,
                          nextStatus.progressKey == previousStatus?.progressKey
                {
                    unavailableRefreshLockRetryCounts.removeValue(forKey: account.cacheIdentity)
                    terminalUnavailableRefreshLockCacheIdentities.remove(account.cacheIdentity)
                    if transientNoProgressKeys[account.cacheIdentity] == nextStatus.progressKey {
                        transientNoProgressKeys.removeValue(forKey: account.cacheIdentity)
                        stalledCacheIdentities.insert(account.cacheIdentity)
                    } else {
                        // Source mutation and transient sidecar persistence failures deliberately
                        // keep the published progress key unchanged. Retry one bounded pass after
                        // a short backoff before declaring this account permanently stalled.
                        transientNoProgressKeys[account.cacheIdentity] = nextStatus.progressKey
                        stalledCacheIdentities.remove(account.cacheIdentity)
                        shouldDeferUntilNextSweep = true
                    }
                } else {
                    unavailableRefreshLockRetryCounts.removeValue(forKey: account.cacheIdentity)
                    terminalUnavailableRefreshLockCacheIdentities.remove(account.cacheIdentity)
                    transientNoProgressKeys.removeValue(forKey: account.cacheIdentity)
                    stalledCacheIdentities.remove(account.cacheIdentity)
                }
                if shouldDeferUntilNextSweep {
                    deferredCacheIdentitiesThisSweep.insert(account.cacheIdentity)
                } else {
                    deferredCacheIdentitiesThisSweep.remove(account.cacheIdentity)
                }

                guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
                let isPending = Self.spendDashboardCodexCatchUpIsPending(statuses)
                self.publishSpendDashboardCodexCostCatchUpActivity(
                    statuses: statuses,
                    context: context,
                    phase: isPending ? .indexing : .complete)
                if self.spendDashboardCodexCostCatchUpStopRequested {
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: .user)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                self.publishSpendDashboardCodexCostCatchUpActivity(
                    statuses: statuses,
                    context: context,
                    phase: .paused,
                    pauseReason: .error(error.localizedDescription))
                self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                CodexBarLog.logger(LogCategories.tokenCost).warning(
                    "Spend Dashboard Codex cost catch-up stopped after error: \(error.localizedDescription)")
                return
            }
        }

        self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
    }

    private func spendDashboardCodexCostCatchUpContextIsCurrent(
        _ context: SpendDashboardCodexCostCatchUpContext) -> Bool
    {
        !Task.isCancelled
            && self.spendDashboardCodexCostCatchUpToken == context.token
            && self.spendDashboardCodexCostCatchUpScopeSignature == context.scopeSignature
            && self.settings.providerConfigRevision(for: .codex) == context.providerConfigRevision
            && self.settings.costUsageSettingsRevision == context.costUsageSettingsRevision
            && self.settings.isCostUsageEffectivelyEnabled(for: .codex)
            && self.isEnabled(.codex)
            && context.accounts.allSatisfy(SpendDashboardSource.codexAuthFingerprintMatches)
    }

    private func loadSpendDashboardCodexCostCatchUpStatuses(
        _ accounts: [CodexSpendScanRequest]) async -> [String: CostUsageFetcher.CodexScanCatchUpStatus]
    {
        var statuses: [String: CostUsageFetcher.CodexScanCatchUpStatus] = [:]
        for account in accounts {
            if let override = self._test_spendDashboardCodexCostCatchUpStatusOverride {
                statuses[account.cacheIdentity] = await override(account)
            } else {
                statuses[account.cacheIdentity] = await CostUsageFetcher(
                    cacheRoot: SpendDashboardSource.codexCacheRoot(for: account),
                    codexRefreshLockRoot: SpendDashboardSource.codexCacheFamilyRoot())
                    .codexScanCatchUpStatus(codexHomePath: account.homePath)
            }
        }
        return statuses
    }

    private func advanceSpendDashboardCodexCostCatchUp(
        account: CodexSpendScanRequest,
        now: Date,
        historyDays: Int) async throws -> CostUsageFetcher.CodexScanCatchUpStatus
    {
        if let override = self._test_spendDashboardCodexCostCatchUpAdvanceOverride {
            return try await override(account, now, historyDays)
        }
        return try await CostUsageFetcher(
            cacheRoot: SpendDashboardSource.codexCacheRoot(for: account),
            codexRefreshLockRoot: SpendDashboardSource.codexCacheFamilyRoot())
            .advanceCodexScanCatchUp(
                now: now,
                codexHomePath: account.homePath,
                historyDays: historyDays)
    }

    private func spendDashboardCodexCostCatchUpDecision(
        mode: CodexCostCatchUpMode,
        previousActiveDuration: TimeInterval?) -> CodexCostCatchUpPolicy.Decision
    {
        let resourceState = self._test_spendDashboardCodexCostCatchUpResourceStateOverride?() ?? (
            powerSource: CodexCostCatchUpPowerSource.current(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
        return CodexCostCatchUpPolicy().decision(for: .init(
            mode: mode,
            previousActiveDuration: previousActiveDuration,
            powerSource: resourceState.powerSource,
            lowPowerModeEnabled: resourceState.lowPowerModeEnabled,
            thermalState: resourceState.thermalState))
    }

    private func publishSpendDashboardCodexCostCatchUpActivity(
        statuses: [String: CostUsageFetcher.CodexScanCatchUpStatus],
        context: SpendDashboardCodexCostCatchUpContext,
        phase: CodexCostCatchUpActivity.Phase,
        pauseReason: CodexCostCatchUpPauseReason? = nil)
    {
        guard self.spendDashboardCodexCostCatchUpToken == context.token else { return }
        let values = context.accounts.compactMap { statuses[$0.cacheIdentity] }
        let hasIndeterminatePendingStatus = values.contains {
            $0.pending && $0.totalBytes == 0 && $0.totalFiles == 0
        }
        self.spendDashboardCodexCostCatchUpActivity = CodexCostCatchUpActivity(
            phase: phase,
            mode: self.spendDashboardCodexCostCatchUpMode,
            processedBytes: hasIndeterminatePendingStatus ? 0 : values.reduce(0) { $0 + $1.processedBytes },
            totalBytes: hasIndeterminatePendingStatus ? 0 : values.reduce(0) { $0 + $1.totalBytes },
            completedFiles: hasIndeterminatePendingStatus ? 0 : values.reduce(0) { $0 + $1.completedFiles },
            totalFiles: hasIndeterminatePendingStatus ? 0 : values.reduce(0) { $0 + $1.totalFiles },
            pauseReason: pauseReason,
            staleSnapshotUpdatedAt: values.compactMap(\.staleSnapshotUpdatedAt).min())
    }

    private func publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(_ didChangeCache: Bool) {
        guard didChangeCache else { return }
        self.spendDashboardCodexCostCatchUpRevision &+= 1
    }

    private func sleepBetweenSpendDashboardCodexCostCatchUpPasses(seconds: TimeInterval) async throws {
        if let override = self._test_spendDashboardCodexCostCatchUpSleepOverride {
            try await override(max(0, seconds))
            return
        }
        guard seconds > 0 else {
            await Task.yield()
            return
        }
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func uniqueSpendDashboardCodexAccounts(
        _ accounts: [CodexSpendScanRequest]) -> [CodexSpendScanRequest]
    {
        var seen: Set<String> = []
        return accounts.filter { seen.insert($0.cacheIdentity).inserted }
    }

    private static func spendDashboardCodexCatchUpIsPending(
        _ statuses: [String: CostUsageFetcher.CodexScanCatchUpStatus]) -> Bool
    {
        statuses.values.contains(where: \.pending)
    }

    private static func spendDashboardCodexCatchUpDuration(
        since start: ContinuousClock.Instant) -> TimeInterval
    {
        let components = (ContinuousClock.now - start).components
        return max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
