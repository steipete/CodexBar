import CodexBarCore
import Foundation

extension UsageStore {
    func scheduleTokenRefresh(
        force: Bool,
        providers: [UsageProvider]? = nil,
        allowDuringMenuInteraction: Bool = false,
        reason: String = "scheduled-refresh")
    {
        let refreshProviders = providers ?? self.enabledProvidersForBackgroundWork()
        guard !refreshProviders.isEmpty else { return }
        if !allowDuringMenuInteraction,
           self
               .shouldDeferTokenRefreshForMenuInteraction(reason: force ? "forced-scheduled-refresh" : reason)
        {
            if force {
                self.tokenCostDeferredForceRefreshPending = true
            } else {
                self.tokenCostDeferredRefreshPending = true
            }
            return
        }

        self.tokenRefreshQueuedProviders.formUnion(refreshProviders)
        if allowDuringMenuInteraction {
            self.tokenRefreshMenuAllowedProviders.formUnion(refreshProviders)
        }
        if force {
            self.tokenRefreshSequenceTask?.cancel()
            self.tokenRefreshSequenceTask = nil
        } else if self.tokenRefreshSequenceTask != nil {
            self.pendingTokenRefreshProviders.formUnion(refreshProviders)
            self.pendingTokenRefreshAllowsMenuInteraction =
                self.pendingTokenRefreshAllowsMenuInteraction || allowDuringMenuInteraction
            return
        }

        self.tokenRefreshSequenceTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.tokenRefreshSequenceTask = nil
                }
            }
            await self.refreshTokenUsageSequenceWorker(
                force: force,
                providers: refreshProviders,
                allowDuringMenuInteraction: allowDuringMenuInteraction)
        }
    }

    func refreshTokenUsageSequenceNow(force: Bool) async {
        if force, let existing = self.tokenRefreshSequenceTask {
            existing.cancel()
            await existing.value
            self.tokenRefreshSequenceTask = nil
        }

        await self.refreshTokenUsageSequence(force: force, providers: self.enabledProvidersForBackgroundWork())
    }

    private func refreshTokenUsageSequenceWorker(
        force: Bool,
        providers: [UsageProvider],
        allowDuringMenuInteraction: Bool) async
    {
        var nextProviders = providers
        var nextAllowsMenuInteraction = allowDuringMenuInteraction
        var nextForce = force
        defer {
            if Task.isCancelled {
                self.tokenRefreshQueuedProviders.subtract(nextProviders)
                self.tokenRefreshQueuedProviders.subtract(self.pendingTokenRefreshProviders)
                self.tokenRefreshMenuAllowedProviders.subtract(nextProviders)
                self.tokenRefreshMenuAllowedProviders.subtract(self.pendingTokenRefreshProviders)
                self.pendingTokenRefreshProviders = []
                self.pendingTokenRefreshAllowsMenuInteraction = false
            }
        }

        while !Task.isCancelled {
            await self.refreshTokenUsageSequence(
                force: nextForce,
                providers: nextProviders,
                allowDuringMenuInteraction: nextAllowsMenuInteraction)
            guard !Task.isCancelled else { break }
            guard !self.pendingTokenRefreshProviders.isEmpty else { break }

            nextProviders = Array(self.pendingTokenRefreshProviders)
            nextAllowsMenuInteraction = self.pendingTokenRefreshAllowsMenuInteraction
            nextForce = false
            self.pendingTokenRefreshProviders = []
            self.pendingTokenRefreshAllowsMenuInteraction = false
        }
    }

    private func refreshTokenUsageSequence(
        force: Bool,
        providers: [UsageProvider],
        allowDuringMenuInteraction: Bool = false) async
    {
        for provider in providers {
            if Task.isCancelled { break }
            if !force,
               !allowDuringMenuInteraction,
               !self.shouldRunTokenCostRefreshDuringMenuInteraction(provider),
               self.shouldDeferScheduledTokenRefresh(reason: "sequence-refresh")
            {
                break
            }
            await self.refreshTokenUsage(provider, force: force)
        }
    }
}
