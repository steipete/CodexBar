import CodexBarCore
import Foundation

extension UsageStore {
    private enum TokenRefreshSequenceScope: Sendable {
        case all
        case provider(UsageProvider)
        case providers([UsageProvider])
    }

    func startTokenTimer() {
        self.tokenTimerTask?.cancel()
        guard let wait = self.tokenFetchTTL else { return }
        self.tokenTimerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(wait))
                } catch {
                    return
                }
                await self?.scheduleTokenRefresh()
            }
        }
    }

    func scheduleTokenRefresh() {
        guard self.tokenRefreshSequenceTask == nil, !self.hasForcedRefreshEnrichmentInFlight else { return }
        if self.startPendingTokenRefreshRetryIfPossible() {
            return
        }
        self.startTokenRefreshSequence(force: false, scope: .all)
    }

    func refreshTokenUsageSequenceNow(force: Bool) async {
        guard let task = await self.serializedTokenRefreshTask(force: force, scope: .all) else { return }
        await self.awaitTokenRefreshSequence(task)
    }

    func refreshTokenUsageNow(for provider: UsageProvider, force: Bool) async {
        if force,
           self.tokenRefreshSequenceTask != nil,
           let activeProvider = self.tokenRefreshSequenceProvider,
           activeProvider != provider
        {
            // A scoped user refresh can run beside unrelated scheduled work. The scheduled
            // sequence still owns the shared slot, so the timer cannot introduce a third pass.
            await self.refreshTokenUsage(provider, force: true)
            self.scheduleMemoryPressureRelief()
            return
        }
        guard let task = await self.serializedTokenRefreshTask(force: force, scope: .provider(provider)) else {
            return
        }
        await self.awaitTokenRefreshSequence(task)
    }

    private func serializedTokenRefreshTask(
        force: Bool,
        scope: TokenRefreshSequenceScope) async -> Task<Void, Never>?
    {
        if force {
            while let existing = self.tokenRefreshSequenceTask {
                existing.cancel()
                await existing.value
                guard !Task.isCancelled else { return nil }
            }
        } else if let existing = self.tokenRefreshSequenceTask {
            return existing
        }
        return self.startTokenRefreshSequence(force: force, scope: scope)
    }

    @discardableResult
    private func startTokenRefreshSequence(
        force: Bool,
        scope: TokenRefreshSequenceScope) -> Task<Void, Never>
    {
        let providers: [UsageProvider] = switch scope {
        case .all:
            self.enabledProvidersForBackgroundWork()
        case let .provider(provider):
            [provider]
        case let .providers(providers):
            providers
        }
        let token = UUID()
        self.tokenRefreshSequenceToken = token
        // Publish the first owner before installing the task. A scoped forced refresh can arrive
        // before the task gets its first MainActor turn and must not mistake this slot for unknown work.
        self.tokenRefreshSequenceProvider = providers.first
        let task = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshTokenUsageSequence(providers: providers, force: force)
            self.completeTokenRefreshSequence(token: token)
        }
        self.tokenRefreshSequenceTask = task
        return task
    }

    private func awaitTokenRefreshSequence(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func completeTokenRefreshSequence(token: UUID) {
        guard self.tokenRefreshSequenceToken == token else { return }
        self.tokenRefreshSequenceTask = nil
        self.tokenRefreshSequenceToken = nil
        self.tokenRefreshSequenceProvider = nil
        self.startPendingTokenRefreshRetryIfPossible()
    }

    func requestTokenRefreshAfterStaleCompletion(for provider: UsageProvider) {
        self.tokenRefreshRetryProviders.insert(provider)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.startPendingTokenRefreshRetryIfPossible()
        }
    }

    @discardableResult
    private func startPendingTokenRefreshRetryIfPossible() -> Bool {
        guard !self.tokenRefreshRetryProviders.isEmpty,
              self.tokenRefreshSequenceTask == nil,
              self.settings.costUsageEnabled || self.settings.codexLocalSessionCostLedgerEnabled
        else {
            return false
        }
        let providers = self.enabledProvidersForBackgroundWork().filter(self.tokenRefreshRetryProviders.contains)
        guard !providers.isEmpty else { return false }
        self.tokenRefreshRetryProviders.subtract(providers)
        // Retry only lanes whose prior completion was rejected. Disabled lanes remain pending
        // until re-enabled, while unrelated providers keep their valid TTL and avoid a second scan.
        self.startTokenRefreshSequence(force: true, scope: .providers(providers))
        return true
    }

    private func refreshTokenUsageSequence(providers: [UsageProvider], force: Bool) async {
        defer { self.tokenRefreshSequenceProvider = nil }
        for provider in providers {
            if Task.isCancelled {
                break
            }
            self.tokenRefreshSequenceProvider = provider
            await self.refreshTokenUsage(provider, force: force)
            self.tokenRefreshSequenceProvider = nil
        }
        self.scheduleMemoryPressureRelief()
    }

    #if DEBUG
    func scheduleTokenRefreshForTesting() {
        self.scheduleTokenRefresh()
    }
    #endif
}
