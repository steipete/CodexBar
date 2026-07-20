import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    struct ProviderPublicationRevision: Equatable {
        let cleanupRevision: UInt64
        let enablementRevision: UInt64
    }

    /// Invalidates in-flight provider work and clears its transient runtime/UI state.
    /// Settings, token-account configuration, historical datasets, credits/dashboard caches,
    /// and disk-backed Codex account snapshots intentionally remain owned by their existing lifetimes.
    func clearProviderState(_ provider: UsageProvider) {
        self.invalidateProviderRefreshRequests(provider)
        self.clearProviderRuntimeState(provider)
    }

    /// Cancels and retires in-flight work without clearing the provider's current presentation state.
    func invalidateProviderRefreshRequests(_ provider: UsageProvider) {
        self.providerRefreshCoordinator.invalidateRequests(for: provider)
    }

    /// The active refresh uses this when it discovers its own provider is disabled. Its replacing
    /// request already invalidated predecessors, so canceling the current coordinator state here
    /// would make it cancel itself before its waiters can drain.
    func clearProviderRuntimeState(_ provider: UsageProvider) {
        self.providerCleanupRevisions[provider, default: 0] &+= 1
        self.refreshingProviders.remove(provider)
        self.snapshots.removeValue(forKey: provider)
        self.lastKnownResetSnapshots.removeValue(forKey: provider)
        self.errors[provider] = nil
        self.diagnostics[provider] = nil
        if provider == .deepseek {
            self.clearDeepSeekProfileTransition()
        }
        if provider == .gemini {
            self.clearGeminiConsumerTierDeprecationObservation()
        }
        self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
        self.lastSourceLabels.removeValue(forKey: provider)
        self.lastFetchAttempts.removeValue(forKey: provider)
        self.accountSnapshots.removeValue(forKey: provider)
        self.tokenAccountLiveStateProviders.remove(provider)
        if provider == .codex {
            self.codexAccountSnapshots = []
            self.lastCodexUsagePublicationGuard = nil
        }
        if provider == .kilo {
            self.kiloScopeSnapshots = []
        }
        if provider == .claude {
            self.clearClaudeSwapAccountState()
        }
        self.clearTokenSnapshot(for: provider)
        self.tokenErrors[provider] = nil
        self.providerStorageFootprints.removeValue(forKey: provider)
        self.failureGates[provider]?.reset()
        self.tokenFailureGates[provider]?.reset()
        self.statuses.removeValue(forKey: provider)
        self.statusComponents.removeValue(forKey: provider)
        self.clearSessionQuotaTransitionState(provider: provider)
        self.predictivePaceWarningNotifiedKeys = Set(
            self.predictivePaceWarningNotifiedKeys.filter { $0.provider != provider })
        self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider }
        self.lastTokenFetchAt.removeValue(forKey: provider)
        self.lastTokenFetchScope.removeValue(forKey: provider)
    }

    func providerCleanupRevision(for provider: UsageProvider) -> UInt64 {
        self.providerCleanupRevisions[provider, default: 0]
    }

    func providerCleanupRevisionIsCurrent(_ revision: UInt64, for provider: UsageProvider) -> Bool {
        self.providerCleanupRevision(for: provider) == revision
    }

    func providerPublicationRevision(for provider: UsageProvider) -> ProviderPublicationRevision {
        ProviderPublicationRevision(
            cleanupRevision: self.providerCleanupRevision(for: provider),
            enablementRevision: self.settings.providerEnablementRevision(for: provider))
    }

    func providerPublicationRevisionIsCurrent(
        _ revision: ProviderPublicationRevision,
        for provider: UsageProvider) -> Bool
    {
        self.providerCleanupRevisionIsCurrent(revision.cleanupRevision, for: provider) &&
            revision.enablementRevision == self.settings.providerEnablementRevision(for: provider)
    }

    func clearDisabledProviderState(enabledProviders: Set<UsageProvider>) {
        for provider in UsageProvider.allCases where !enabledProviders.contains(provider) {
            if self.currentProviderRefreshAllowsDisabledPublication(provider) {
                self.clearProviderRuntimeState(provider)
            } else {
                self.clearProviderState(provider)
            }
        }
    }

    func clearUnavailableProviderState(
        displayEnabledProviders: Set<UsageProvider>,
        availableProviders: Set<UsageProvider>)
    {
        for provider in displayEnabledProviders where !availableProviders.contains(provider) {
            self.clearProviderState(provider)
        }
    }
}
