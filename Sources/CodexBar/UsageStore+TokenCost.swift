import CodexBarCore
import Foundation

extension UsageStore {
    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        self.tokenSnapshots[provider]
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider)
    }

    func isTokenRefreshQueued(for provider: UsageProvider) -> Bool {
        self.tokenRefreshQueuedProviders.contains(provider)
    }

    func tokenCostScope(for provider: UsageProvider) -> (codexHomePath: String?, signature: String) {
        guard provider == .codex else {
            return (nil, provider.rawValue)
        }
        let homePath = self.settings.activeManagedCodexRemoteHomePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let homePath, !homePath.isEmpty else {
            return (nil, "codex:ambient")
        }
        return (homePath, "codex:managed:\(homePath)")
    }

    func tokenSnapshot(
        fromProviderSnapshot snapshot: UsageSnapshot?,
        provider: UsageProvider)
        -> CostUsageTokenSnapshot?
    {
        switch provider {
        case .openai:
            snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .mistral:
            snapshot?.mistralUsage?.toCostUsageTokenSnapshot(historyDays: self.settings.costUsageHistoryDays)
        default:
            nil
        }
    }

    nonisolated static func tokenCostRequiresProviderSnapshot(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .mistral, .openai:
            true
        default:
            false
        }
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage()
    }

    func ensureTokenCostSnapshotScheduled(for provider: UsageProvider, reason: String) {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else { return }
        guard self.settings.isCostUsageEffectivelyEnabled(for: provider) else { return }
        guard !Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        guard self.isEnabled(provider) else { return }
        guard self.tokenSnapshots[provider] == nil else { return }
        guard self.tokenErrors[provider] == nil else { return }
        guard !self.tokenRefreshQueuedProviders.contains(provider) else { return }
        guard !self.tokenRefreshInFlight.contains(provider) else { return }

        if !self.hydrateCachedTokenCostSnapshotIfNeeded(for: provider, reason: reason) {
            self.scheduleTokenRefresh(
                force: false,
                providers: [provider],
                allowDuringMenuInteraction: true,
                reason: reason)
        }
    }

    func shouldRunTokenCostRefreshDuringMenuInteraction(_ provider: UsageProvider) -> Bool {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else { return false }
        guard self.settings.isCostUsageEffectivelyEnabled(for: provider) else { return false }
        guard !Self.tokenCostRequiresProviderSnapshot(provider) else { return false }
        guard self.isEnabled(provider) else { return false }
        return self.tokenSnapshots[provider] == nil && self.tokenErrors[provider] == nil
    }

    @discardableResult
    private func hydrateCachedTokenCostSnapshotIfNeeded(for provider: UsageProvider, reason: String) -> Bool {
        guard self.tokenCacheHydrationTasks[provider] == nil else { return true }
        let now = Date()
        if let lastAttempt = self.lastTokenCacheHydrationAttemptAt[provider],
           now.timeIntervalSince(lastAttempt) < self.tokenCacheHydrationRetryInterval
        {
            return false
        }
        self.lastTokenCacheHydrationAttemptAt[provider] = now
        self.tokenRefreshQueuedProviders.insert(provider)

        let fetcher = self.costUsageFetcher
        let environment = self.environmentBase
        let historyDays = self.settings.costUsageHistoryDays
        let costScope = self.tokenCostScope(for: provider)
        let allowVertexClaudeFallback = !self.isEnabled(.claude)
        let override = self._test_cachedTokenUsageLoadOverride
        self.tokenCacheHydrationTasks[provider] = Task(priority: .utility) { @MainActor [weak self] in
            let snapshot: CostUsageTokenSnapshot? = if let override {
                await override(provider)
            } else {
                await Task.detached(priority: .utility) {
                    fetcher.loadCachedTokenSnapshot(
                        provider: provider,
                        environment: environment,
                        now: now,
                        allowVertexClaudeFallback: allowVertexClaudeFallback,
                        codexHomePath: costScope.codexHomePath,
                        historyDays: historyDays)
                }.value
            }

            guard let self else { return }
            self.tokenCacheHydrationTasks[provider] = nil
            if Task.isCancelled {
                self.tokenRefreshQueuedProviders.remove(provider)
                return
            }
            guard let snapshot, !snapshot.daily.isEmpty else {
                self.scheduleTokenRefresh(
                    force: false,
                    providers: [provider],
                    allowDuringMenuInteraction: true,
                    reason: "\(reason)-cache-miss")
                return
            }
            self.tokenRefreshQueuedProviders.remove(provider)
            guard self.tokenSnapshots[provider] == nil else { return }
            self.tokenCostLogger.debug(
                "cost usage hydrated cached snapshot provider=\(provider.rawValue) reason=\(reason)")
            self.tokenSnapshots[provider] = snapshot
            self.tokenErrors[provider] = nil
            self.tokenFailureGates[provider]?.recordSuccess()
            self.scheduleTokenRefresh(
                force: false,
                providers: [provider],
                reason: "\(reason)-revalidate")
        }
        return true
    }
}
