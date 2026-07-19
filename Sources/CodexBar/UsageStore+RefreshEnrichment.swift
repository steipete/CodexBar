import CodexBarCore
import Foundation

extension UsageStore {
    enum RefreshEnrichmentMode: Equatable, Sendable {
        case automatic
        case forcedForeground
        case forcedBackground
    }

    struct RequiredRefreshRequest: Sendable {
        var throughGeneration: UInt64
        var startupConnectivityRetryAttempt: Int?
        var coalesceProviderRefreshes: Bool
        var interaction: ProviderInteraction

        mutating func merge(_ newer: Self) {
            self.throughGeneration = max(self.throughGeneration, newer.throughGeneration)
            if let newerAttempt = newer.startupConnectivityRetryAttempt {
                self.startupConnectivityRetryAttempt = max(
                    self.startupConnectivityRetryAttempt ?? newerAttempt,
                    newerAttempt)
            }
            // Replacement is the stronger policy: a settings change must not join work started
            // with the old configuration merely because another required refresh arrived first.
            self.coalesceProviderRefreshes = self.coalesceProviderRefreshes && newer.coalesceProviderRefreshes
            if newer.interaction == .userInitiated {
                self.interaction = .userInitiated
            }
        }
    }

    func refresh(forceTokenUsage: Bool = false) async {
        if forceTokenUsage {
            await self.refresh(enrichmentMode: .forcedForeground)
        } else {
            await self.runRefresh(
                startupConnectivityRetryAttempt: nil,
                waitForRefreshAvailability: true)
        }
    }

    private struct ForcedRefreshEnrichmentRequest: Sendable {
        let generation: UInt64
        let refreshStartedAt: Date
        let openAIWebRefreshPhase: ProviderRefreshPhase
    }

    func refresh(enrichmentMode: RefreshEnrichmentMode) async {
        if enrichmentMode == .forcedForeground {
            await self.cancelForcedRefreshEnrichmentAndWait()
        }
        await self.runRefresh(
            enrichmentMode: enrichmentMode,
            startupConnectivityRetryAttempt: nil)
    }

