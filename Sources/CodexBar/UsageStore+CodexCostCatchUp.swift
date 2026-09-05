import CodexBarCore
import Foundation

private struct CodexCostCatchUpContext {
    let token: UUID
    let codexHomePath: String?
    let historyDays: Int
    let scopeSignature: String
    let providerConfigRevision: UInt64
    let costUsageSettingsRevision: UInt64
}

private enum CodexCostCatchUpPublicationError: LocalizedError {
    case completedHistoryUnavailable

    var errorDescription: String? {
        "Completed Codex cost history is unavailable; waiting for the next refresh."
    }
}

extension UsageStore {
    func startCodexCostCatchUpIfNeeded(afterRefreshing provider: UsageProvider) {
        guard provider == .codex else { return }
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
            costUsageSettingsRevision: self.settings.costUsageSettingsRevision)
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
                    if self.codexCostCatchUpRestartRequested {
                        self.codexCostCatchUpRestartRequested = false
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

    func startAcceleratedCodexCostCatchUp() {
        self.startCodexCostCatchUpIfNeeded(mode: .accelerated)
    }

    func returnCodexCostCatchUpToBackground() {
        self.startCodexCostCatchUpIfNeeded(mode: .automatic)
    }

    func stopCodexCostCatchUp() {
        guard self.codexCostCatchUpTask != nil else { return }
        self.codexCostCatchUpStopRequested = true
        self.codexCostCatchUpRestartRequested = false
        guard !self.codexCostCatchUpPassIsRunning else { return }
        if let activity = self.codexCostCatchUpActivity {
            self.codexCostCatchUpActivity = CodexCostCatchUpActivity(
                phase: .paused,
                mode: activity.mode,
                processedBytes: activity.processedBytes,
                totalBytes: activity.totalBytes,
                completedFiles: activity.completedFiles,
                totalFiles: activity.totalFiles,
                pauseReason: .user,
                staleSnapshotUpdatedAt: activity.staleSnapshotUpdatedAt)
        }
        self.codexCostCatchUpTask?.cancel()
        self.codexCostCatchUpTask = nil
        self.codexCostCatchUpToken = nil
        self.codexCostCatchUpScopeSignature = nil
    }

    private func runCodexCostCatchUp(context: CodexCostCatchUpContext) async {
        while self.codexCostCatchUpContextIsCurrent(context) {
            var status = await self.loadCodexCostCatchUpStatus(codexHomePath: context.codexHomePath)
            self.publishCodexCostCatchUpActivity(
                status: status,
                context: context,
                phase: status.pending ? .indexing : .complete)
            var didAdvance = false
            var (previousActiveDuration, seenProgressKeys): (TimeInterval?, Set<String>) =
                (nil, [status.progressKey])
            while status.pending {
                do {
                    guard self.codexCostCatchUpContextIsCurrent(context) else { return }
                    if self.codexCostCatchUpStopRequested {
                        self.publishCodexCostCatchUpActivity(
                            status: status,
                            context: context,
                            phase: .paused,
                            pauseReason: .user)
                        return
                    }

                    let decision = self.codexCostCatchUpDecision(
                        mode: self.codexCostCatchUpMode,
                        previousActiveDuration: previousActiveDuration)
                    switch decision.action {
                    case let .pause(delay, reason):
                        self.publishCodexCostCatchUpActivity(
                            status: status,
                            context: context,
                            phase: .paused,
                            pauseReason: reason)
                        try await self.sleepBetweenCodexCostCatchUpPasses(seconds: delay)
                        continue
                    case let .runAfter(delay):
                        self.publishCodexCostCatchUpActivity(
                            status: status,
                            context: context,
                            phase: .indexing)
                        try await self.sleepBetweenCodexCostCatchUpPasses(seconds: delay)
                    }

                    try Task.checkCancellation()
                    guard self.codexCostCatchUpContextIsCurrent(context) else { return }
                    if self.codexCostCatchUpStopRequested {
                        self.publishCodexCostCatchUpActivity(
                            status: status,
                            context: context,
                            phase: .paused,
                            pauseReason: .user)
                        return
                    }

                    let passStartedAt = ContinuousClock.now
                    self.codexCostCatchUpPassIsRunning = true
                    let nextStatus: CostUsageFetcher.CodexScanCatchUpStatus
                    do {
                        nextStatus = try await self.advanceCodexCostCatchUp(
                            now: Date(),
                            codexHomePath: context.codexHomePath,
                            historyDays: context.historyDays)
                        self.codexCostCatchUpPassIsRunning = false
                    } catch {
                        self.codexCostCatchUpPassIsRunning = false
                        throw error
                    }
                    let passDuration = ContinuousClock.now - passStartedAt
                    let durationComponents = passDuration.components
                    previousActiveDuration = max(
                        0,
                        Double(durationComponents.seconds)
                            + Double(durationComponents.attoseconds) / 1_000_000_000_000_000_000)
                    didAdvance = true
                    guard self.codexCostCatchUpContextIsCurrent(context) else { return }
                    self.publishCodexCostCatchUpActivity(
                        status: nextStatus,
                        context: context,
                        phase: nextStatus.pending ? .indexing : .complete)
                    if self.codexCostCatchUpStopRequested {
                        self.publishCodexCostCatchUpActivity(
                            status: nextStatus,
                            context: context,
                            phase: .paused,
                            pauseReason: .user)
                        return
                    }
                    if nextStatus.pending, !seenProgressKeys.insert(nextStatus.progressKey).inserted {
                        self.publishCodexCostCatchUpActivity(
                            status: nextStatus,
                            context: context,
                            phase: .paused,
                            pauseReason: .noProgress)
                        CodexBarLog.logger(LogCategories.tokenCost).warning(
                            "Codex cost catch-up stopped because a bounded pass made no progress")
                        return
                    }
                    status = nextStatus
                } catch is CancellationError {
                    return
                } catch {
                    self.publishCodexCostCatchUpActivity(
                        status: status,
                        context: context,
                        phase: .paused,
                        pauseReason: .error(error.localizedDescription))
                    CodexBarLog.logger(LogCategories.tokenCost).warning(
                        "Codex cost catch-up stopped after error: \(error.localizedDescription)")
                    return
                }
            }

            guard self.codexCostCatchUpContextIsCurrent(context) else { return }
            guard didAdvance else {
                self.publishCodexCostCatchUpActivity(
                    status: status,
                    context: context,
                    phase: .complete)
                return
            }
            do {
                status = try await self.publishStableCodexCostCatchUpSnapshot(context: context)
                guard status.pending else { return }
            } catch is CancellationError {
                return
            } catch {
                self.publishCodexCostCatchUpActivity(
                    status: status,
                    context: context,
                    phase: .paused,
                    pauseReason: .error(error.localizedDescription))
                CodexBarLog.logger(LogCategories.tokenCost).warning(
                    "Codex cost catch-up final snapshot failed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func publishStableCodexCostCatchUpSnapshot(
        context: CodexCostCatchUpContext) async throws -> CostUsageFetcher.CodexScanCatchUpStatus
    {
        let now = Date()
        // Provider-specific by design: Codex owns resumable cost catch-up and this guarded completed-cache publication.
        let publicationRevision = self.tokenSnapshotPublicationRevision(for: .codex)
        let result = await self.loadCompletedCodexCostCatchUpSnapshot(
            now: now,
            context: context)
        try Task.checkCancellation()
        guard self.codexCostCatchUpContextIsCurrent(context),
              self.tokenSnapshotPublicationRevision(for: .codex) == publicationRevision
        else {
            throw CancellationError()
        }
        guard let result,
              result.snapshot.historyCoverageIsEstablished,
              result.staleSnapshotUpdatedAt == nil
        else { throw CodexCostCatchUpPublicationError.completedHistoryUnavailable }
        let snapshot = result.snapshot

        if let lastRefreshAt = result.lastRefreshAt {
            self.lastTokenFetchAt[.codex] = lastRefreshAt
            self.lastTokenFetchScope[.codex] = context.scopeSignature
        }
        if snapshot.daily.isEmpty, snapshot.meteredCostUSD == nil {
            self.publishConfirmedEmptyTokenSnapshot(for: .codex)
            self.tokenErrors[.codex] = Self.tokenCostNoDataMessage(for: .codex)
        } else {
            self.publishTokenSnapshot(snapshot, for: .codex)
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

    private func loadCompletedCodexCostCatchUpSnapshot(
        now: Date,
        context: CodexCostCatchUpContext) async -> (
        snapshot: CostUsageTokenSnapshot,
        lastRefreshAt: Date?,
        staleSnapshotUpdatedAt: Date?)?
    {
        if let override = self._test_cachedCodexTokenSnapshotLoaderOverride {
            return await override(now, context.codexHomePath, context.historyDays)
        }
        return await self.costUsageFetcher.loadCompletedCodexTokenSnapshotResult(
            now: now,
            codexHomePath: context.codexHomePath,
            historyDays: context.historyDays,
            calendar: self.settings.costUsageBucketCalendar)
            .map { ($0.snapshot, $0.lastRefreshAt, $0.staleSnapshotUpdatedAt) }
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
            calendar: self.settings.costUsageBucketCalendar)
    }

    private func advanceCodexCostCatchUp(
        now: Date,
        codexHomePath: String?,
        historyDays: Int) async throws -> CostUsageFetcher.CodexScanCatchUpStatus
    {
        if let override = self._test_codexCostCatchUpAdvanceOverride {
            return try await override(now, codexHomePath, historyDays)
        }
        return try await self.costUsageFetcher.advanceCodexScanCatchUp(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            calendar: self.settings.costUsageBucketCalendar)
    }

    private func codexCostCatchUpDecision(
        mode: CodexCostCatchUpMode,
        previousActiveDuration: TimeInterval?) -> CodexCostCatchUpPolicy.Decision
    {
        let resourceState = self._test_codexCostCatchUpResourceStateOverride?() ?? (
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

    private func sleepBetweenCodexCostCatchUpPasses(seconds: TimeInterval) async throws {
        if let override = self._test_codexCostCatchUpSleepOverride {
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
