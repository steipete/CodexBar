import Foundation

extension UsageStore {
    func beginInteractiveMenuTokenCostDeferral(reason: String) {
        self.tokenCostInteractiveDeferralDepth += 1
        self.tokenCostInteractiveDeferralGeneration &+= 1
        self.tokenCostDeferredUntil = nil
        self.tokenRefreshResumeTask?.cancel()
        self.tokenRefreshResumeTask = nil
        self.cancelScheduledTokenRefreshForMenuInteraction(reason: reason)
    }

    func endInteractiveMenuTokenCostDeferral(reason: String) {
        guard self.tokenCostInteractiveDeferralDepth > 0 else { return }
        self.tokenCostInteractiveDeferralDepth -= 1
        self.tokenCostInteractiveDeferralGeneration &+= 1
        guard self.tokenCostInteractiveDeferralDepth == 0 else { return }

        let delay = max(0, self.tokenCostInteractionResumeDelay)
        self.tokenCostDeferredUntil = Date().addingTimeInterval(delay)
        self.scheduleTokenRefreshResumeAfterInteraction(reason: reason, delay: delay)
    }

    func deferRefreshDuringMenuInteractionIfNeeded(forceTokenUsage: Bool) -> Bool {
        if self.tokenCostInteractiveDeferralDepth > 0 {
            self.refreshDeferredDuringMenuInteraction = true
            self.refreshDeferredForceTokenUsage = self.refreshDeferredForceTokenUsage || forceTokenUsage
            self.tokenCostLogger.debug(
                "store refresh deferred for menu interaction " +
                    "activeMenuDepth=\(self.tokenCostInteractiveDeferralDepth) " +
                    "forceTokenUsage=\(forceTokenUsage)")
            return true
        }

        guard let deferredUntil = self.tokenCostDeferredUntil else { return false }

        let remaining = deferredUntil.timeIntervalSinceNow
        guard remaining > 0 else {
            self.tokenCostDeferredUntil = nil
            return false
        }

        self.refreshDeferredDuringMenuInteraction = true
        self.refreshDeferredForceTokenUsage = self.refreshDeferredForceTokenUsage || forceTokenUsage
        self.scheduleTokenRefreshResumeAfterInteraction(reason: "refresh-deferred-during-menu", delay: remaining)
        return true
    }

    func shouldDeferScheduledTokenRefresh(reason: String) -> Bool {
        self.shouldDeferTokenRefreshForMenuInteraction(reason: reason)
    }

    func shouldDeferTokenRefreshForMenuInteraction(reason: String) -> Bool {
        if self.tokenCostInteractiveDeferralDepth > 0 {
            self.tokenCostLogger
                .debug("cost usage deferred reason=\(reason) activeMenuDepth=\(self.tokenCostInteractiveDeferralDepth)")
            return true
        }

        guard let deferredUntil = self.tokenCostDeferredUntil else { return false }

        let remaining = deferredUntil.timeIntervalSinceNow
        guard remaining > 0 else {
            self.tokenCostDeferredUntil = nil
            return false
        }

        self.scheduleTokenRefreshResumeAfterInteraction(reason: reason, delay: remaining)
        return true
    }

    private func scheduleTokenRefreshResumeAfterInteraction(reason: String, delay: TimeInterval) {
        self.tokenRefreshResumeTask?.cancel()
        let generation = self.tokenCostInteractiveDeferralGeneration
        self.tokenRefreshResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.tokenCostInteractiveDeferralDepth == 0 else { return }
            guard self.tokenCostInteractiveDeferralGeneration == generation else { return }
            self.tokenCostDeferredUntil = nil
            self.tokenRefreshResumeTask = nil
            self.tokenCostLogger
                .debug("cost usage resuming after menu interaction reason=\(reason) delaySeconds=\(Int(delay))")
            let shouldRunRefresh = self.refreshDeferredDuringMenuInteraction
            let refreshForceTokenUsage = self.refreshDeferredForceTokenUsage
            let regularTokenRefresh = self.tokenCostDeferredRefreshPending
            let forceTokenRefresh = self.tokenCostDeferredForceRefreshPending
            self.refreshDeferredDuringMenuInteraction = false
            self.refreshDeferredForceTokenUsage = false
            self.tokenCostDeferredRefreshPending = false
            self.tokenCostDeferredForceRefreshPending = false

            if shouldRunRefresh {
                await self.refresh(forceTokenUsage: refreshForceTokenUsage)
                if forceTokenRefresh, !refreshForceTokenUsage {
                    self.scheduleTokenRefresh(force: true)
                } else if regularTokenRefresh, !refreshForceTokenUsage {
                    self.scheduleTokenRefresh(force: false)
                }
            } else if forceTokenRefresh {
                self.scheduleTokenRefresh(force: true)
            } else if regularTokenRefresh {
                self.scheduleTokenRefresh(force: false)
            } else {
                self.scheduleTokenRefresh(force: false)
            }
        }
    }

    private func cancelScheduledTokenRefreshForMenuInteraction(reason: String) {
        guard let task = self.tokenRefreshSequenceTask else { return }
        let protectedProviders = self.tokenRefreshMenuAllowedProviders
            .filter { self.shouldRunTokenCostRefreshDuringMenuInteraction($0) }
        let inFlightProviders = Set(self.tokenRefreshInFlightStartedAt.keys)
        let shouldKeepProtectedJob = !protectedProviders.isEmpty &&
            (inFlightProviders.isEmpty || !inFlightProviders.isDisjoint(with: protectedProviders))
        if shouldKeepProtectedJob {
            let providersText = protectedProviders.map(\.rawValue).sorted().joined(separator: ",")
            self.tokenCostLogger
                .debug("cost usage kept running during menu interaction reason=\(reason) providers=\(providersText)")
            return
        }

        let inFlightDetails = self.tokenRefreshInFlightStartedAt
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { provider, startedAt in
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                return "inFlightProvider=\(provider.rawValue) inFlightMs=\(elapsedMs)"
            }
            .joined(separator: " ")

        let suffix = inFlightDetails.isEmpty ? "inFlightProvider=none" : inFlightDetails
        self.tokenCostLogger
            .info("cost usage cancelled for menu interaction reason=\(reason) \(suffix)")
        task.cancel()
    }

    func clearCostUsageCache() async -> String? {
        let errorMessage: String? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cacheDirs = [
                Self.costUsageCacheDirectory(fileManager: fm),
            ]

            for cacheDir in cacheDirs {
                do {
                    try fm.removeItem(at: cacheDir)
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError { continue }
                    return error.localizedDescription
                }
            }
            return nil
        }.value

        guard errorMessage == nil else { return errorMessage }

        self.tokenSnapshots.removeAll()
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.lastTokenFetchScope.removeAll()
        self.tokenFailureGates[.codex]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        return nil
    }
}