    func enqueueRequiredRefresh(
        startupConnectivityRetryAttempt: Int?,
        coalesceProviderRefreshesOverride: Bool?) async -> Bool
    {
        self.requiredRefreshRequestGeneration &+= 1
        let interaction = ProviderInteractionContext.current
        let request = RequiredRefreshRequest(
            throughGeneration: self.requiredRefreshRequestGeneration,
            startupConnectivityRetryAttempt: startupConnectivityRetryAttempt,
            coalesceProviderRefreshes: coalesceProviderRefreshesOverride ?? (interaction == .background),
            interaction: interaction)
        if var pending = self.pendingRequiredRefreshRequest {
            pending.merge(request)
            self.pendingRequiredRefreshRequest = pending
        } else {
            self.pendingRequiredRefreshRequest = request
        }

        if let task = self.requiredRefreshTask {
            return await task.value
        }

        let token = UUID()
        self.requiredRefreshTaskToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let didRefresh = await self.drainRequiredRefreshRequests()
            self.completeRequiredRefreshTask(token: token)
            return didRefresh
        }
        self.requiredRefreshTask = task
        return await task.value
    }

    func cancelRequiredRefresh() {
        self.pendingRequiredRefreshRequest = nil
        self.requiredRefreshTaskToken = nil
        let task = self.requiredRefreshTask
        self.requiredRefreshTask = nil
        task?.cancel()
    }

    private func drainRequiredRefreshRequests() async -> Bool {
        var completedAnyRefresh = false
        while !Task.isCancelled {
            guard await self.waitForRequiredRefreshAvailability(),
                  let request = self.pendingRequiredRefreshRequest
            else {
                break
            }
            self.pendingRequiredRefreshRequest = nil

            let didRefresh = await ProviderInteractionContext.$current.withValue(request.interaction) {
                await self.runRefresh(
                    startupConnectivityRetryAttempt: request.startupConnectivityRetryAttempt,
                    coalesceProviderRefreshesOverride: request.coalesceProviderRefreshes)
            }
            if didRefresh {
                completedAnyRefresh = true
                self.requiredRefreshCompletedGeneration = max(
                    self.requiredRefreshCompletedGeneration,
                    request.throughGeneration)
            } else if !Task.isCancelled {
                var retry = request
                if let pending = self.pendingRequiredRefreshRequest {
                    retry.merge(pending)
                }
                self.pendingRequiredRefreshRequest = retry
            }
        }
        return completedAnyRefresh
    }

    private func waitForRequiredRefreshAvailability() async -> Bool {
        while self.isRefreshing || self.hasForcedRefreshEnrichmentInFlight {
            guard !Task.isCancelled else { return false }
            if self.hasForcedRefreshEnrichmentInFlight {
                await self.awaitForcedRefreshEnrichment()
            } else {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return false
                }
            }
        }
        return !Task.isCancelled
    }

    private func completeRequiredRefreshTask(token: UUID) {
        guard self.requiredRefreshTaskToken == token else { return }
        self.requiredRefreshTask = nil
        self.requiredRefreshTaskToken = nil
    }

    func enqueueForcedRefreshEnrichment(
        generation: UInt64,
        refreshStartedAt: Date,
        openAIWebRefreshPhase: ProviderRefreshPhase)
    {
        let request = ForcedRefreshEnrichmentRequest(
            generation: generation,
            refreshStartedAt: refreshStartedAt,
            openAIWebRefreshPhase: openAIWebRefreshPhase)
        if let predecessor = self.forcedRefreshEnrichmentTask {
            self.replacePendingForcedRefreshEnrichment(request, predecessor: predecessor)
        } else {
            self.startForcedRefreshEnrichment(request)
        }
    }

    func awaitForcedRefreshEnrichment() async {
        var reportedWait = false
        while !Task.isCancelled {
            guard let task = self.pendingForcedRefreshEnrichmentTask ?? self.forcedRefreshEnrichmentTask else {
                return
            }
            if !reportedWait {
                self._test_forcedRefreshEnrichmentWaitObserver?()
                reportedWait = true
            }
            await task.value
        }
    }

    func cancelForcedRefreshEnrichment() {
        _ = self.cancelForcedRefreshEnrichmentTasks()
    }

    private func cancelForcedRefreshEnrichmentAndWait() async {
        let tasks = self.cancelForcedRefreshEnrichmentTasks()
        for task in tasks {
            await task.value
        }
    }

    private func startForcedRefreshEnrichment(_ request: ForcedRefreshEnrichmentRequest) {
        let token = UUID()
        self.forcedRefreshEnrichmentToken = token
        self.hasForcedRefreshEnrichmentInFlight = true
        self.forcedRefreshEnrichmentTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            await self.runForcedRefreshEnrichment(request)
            self.completeForcedRefreshEnrichment(token: token)
        }
    }

    private func replacePendingForcedRefreshEnrichment(
        _ request: ForcedRefreshEnrichmentRequest,
        predecessor: Task<Void, Never>)
    {
        self.pendingForcedRefreshEnrichmentTask?.cancel()
        let token = UUID()
        self.pendingForcedRefreshEnrichmentToken = token
        self.hasForcedRefreshEnrichmentInFlight = true
        self.pendingForcedRefreshEnrichmentTask = Task(priority: .utility) { @MainActor [weak self] in
            await predecessor.value
            guard !Task.isCancelled,
                  let self,
                  self.pendingForcedRefreshEnrichmentToken == token,
                  let promotedTask = self.pendingForcedRefreshEnrichmentTask
            else { return }

            self.pendingForcedRefreshEnrichmentTask = nil
            self.pendingForcedRefreshEnrichmentToken = nil
            self.forcedRefreshEnrichmentTask = promotedTask
            self.forcedRefreshEnrichmentToken = token
            await self.runForcedRefreshEnrichment(request)
            self.completeForcedRefreshEnrichment(token: token)
        }
    }

    private func completeForcedRefreshEnrichment(token: UUID) {
        guard self.forcedRefreshEnrichmentToken == token else { return }
        // Keep the completed predecessor installed until its latest pending waiter promotes itself.
        // This avoids an actor-reentrancy gap where a new request could otherwise start beside it.
        guard self.pendingForcedRefreshEnrichmentTask == nil else { return }
        self.forcedRefreshEnrichmentTask = nil
        self.forcedRefreshEnrichmentToken = nil
        self.hasForcedRefreshEnrichmentInFlight = false
    }

    private func cancelForcedRefreshEnrichmentTasks() -> [Task<Void, Never>] {
        let tasks = [
            self.forcedRefreshEnrichmentTask,
            self.pendingForcedRefreshEnrichmentTask,
            self.openAIDashboardBackgroundRefreshTask,
            self.openAIDashboardRefreshTask,
        ].compactMap(\.self)

        self.forcedRefreshEnrichmentTask = nil
        self.forcedRefreshEnrichmentToken = nil
        self.pendingForcedRefreshEnrichmentTask = nil
        self.pendingForcedRefreshEnrichmentToken = nil
        self.hasForcedRefreshEnrichmentInFlight = false
        tasks.forEach { $0.cancel() }
        self.invalidateOpenAIDashboardRefreshTask()
        return tasks
    }

    private func runForcedRefreshEnrichment(_ request: ForcedRefreshEnrichmentRequest) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.refreshCreditsNow(minimumSnapshotUpdatedAt: request.refreshStartedAt)
            }
            group.addTask {
                await self.refreshTokenUsageSequenceNow(force: true)
            }
        }
        guard !Task.isCancelled else { return }

        await self.refreshOpenAIWebAfterProviderRefresh(
            force: true,
            refreshPhase: request.openAIWebRefreshPhase)
        guard !Task.isCancelled else { return }

        if self.openAIDashboardRequiresLogin,
           request.generation == self.forcedRefreshEnrichmentGeneration
        {
            // Join a newer in-flight Codex request rather than replacing it. A newer accepted all-provider
            // pass owns reconciliation even before it can enqueue its tail, so recheck generation afterward.
            await self.refreshProvider(.codex, coalesceIfRefreshing: true)
            guard !Task.isCancelled else { return }
            if request.generation == self.forcedRefreshEnrichmentGeneration {
                await self.refreshCreditsNow(minimumSnapshotUpdatedAt: request.refreshStartedAt)
                guard !Task.isCancelled else { return }
            }
        }

        self.persistWidgetSnapshot(reason: "forced-refresh-enrichment")
    }

    func refreshOpenAIWebAfterProviderRefresh(
        force: Bool,
        refreshPhase: ProviderRefreshPhase) async
    {
        self.syncOpenAIWebState()
        let refreshPolicy = OpenAIWebRefreshPolicyContext(
            accessEnabled: self.isEnabled(.codex) &&
                self.settings.openAIWebAccessEnabled &&
                self.settings.codexCookieSource.isEnabled,
            batterySaverEnabled: self.settings.openAIWebBatterySaverEnabled,
            force: force,
            refreshPhase: refreshPhase)
        let shouldRefreshOpenAIWeb = Self.shouldRunOpenAIWebRefresh(refreshPolicy)
        self.openAIWebLogger.debug(
            "OpenAI web refresh gate",
            metadata: [
                "allowed": shouldRefreshOpenAIWeb ? "1" : "0",
                "accessEnabled": refreshPolicy.accessEnabled ? "1" : "0",
                "batterySaverEnabled": refreshPolicy.batterySaverEnabled ? "1" : "0",
                "force": refreshPolicy.force ? "1" : "0",
                "interaction": ProviderInteractionContext.current == .userInitiated ? "user" : "background",
                "phase": refreshPhase == .startup ? "startup" : "regular",
            ])
        guard shouldRefreshOpenAIWeb, !Task.isCancelled else { return }

        let codexDashboardGuard = self.freshCodexOpenAIWebRefreshGuard()
        if force {
            await self.refreshOpenAIDashboardIfNeeded(
                force: true,
                expectedGuard: codexDashboardGuard,
                bypassCoalescing: true)
        } else {
            self.scheduleOpenAIDashboardRefreshIfNeeded(expectedGuard: codexDashboardGuard)
        }
    }
}
