import CodexBarCore
import Foundation

extension UsageStore {
    func prepareRefreshState(for provider: UsageProvider? = nil) {
        guard provider == nil || provider == .codex else { return }
        _ = self.settings.persistResolvedCodexActiveSourceCorrectionIfNeeded()
    }

    /// Force refresh Augment session (called from UI button)
    func forceRefreshAugmentSession() async {
        await self.performRuntimeAction(.forceSessionRefresh, for: .augment)
    }

    func refreshProvider(_ provider: UsageProvider, allowDisabled: Bool = false) async {
        self.prepareRefreshState(for: provider)
        guard let spec = self.providerSpecs[provider] else { return }
        let codexExpectedGuard = provider == .codex ? self.currentCodexAccountScopedRefreshGuard() : nil

        if !spec.isEnabled(), !allowDisabled {
            self.refreshingProviders.remove(provider)
            await MainActor.run {
                self.snapshots.removeValue(forKey: provider)
                self.lastKnownResetSnapshots.removeValue(forKey: provider)
                self.errors[provider] = nil
                self.lastSourceLabels.removeValue(forKey: provider)
                self.lastFetchAttempts.removeValue(forKey: provider)
                self.accountSnapshots.removeValue(forKey: provider)
                if provider == .codex {
                    self.codexAccountSnapshots = []
                }
                self.tokenSnapshots.removeValue(forKey: provider)
                self.tokenErrors[provider] = nil
                self.failureGates[provider]?.reset()
                self.tokenFailureGates[provider]?.reset()
                self.statuses.removeValue(forKey: provider)
                self.lastKnownSessionRemaining.removeValue(forKey: provider)
                self.lastKnownSessionWindowSource.removeValue(forKey: provider)
                self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider }
                self.lastTokenFetchAt.removeValue(forKey: provider)
            }
            return
        }

        self.refreshingProviders.insert(provider)
        defer { self.refreshingProviders.remove(provider) }

        if provider == .codex, self.shouldFetchAllCodexVisibleAccounts() {
            await self.refreshCodexVisibleAccountsForMenu()
            return
        } else if provider == .codex {
            self.codexAccountSnapshots = []
        }

        let tokenAccounts = self.tokenAccounts(for: provider)
        if self.shouldFetchAllTokenAccounts(provider: provider, accounts: tokenAccounts) {
            await self.refreshTokenAccounts(provider: provider, accounts: tokenAccounts)
            return
        } else {
            _ = await MainActor.run {
                self.accountSnapshots.removeValue(forKey: provider)
            }
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
                self.lastKnownResetSnapshots.removeValue(forKey: .claude)
                self.errors[.claude] = nil
                self.lastSourceLabels.removeValue(forKey: .claude)
                self.lastFetchAttempts.removeValue(forKey: .claude)
                self.accountSnapshots.removeValue(forKey: .claude)
                self.tokenSnapshots.removeValue(forKey: .claude)
                self.tokenErrors[.claude] = nil
                self.failureGates[.claude]?.reset()
                self.tokenFailureGates[.claude]?.reset()
                self.lastTokenFetchAt.removeValue(forKey: .claude)
            }
        }
        await MainActor.run {
            self.lastFetchAttempts[provider] = outcome.attempts
        }

        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            if provider == .codex,
               let codexExpectedGuard,
               !self.shouldApplyCodexUsageResult(expectedGuard: codexExpectedGuard, usage: scoped)
            {
                return
            }
            let backfilled = await MainActor.run {
                let backfilled = scoped.backfillingResetTimes(from: self.lastKnownResetSnapshots[provider])
                self.handleQuotaWarningTransitions(provider: provider, snapshot: backfilled)
                self.handleSessionQuotaTransition(provider: provider, snapshot: backfilled)
                self.lastKnownResetSnapshots[provider] = backfilled
                self.snapshots[provider] = backfilled
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
                if provider == .codex {
                    self.rememberLiveSystemCodexEmailIfNeeded(scoped.accountEmail(for: .codex))
                    self.seedCodexAccountScopedRefreshGuard(accountEmail: scoped.accountEmail(for: .codex))
                }
                return backfilled
            }
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: backfilled)
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(
                    provider: provider, settings: self.settings, store: self)
                runtime.providerDidRefresh(context: context, provider: provider)
            }
            if provider == .codex {
                self.recordCodexHistoricalSampleIfNeeded(snapshot: backfilled)
            }
        case let .failure(error):
            if provider == .codex,
               let codexExpectedGuard,
               !self.shouldApplyCodexScopedFailure(expectedGuard: codexExpectedGuard)
            {
                return
            }
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
    }
}
