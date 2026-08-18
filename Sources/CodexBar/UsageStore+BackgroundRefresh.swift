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
        self.providerRefreshCoordinator.invalidateRequests(for: provider.instanceID)
    }

    /// The active refresh uses this when it discovers its own provider is disabled. Its replacing
    /// request already invalidated predecessors, so canceling the current coordinator state here
    /// would make it cancel itself before its waiters can drain.
    func clearProviderRuntimeState(_ provider: UsageProvider) {
        self.providerCleanupRevisions[provider.instanceID, default: 0] &+= 1
        self.refreshingProviders.remove(provider.instanceID)
        self.snapshots.removeValue(forKey: provider.instanceID)
        self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
        self.errors[provider.instanceID] = nil
        self.diagnostics[provider.instanceID] = nil
        // Provider-specific by design: disabling clears each provider's app-owned transient account/session state.
        if provider == .deepseek {
            self.clearDeepSeekProfileTransition()
        }
        if provider == .gemini {
            self.clearGeminiConsumerTierDeprecationObservation()
        }
        self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
        self.lastSourceLabels.removeValue(forKey: provider.instanceID)
        self.lastFetchAttempts.removeValue(forKey: provider.instanceID)
        self.accountSnapshots.removeValue(forKey: provider.instanceID)
        self.tokenAccountLiveStateProviders.remove(provider.instanceID)
        if provider == .codex {
            self.codexAccountSnapshots = []
            self.lastCodexUsagePublicationGuard = nil
        }
        if provider == .kilo {
            self.kiloScopeSnapshots = []
        }
        if provider == .claude {
            self.widgetUsagePreservationBlockedProviders.insert(provider.instanceID)
            self.clearClaudeSwapAccountState()
        }
        self.clearTokenSnapshot(for: provider)
        self.clearSpendDashboardTokenSnapshot(for: provider)
        self.tokenErrors[provider.instanceID] = nil
        self.providerStorageFootprints.removeValue(forKey: provider.instanceID)
        self.failureGates[provider.instanceID]?.reset()
        self.tokenFailureGates[provider.instanceID]?.reset()
        self.statuses.removeValue(forKey: provider.instanceID)
        self.statusComponents.removeValue(forKey: provider.instanceID)
        self.clearSessionQuotaTransitionState(provider: provider)
        self.predictivePaceWarningNotifiedKeys = Set(
            self.predictivePaceWarningNotifiedKeys.filter { $0.provider != provider })
        self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider }
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
    }

    func providerCleanupRevision(for provider: UsageProvider) -> UInt64 {
        self.providerCleanupRevisions[provider.instanceID, default: 0]
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

    func clearDisabledProviderState(enabledProviders: Set<ProviderInstanceID>) {
        for provider in UsageProvider.allCases where !enabledProviders.contains(provider.instanceID) {
            if self.currentProviderRefreshAllowsDisabledPublication(provider) {
                self.clearProviderRuntimeState(provider)
            } else {
                self.clearProviderState(provider)
            }
        }
        let dynamicIDs = Set(self.snapshots.keys).union(self.errors.keys).filter { $0.firstPartyProvider == nil }
        for instanceID in dynamicIDs where !enabledProviders.contains(instanceID) {
            self.snapshots.removeValue(forKey: instanceID)
            self.errors.removeValue(forKey: instanceID)
            self.lastSourceLabels.removeValue(forKey: instanceID)
        }
    }

    func clearUnavailableProviderState(
        displayEnabledProviders: Set<ProviderInstanceID>,
        availableProviders: Set<ProviderInstanceID>)
    {
        for instanceID in displayEnabledProviders where !availableProviders.contains(instanceID) {
            guard let provider = instanceID.firstPartyProvider else { continue }
            self.clearProviderState(provider)
        }
    }
}
