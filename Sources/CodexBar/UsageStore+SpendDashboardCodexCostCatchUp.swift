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
    func refreshSpendDashboard(accounts: [CodexSpendScanRequest]) {
        self.sharedSpendDashboardController().refresh()
        guard self.spendDashboardCodexCostCatchUpRequiresExplicitResume else { return }
        self.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .automatic)
    }

    func synchronizeSpendDashboardCodexCostCatchUp(
        accounts: [CodexSpendScanRequest],
        preferredMode: CodexCostCatchUpMode? = nil)
    {
        let accounts = Self.uniqueSpendDashboardCodexAccounts(accounts)
        guard !accounts.isEmpty,
              self.settings.isCostUsageEffectivelyEnabled(for: .codex),
              self.isEnabled(.codex)
        else {
            self.cancelSpendDashboardCodexCostCatchUp()
            return
        }
        // Observation-driven reloads must not undo a stop or repeatedly retry a stalled/failed pass.
        // Explicit Refresh uses startSpendDashboardCodexCostCatchUpIfNeeded directly.
        guard !self.spendDashboardCodexCostCatchUpStopRequested,
              !self.spendDashboardCodexCostCatchUpRequiresExplicitResume else { return }
        var mode = preferredMode
            ?? (self.spendDashboardCodexCostCatchUpTask == nil ? .automatic : self.spendDashboardCodexCostCatchUpMode)
        if preferredMode == .accelerated,
           self.spendDashboardCodexCostCatchUpTask == nil
           || self.spendDashboardCodexCostCatchUpMode != .accelerated,
           case .pause = self.spendDashboardCodexCostCatchUpDecision(
               mode: .automatic,
               previousActiveDuration: nil).action
        {
            mode = .automatic
        }
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

        let historyDays = max(SpendDashboardSource.scanDays, self.settings.costUsageHistoryDays)
        let accountScopeSignature = accounts
            .map { "\($0.id)|\($0.cacheIdentity)" }
            .joined(separator: "\u{0}")
        let scopeSignature = "\(historyDays)\u{0}\(accountScopeSignature)"
        if self.spendDashboardCodexCostCatchUpTask != nil,
           self.spendDashboardCodexCostCatchUpScopeSignature == scopeSignature
        {
            if self.spendDashboardCodexCostCatchUpMode == mode {
                // A dashboard reload can discover fresh tail work while the previous task is
                // completing. Queue one restart so that the new pending status retains a worker.
                self.spendDashboardCodexCostCatchUpRestartRequested = true
                return
            }
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
            historyDays: historyDays,
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
                    let restartRequested = self.spendDashboardCodexCostCatchUpRestartRequested
                    self.spendDashboardCodexCostCatchUpRestartRequested = false
                    if restartRequested, !self.spendDashboardCodexCostCatchUpRequiresExplicitResume {
                        self.startSpendDashboardCodexCostCatchUpIfNeeded(
                            accounts: context.accounts,
                            mode: self.spendDashboardCodexCostCatchUpMode)
                    }
                }
            }
            await self.runSpendDashboardCodexCostCatchUp(context: context)
        }
    }

    func stopSpendDashboardCodexCostCatchUp() {
        guard self.spendDashboardCodexCostCatchUpTask != nil else { return }
        self.spendDashboardCodexCostCatchUpStopRequested = true
        self.spendDashboardCodexCostCatchUpRestartRequested = false
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
        self.spendDashboardCodexCostCatchUpRestartRequested = false
        self.spendDashboardCodexCostCatchUpActivity = nil
    }

    private var spendDashboardCodexCostCatchUpRequiresExplicitResume: Bool {
        guard let activity = self.spendDashboardCodexCostCatchUpActivity,
              activity.phase == .paused else { return false }
        switch activity.pauseReason {
        case .user, .noProgress, .error:
            return true
        case .lowPower, .thermal, .none:
            return false
        }
    }

    private func runSpendDashboardCodexCostCatchUp(
        context: SpendDashboardCodexCostCatchUpContext) async
    {
        var statuses = await self.loadSpendDashboardCodexCostCatchUpStatuses(context.accounts)
        guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
        self.publishSpendDashboardCodexCostCatchUpActivity(
            statuses: statuses,
            context: context,
            phase: Self.spendDashboardCodexCatchUpIsPending(statuses) ? .indexing : .complete)

        var didChangeCache = false
        var previousActiveDuration: TimeInterval?
        var (stalledCacheIdentities, seenKeysByCache) =
            (Set<String>(), statuses.mapValues { Set([$0.progressKey]) })
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
                }) else {
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: .noProgress)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    CodexBarLog.logger(LogCategories.tokenCost).warning(
                        "Spend Dashboard Codex cost catch-up stopped because all pending account caches stalled")
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
                let nextStatus: CostUsageFetcher.CodexScanCatchUpStatus
                do {
                    defer {
                        // A cancelled pass can finish after its replacement has started.
                        if self.spendDashboardCodexCostCatchUpToken == context.token {
                            self.spendDashboardCodexCostCatchUpPassIsRunning = false
                        }
                    }
                    nextStatus = try await self.advanceSpendDashboardCodexCostCatchUp(
                        account: account,
                        now: Date(),
                        historyDays: context.historyDays)
                }
                previousActiveDuration = Self.spendDashboardCodexCatchUpDuration(
                    since: passStartedAt)
                didChangeCache = didChangeCache || nextStatus.progressKey != previousStatus?.progressKey
                statuses[account.cacheIdentity] = nextStatus
                if nextStatus.pending,
                   !seenKeysByCache[account.cacheIdentity, default: []].insert(nextStatus.progressKey).inserted
                {
                    stalledCacheIdentities.insert(account.cacheIdentity)
                } else {
                    stalledCacheIdentities.remove(account.cacheIdentity)
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
                guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
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
            && max(SpendDashboardSource.scanDays, self.settings.costUsageHistoryDays) == context.historyDays
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
                    calendar: self.settings.costUsageBucketCalendar)
                    .codexScanCatchUpStatus(
                        codexHomePath: account.homePath,
                        calendar: self.settings.costUsageBucketCalendar)
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
            calendar: self.settings.costUsageBucketCalendar)
            .advanceCodexScanCatchUp(
                now: now,
                codexHomePath: account.homePath,
                historyDays: historyDays,
                scanDurationPerRefresh: self.spendDashboardCodexCostCatchUpMode.scanDurationPerRefresh,
                calendar: self.settings.costUsageBucketCalendar)
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
