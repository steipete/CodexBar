import CodexBarCore
import Foundation

extension UsageStore {
    /// Force refresh Augment session (called from UI button)
    func forceRefreshAugmentSession() async {
        await self.performRuntimeAction(.forceSessionRefresh, for: .augment)
    }

    func refreshProvider(_ provider: UsageProvider, allowDisabled: Bool = false) async {
        guard let spec = self.providerSpecs[provider] else { return }

        if !spec.isEnabled(), !allowDisabled {
            self.refreshingProviders.remove(provider)
            await MainActor.run {
                self.snapshots.removeValue(forKey: provider)
                self.errors[provider] = nil
                self.lastSourceLabels.removeValue(forKey: provider)
                self.lastFetchAttempts.removeValue(forKey: provider)
                self.accountSnapshots.removeValue(forKey: provider)
                self.tokenSnapshots.removeValue(forKey: provider)
                self.tokenErrors[provider] = nil
                self.failureGates[provider]?.reset()
                self.tokenFailureGates[provider]?.reset()
                self.statuses.removeValue(forKey: provider)
                self.lastKnownSessionRemaining.removeValue(forKey: provider)
                self.lastKnownSessionWindowSource.removeValue(forKey: provider)
                self.lastTokenFetchAt.removeValue(forKey: provider)
                self.lastTokenCostSelectionIdentity.removeValue(forKey: provider)
            }
            return
        }

        self.refreshingProviders.insert(provider)
        defer { self.refreshingProviders.remove(provider) }

        let tokenAccounts = self.tokenAccounts(for: provider)
        if self.shouldFetchAllTokenAccounts(provider: provider, accounts: tokenAccounts) {
            await self.refreshTokenAccounts(provider: provider, accounts: tokenAccounts)
            await self.refreshTokenUsageIfConfigured(provider)
            return
        } else {
            _ = await MainActor.run {
                self.accountSnapshots.removeValue(forKey: provider)
            }
        }

        // When "CodexBar accounts only" is on, do not fall back to ~/.codex implicit credentials.
        // If there are no explicit accounts, clear all cached Codex data and stop.
        if provider == .codex,
           self.settings.codexExplicitAccountsOnly,
           tokenAccounts.isEmpty
        {
            await MainActor.run {
                self.snapshots.removeValue(forKey: .codex)
                self.errors[.codex] = nil
                self.lastSourceLabels.removeValue(forKey: .codex)
                self.lastFetchAttempts.removeValue(forKey: .codex)
                self.accountSnapshots.removeValue(forKey: .codex)
                self.tokenSnapshots.removeValue(forKey: .codex)
                self.tokenErrors[.codex] = nil
                self.allAccountCredits.removeValue(forKey: .codex)
                self.credits = nil
                self.lastCreditsError = nil
                self.statuses.removeValue(forKey: .codex)
                self.lastKnownSessionRemaining.removeValue(forKey: .codex)
                self.lastKnownSessionWindowSource.removeValue(forKey: .codex)
                self.lastTokenFetchAt.removeValue(forKey: .codex)
                self.lastTokenCostSelectionIdentity.removeValue(forKey: .codex)
                self.failureGates[.codex]?.reset()
                self.tokenFailureGates[.codex]?.reset()
            }
            self.resetOpenAIWebState()
            return
        }

        let fetchContext = spec.makeFetchContext()
        let descriptor = spec.descriptor
        // Keep provider fetch work off MainActor so slow keychain/process reads don't stall menu/UI responsiveness.
        let outcome = await withTaskGroup(
            of: ProviderFetchOutcome.self,
            returning: ProviderFetchOutcome.self)
        { group in
            group.addTask {
                await descriptor.fetchOutcome(context: fetchContext)
            }
            return await group.next()!
        }
        if provider == .claude,
           ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
        {
            await MainActor.run {
                self.snapshots.removeValue(forKey: .claude)
                self.errors[.claude] = nil
                self.lastSourceLabels.removeValue(forKey: .claude)
                self.lastFetchAttempts.removeValue(forKey: .claude)
                self.accountSnapshots.removeValue(forKey: .claude)
                self.tokenSnapshots.removeValue(forKey: .claude)
                self.tokenErrors[.claude] = nil
                self.failureGates[.claude]?.reset()
                self.tokenFailureGates[.claude]?.reset()
                self.lastTokenFetchAt.removeValue(forKey: .claude)
                self.lastTokenCostSelectionIdentity.removeValue(forKey: .claude)
            }
        }
        await MainActor.run {
            self.lastFetchAttempts[provider] = outcome.attempts
        }

        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            await MainActor.run {
                self.handleSessionQuotaTransition(provider: provider, snapshot: scoped)
                self.snapshots[provider] = scoped
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
            }
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: scoped)
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(
                    provider: provider, settings: self.settings, store: self)
                runtime.providerDidRefresh(context: context, provider: provider)
            }
            if provider == .codex {
                self.recordCodexHistoricalSampleIfNeeded(snapshot: scoped)
                Task { await self.refreshAllAccountCredits(for: .codex) }
            }
        case let .failure(error):
            await MainActor.run {
                let hadPriorData = self.snapshots[provider] != nil
                let shouldSurface =
                    self.failureGates[provider]?
                        .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
                if shouldSurface {
                    self.errors[provider] = error.localizedDescription
                    self.snapshots.removeValue(forKey: provider)
                } else {
                    self.errors[provider] = nil
                }
            }
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(
                    provider: provider, settings: self.settings, store: self)
                runtime.providerDidFail(context: context, provider: provider, error: error)
            }
        }

        await self.refreshTokenUsageIfConfigured(provider)
    }

    /// Local token/cost scan from session logs — must run after account switches, not only on full `refresh()`.
    private func refreshTokenUsageIfConfigured(_ provider: UsageProvider) async {
        guard provider == .codex || provider == .claude || provider == .vertexai else { return }
        guard self.settings.costUsageEnabled else { return }
        await self.refreshTokenUsage(provider, force: false)
    }
}
