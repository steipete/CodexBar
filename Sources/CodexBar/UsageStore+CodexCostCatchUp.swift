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
            guard self.codexCostCatchUpMode != mode else { return }
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

    // This is an intentional async state machine: keeping cancellation, pause, retry, and
    // publication transitions together makes their ordering explicit.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func runCodexCostCatchUp(context: CodexCostCatchUpContext) async {
        while self.codexCostCatchUpContextIsCurrent(context) {
            var status = await self.loadCodexCostCatchUpStatus(codexHomePath: context.codexHomePath)
            status = status.requiringTransientRetry()
            self.publishCodexCostCatchUpActivity(
                status: status,
                context: context,
                phase: status.pending ? .indexing : .complete)
            var didAdvance = false
            var previousActiveDuration: TimeInterval?
            var transientNoProgressKey: String?
            var unavailableRefreshLockRetryCount = 0
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
                    let loadedStatus: CostUsageFetcher.CodexScanCatchUpStatus
                    do {
                        loadedStatus = try await self.advanceCodexCostCatchUp(
                            now: Date(),
                            codexHomePath: context.codexHomePath,
                            historyDays: context.historyDays)
                        self.codexCostCatchUpPassIsRunning = false
                    } catch {
                        self.codexCostCatchUpPassIsRunning = false
                        throw error
                    }
                    let nextStatus = loadedStatus.requiresTransientRetry
                        ? loadedStatus.requiringTransientRetry()
                        : loadedStatus
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
                    if nextStatus.refreshLockUnavailable {
                        if unavailableRefreshLockRetryCount >= 1 {
                            self.publishCodexCostCatchUpActivity(
                                status: nextStatus,
                                context: context,
                                phase: .paused,
                                pauseReason: .error(
                                    CostUsageFetcher.CodexScanCatchUpStatus
                                        .refreshLockUnavailableErrorMessage))
                            return
                        }
                        unavailableRefreshLockRetryCount += 1
                        transientNoProgressKey = nil
                        status = nextStatus
                        try await self.sleepBetweenCodexCostCatchUpPasses(seconds: 1)
                        continue
                    }
                    unavailableRefreshLockRetryCount = 0
                    if nextStatus.deferredByConcurrentWriter {
                        transientNoProgressKey = nil
                        status = nextStatus
                        try await self.sleepBetweenCodexCostCatchUpPasses(seconds: 1)
                        continue
                    }
                    if nextStatus.pending, nextStatus.progressKey == status.progressKey {
                        if transientNoProgressKey == nextStatus.progressKey {
                            self.publishCodexCostCatchUpActivity(
                                status: nextStatus,
                                context: context,
                                phase: .paused,
                                pauseReason: .noProgress)
                            CodexBarLog.logger(LogCategories.tokenCost).warning(
                                "Codex cost catch-up stopped because repeated bounded passes made no progress")
                            return
                        }
                        // A source can change while it is being parsed, or SQLite can be briefly
                        // unavailable after the JSON suffix was read. Both intentionally preserve
                        // the published cursor, so one unchanged pass is a retry signal rather than
                        // proof that catch-up is permanently stalled.
                        transientNoProgressKey = nextStatus.progressKey
                        status = nextStatus
                        try await self.sleepBetweenCodexCostCatchUpPasses(seconds: 1)
                        continue
                    }
                    transientNoProgressKey = nil
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
        let snapshot = try await self.loadTokenUsageSnapshot(
            provider: .codex,
            force: true,
            now: now,
            codexHomePath: context.codexHomePath,
            historyDays: context.historyDays)
        try Task.checkCancellation()
        guard self.codexCostCatchUpContextIsCurrent(context) else {
            throw CancellationError()
        }

        self.lastTokenFetchAt[.codex] = now
        self.lastTokenFetchScope[.codex] = context.scopeSignature
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
            .requiringTransientRetry()
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
        return await self.costUsageFetcher.codexScanCatchUpStatus(codexHomePath: codexHomePath)
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
            historyDays: historyDays)
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
