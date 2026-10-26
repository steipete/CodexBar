import CodexBarCore
import Foundation

private struct CodexCostCatchUpContext {
    let token: UUID
    let codexHomePath: String?
    let historyDays: Int
    let scopeSignature: String
    let providerConfigRevision: UInt64
    let costUsageSettingsRevision: UInt64
    let includePiSessions: Bool
    @ProcessEnvironment private(set) var environment: [String: String]
    let piHistoryScopeGeneration: UInt64
}

extension UsageStore {
    func startCodexCostCatchUpIfNeeded(afterRefreshing provider: UsageProvider) {
        guard provider == .codex else { return }
        if self.codexCostCatchUpStopRequested || self.codexCostCatchUpActivity?.requiresExplicitResume == true {
            guard ProviderInteractionContext.current == .userInitiated,
                  self.codexCostCatchUpTask == nil else { return }
        }
        self.startCodexCostCatchUpIfNeeded(mode: .automatic)
    }

    func startCodexCostCatchUpIfNeeded(mode: CodexCostCatchUpMode = .automatic) {
        let scope = self.tokenCostScope(for: .codex)
        let scopeSignature = self.tokenSnapshotScopeSignature(for: .codex)
        if self.codexCostCatchUpTask != nil,
           self.codexCostCatchUpScopeSignature == scopeSignature
        {
            if self.codexCostCatchUpMode == mode {
                // Hydration can observe a complete cache while the foreground refresh that follows it
                // creates new tail work. Keep one restart queued so that refresh cannot lose the race
                // with the existing task's completion cleanup.
                self.codexCostCatchUpRestartRequested = true
                return
            }
            self.codexCostCatchUpMode = mode
            // Never cancel a pass while it may be committing a resume checkpoint. The new mode
            // applies immediately after that bounded pass completes.
            if self.codexCostCatchUpPassIsRunning {
                return
            }
        }

        self.cancelCodexCostCatchUp()
        let token = UUID()
        let context = CodexCostCatchUpContext(
            token: token,
            codexHomePath: scope.codexHomePath,
            historyDays: self.settings.costUsageHistoryDays,
            scopeSignature: scopeSignature,
            providerConfigRevision: self.settings.providerConfigRevision(for: .codex),
            costUsageSettingsRevision: self.settings.costUsageSettingsRevision,
            includePiSessions: self.shouldIncludePiSessionsInTokenSnapshot(for: .codex),
            environment: self.environmentBase,
            piHistoryScopeGeneration: self.piHistoryScopeGeneration)
        self.codexCostCatchUpToken = token
        self.codexCostCatchUpScopeSignature = scopeSignature
        self.codexCostCatchUpMode = mode
        self.codexCostCatchUpStopRequested = false
        self.codexCostCatchUpPassIsRunning = false
        let priority: TaskPriority = mode == .accelerated ? .utility : .background
        self.codexCostCatchUpTask = Task(priority: priority) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.codexCostCatchUpToken == token {
                    self.codexCostCatchUpTask = nil
                    self.codexCostCatchUpToken = nil
                    self.codexCostCatchUpScopeSignature = nil
                    let restartRequested = self.codexCostCatchUpRestartRequested
                    self.codexCostCatchUpRestartRequested = false
                    if restartRequested, self.codexCostCatchUpActivity?.requiresExplicitResume != true {
                        self.startCodexCostCatchUpIfNeeded(mode: self.codexCostCatchUpMode)
                    }
                }
            }
            await self.runCodexCostCatchUp(context: context)
        }
    }

    func cancelCodexCostCatchUp() {
        self.codexCostCatchUpTask?.cancel()
        self.codexCostCatchUpTask = nil
        self.codexCostCatchUpToken = nil
        self.codexCostCatchUpScopeSignature = nil
        self.codexCostCatchUpStopRequested = false
        self.codexCostCatchUpPassIsRunning = false
        self.codexCostCatchUpRestartRequested = false
        self.codexCostCatchUpActivity = nil
    }

    func stopCodexCostCatchUp() {
        guard self.codexCostCatchUpTask != nil else { return }
        self.codexCostCatchUpStopRequested = true
        self.codexCostCatchUpRestartRequested = false
        guard !self.codexCostCatchUpPassIsRunning else { return }
        self.codexCostCatchUpActivity?.phase = .paused
        self.codexCostCatchUpActivity?.pauseReason = .user
        self.codexCostCatchUpTask?.cancel()
        self.codexCostCatchUpTask = nil
        self.codexCostCatchUpToken = nil
        self.codexCostCatchUpScopeSignature = nil
    }

    private func runCodexCostCatchUp(context: CodexCostCatchUpContext) async {
        func publish(
            _ status: CostUsageFetcher.CodexScanCatchUpStatus,
            _ phase: CodexCostCatchUpActivity.Phase,
            _ reason: CodexCostCatchUpPauseReason? = nil)
        {
            self.publishCodexCostCatchUpActivity(status: status, context: context, phase: phase, pauseReason: reason)
        }
        var previousActiveDuration: TimeInterval?
        var completedPasses = 0
        var recoveredEmptyPass = false
        while self.codexCostCatchUpContextIsCurrent(context) {
            var status = await self.loadCodexCostCatchUpStatus(codexHomePath: context.codexHomePath)
            publish(status, status.pending ? .indexing : .complete)
            var didAdvance = false
            var publishedCurrentWindow = false
            var seenProgressKeys: Set<String> = [status.progressKey]
            while status.pending {
                do {
                    try self.checkCodexCostCatchUpContinuation(status: status, context: context)

                    if !publishedCurrentWindow,
                       let publishedStatus = try await self.publishAvailableCodexCostCatchUpSnapshot(context: context)
                    {
                        publishedCurrentWindow = true
                        status = publishedStatus
                        guard status.pending else { return }
                    }
                    try self.checkCodexCostCatchUpContinuation(
                        status: status,
                        context: context)
                    let decision = self.codexCostCatchUpDecision(
                        mode: self.codexCostCatchUpMode,
                        previousActiveDuration: previousActiveDuration,
                        completedPasses: completedPasses,
                        resourceState: self._test_codexCostCatchUpResourceStateOverride?())
                    switch decision.action {
                    case let .pause(delay, reason):
                        publish(status, .paused, reason)
                        try await self.sleepBetweenCodexCostCatchUpPasses(seconds: delay)
                        continue
                    case let .runAfter(delay):
                        publish(status, .indexing)
                        if delay > 0 || self.codexCostCatchUpMode == .accelerated {
                            previousActiveDuration = nil
                            completedPasses = 0
                        }
                        try await self.sleepBetweenCodexCostCatchUpPasses(seconds: delay)
                    }

                    try self.checkCodexCostCatchUpContinuation(
                        status: status,
                        context: context)

                    let previousProgressKey = status.progressKey
                    let result = try await self.advanceCodexCostCatchUp(
                        codexHomePath: context.codexHomePath,
                        historyDays: context.historyDays,
                        previousActiveDuration: previousActiveDuration)
                    let nextStatus = result.value
                    previousActiveDuration = (previousActiveDuration ?? 0) + result.activeDuration
                    completedPasses += 1
                    didAdvance = true
                    try self.checkCodexCostCatchUpContinuation(status: nextStatus, context: context)
                    publish(nextStatus, nextStatus.pending ? .indexing : .complete)
                    status = nextStatus
                    if status.pending,
                       let publishedStatus = try await self.publishAvailableCodexCostCatchUpSnapshot(context: context)
                    {
                        publishedCurrentWindow = true
                        status = publishedStatus
                        guard status.pending else { return }
                    }
                    if nextStatus.pending, !seenProgressKeys.insert(nextStatus.progressKey).inserted {
                        if !recoveredEmptyPass, nextStatus.progressKey == previousProgressKey,
                           nextStatus.yieldedBeforeFileAttempt
                        {
                            recoveredEmptyPass = true
                            previousActiveDuration = max(
                                previousActiveDuration ?? 0,
                                CodexCostCatchUpPolicy.automaticBurstDuration)
                        } else {
                            publish(nextStatus, .paused, .noProgress)
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    publish(status, .paused, .error(error.localizedDescription))
                    CodexBarLog.logger(LogCategories.tokenCost).warning(
                        "Codex cost catch-up stopped after error: \(error.localizedDescription)")
                    return
                }
            }

            guard self.codexCostCatchUpContextIsCurrent(context), didAdvance else { return }
            do {
                guard let publishedStatus = try await self.publishAvailableCodexCostCatchUpSnapshot(context: context)
                else {
                    let message = "Completed Codex cost history is unavailable; waiting for the next refresh."
                    publish(status, .paused, .error(message))
                    CodexBarLog.logger(LogCategories.tokenCost)
                        .warning("Codex cost catch-up final snapshot failed: \(message)")
                    return
                }
                status = publishedStatus
                guard status.pending else { return }
            } catch is CancellationError {
                return
            } catch {
                publish(status, .paused, .error(error.localizedDescription))
                CodexBarLog.logger(LogCategories.tokenCost).warning(
                    "Codex cost catch-up final snapshot failed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func checkCodexCostCatchUpContinuation(
        status: CostUsageFetcher.CodexScanCatchUpStatus,
        context: CodexCostCatchUpContext) throws
    {
        guard self.codexCostCatchUpContextIsCurrent(context) else { throw CancellationError() }
        if self.codexCostCatchUpStopRequested {
            self.publishCodexCostCatchUpActivity(status: status, context: context, phase: .paused, pauseReason: .user)
            throw CancellationError()
        }
    }

    private func publishAvailableCodexCostCatchUpSnapshot(
        context: CodexCostCatchUpContext) async throws -> CostUsageFetcher.CodexScanCatchUpStatus?
    {
        let now = Date()
        // Provider-specific by design: Codex owns resumable cost catch-up and this guarded completed-cache publication.
        let publicationRevision = self.tokenSnapshotPublicationRevision(for: .codex)
        let result: (
            snapshot: CostUsageTokenSnapshot,
            lastRefreshAt: Date?,
            staleSnapshotUpdatedAt: Date?,
            accounting: PiSnapshotAccounting?)? = if let override = self._test_cachedCodexTokenSnapshotLoaderOverride
        {
            await override(now, context.codexHomePath, context.historyDays)
                .map { ($0.snapshot, $0.lastRefreshAt, $0.staleSnapshotUpdatedAt, nil) }
        } else {
            await self.costUsageFetcher.loadCachedCodexTokenSnapshotResult(
                now: now,
                codexHomePath: context.codexHomePath,
                historyDays: context.historyDays,
                includePiSessions: context.includePiSessions,
                includeOpenCodeLocalHistory: self.shouldIncludeOpenCodeLocalHistory,
                calendar: self.settings.costUsageBucketCalendar,
                requireCompleteHistory: true,
                environment: context.environment)
                .map { ($0.snapshot, $0.lastRefreshAt, $0.staleSnapshotUpdatedAt, $0.accounting) }
        }
        try Task.checkCancellation()
        // Provider-specific by design: Codex owns completed-cache publication and account validation here.
        guard await self.refreshPiHistoryScope(for: .codex) else { throw CancellationError() }
        guard self.codexCostCatchUpContextIsCurrent(context),
              self.tokenSnapshotPublicationRevision(for: .codex) == publicationRevision
        else {
            if context.includePiSessions, self.piHistoryScopeGeneration != context.piHistoryScopeGeneration {
                self.requestTokenRefreshAfterStaleCompletion(for: .codex)
            }
            throw CancellationError()
        }
        guard let result,
              result.snapshot.historyCoverageIsEstablished,
              result.staleSnapshotUpdatedAt == nil,
              self.tokenAccountingScopeIsCurrent(result.accounting, for: .codex)
        else { return nil }
        let snapshot = result.snapshot

        if let lastRefreshAt = result.lastRefreshAt {
            self.lastTokenFetchAt[.codex] = lastRefreshAt
            self.lastTokenFetchScope[.codex] = context.scopeSignature
        }
        if snapshot.daily.isEmpty, snapshot.meteredCostUSD == nil {
            self.publishConfirmedEmptyTokenSnapshot(for: .codex, accounting: result.accounting)
            self.tokenErrors[.codex] = Self.tokenCostNoDataMessage(for: .codex)
        } else {
            self.publishTokenSnapshot(snapshot, for: .codex, accounting: result.accounting)
            self.tokenErrors[.codex] = nil
        }
        self.tokenFailureGates[.codex]?.recordSuccess()
        self.persistWidgetSnapshot(reason: "token-usage-catch-up")

        let status = await self.loadCodexCostCatchUpStatus(codexHomePath: context.codexHomePath)
        self.publishCodexCostCatchUpActivity(
            status: status,
            context: context,
            phase: status.pending ? .indexing : .complete)
        return status
    }

    private func codexCostCatchUpContextIsCurrent(_ context: CodexCostCatchUpContext) -> Bool {
        !Task.isCancelled
            && self.codexCostCatchUpToken == context.token
            && self.settings.providerConfigRevision(for: .codex) == context.providerConfigRevision
            && self.settings.costUsageSettingsRevision == context.costUsageSettingsRevision
            && self.settings.costUsageHistoryDays == context.historyDays
            && self.settings.isCostUsageEffectivelyEnabled(for: .codex)
            && self.isEnabled(.codex)
            && self.tokenCostScope(for: .codex).codexHomePath == context.codexHomePath
            && self.tokenSnapshotScopeSignature(for: .codex) == context.scopeSignature
    }

    private func loadCodexCostCatchUpStatus(
        codexHomePath: String?) async -> CostUsageFetcher.CodexScanCatchUpStatus
    {
        if let override = self._test_codexCostCatchUpStatusOverride {
            return await override(codexHomePath)
        }
        return await self.costUsageFetcher.codexScanCatchUpStatus(
            codexHomePath: codexHomePath,
            calendar: self.settings.costUsageBucketCalendar,
            includeOpenCodeLocalHistory: self.shouldIncludeOpenCodeLocalHistory,
            environment: self.environmentBase)
    }

    private func advanceCodexCostCatchUp(
        codexHomePath: String?,
        historyDays: Int,
        previousActiveDuration: TimeInterval?) async throws
        -> CostUsageScanExecutor.TimedResult<CostUsageFetcher.CodexScanCatchUpStatus>
    {
        let durationBudget = self.codexCostCatchUpMode.scanDurationPerRefresh(after: previousActiveDuration)
        self._test_codexCostCatchUpBudgetObserver?(durationBudget)
        self.codexCostCatchUpPassIsRunning = true
        defer { self.codexCostCatchUpPassIsRunning = false }
        if let override = self._test_codexCostCatchUpAdvanceOverride {
            return try await .init(
                value: override(Date(), codexHomePath, historyDays),
                activeDuration: self._test_codexCostCatchUpActiveDuration)
        }
        return try await self.costUsageFetcher.advanceCodexScanCatchUp(
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            scanDurationPerRefresh: durationBudget,
            calendar: self.settings.costUsageBucketCalendar,
            includeOpenCodeLocalHistory: self.shouldIncludeOpenCodeLocalHistory,
            environment: self.environmentBase)
    }

    func codexCostCatchUpDecision(
        mode: CodexCostCatchUpMode,
        previousActiveDuration: TimeInterval?,
        completedPasses: Int = 0,
        resourceState: (
            powerSource: CodexCostCatchUpPowerSource,
            lowPowerModeEnabled: Bool,
            thermalState: ProcessInfo.ThermalState)? = nil)
        -> CodexCostCatchUpPolicy.Decision
    {
        let resourceState = resourceState ?? (
            powerSource: CodexCostCatchUpPowerSource.current(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: mode,
            previousActiveDuration: previousActiveDuration,
            powerSource: resourceState.powerSource,
            lowPowerModeEnabled: resourceState.lowPowerModeEnabled,
            thermalState: resourceState.thermalState,
            completedPasses: completedPasses))
        guard mode == .automatic, case let .runAfter(delay) = decision.action else { return decision }
        let interval = BackgroundWorkPowerPolicy.automaticInterval(
            delay,
            lowPowerModeEnabled: self.settings.backgroundWorkLowPowerModeEnabled) ?? delay
        return .init(action: .runAfter(interval), targetDutyCycle: decision.targetDutyCycle)
    }

    private func publishCodexCostCatchUpActivity(
        status: CostUsageFetcher.CodexScanCatchUpStatus,
        context: CodexCostCatchUpContext,
        phase: CodexCostCatchUpActivity.Phase,
        pauseReason: CodexCostCatchUpPauseReason? = nil)
    {
        guard self.codexCostCatchUpToken == context.token else { return }
        self.codexCostCatchUpActivity = CodexCostCatchUpActivity(
            phase: phase,
            mode: self.codexCostCatchUpMode,
            processedBytes: status.processedBytes,
            totalBytes: status.totalBytes,
            completedFiles: status.completedFiles,
            totalFiles: status.totalFiles,
            pauseReason: pauseReason,
            staleSnapshotUpdatedAt: status.staleSnapshotUpdatedAt)
    }

    func sleepBetweenCodexCostCatchUpPasses(seconds: TimeInterval, dashboard: Bool = false) async throws {
        if let override = dashboard
            ? self._test_spendDashboardCodexCostCatchUpSleepOverride : self._test_codexCostCatchUpSleepOverride
        {
            try await override(max(0, seconds))
            return
        }
        guard seconds > 0 else {
            await Task.yield()
            return
        }
        try await Task.sleep(for: .seconds(seconds))
    }
}
