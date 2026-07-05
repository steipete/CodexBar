import CodexBarCore
import Foundation

extension UsageStore {
    private struct ProviderRefreshOutcomeContext {
        let generation: UInt64
        let codexExpectedGuard: CodexAccountScopedRefreshGuard?
        let claudeOAuthHistoryPersistentRefHash: String?
        let claudeOAuthActiveAccountObservation: ClaudeOAuthActiveAccountObservation
    }

    static func commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
        current: UsageSnapshot,
        previous: UsageSnapshot?) -> UsageSnapshot
    {
        let previousProvesPaidDepletion = previous?.commandCodeHasSubscriptionPlan == true ||
            (previous?.commandCodeSubscriptionEnrichmentUnavailable == true &&
                previous?.commandCodeMonthlyGrantDepleted == true &&
                previous?.primary?.usedPercent == 100)
        guard current.commandCodeSubscriptionEnrichmentUnavailable,
              current.commandCodeMonthlyGrantDepleted,
              previousProvesPaidDepletion,
              let previousPrimary = previous?.primary
        else {
            return current
        }
        let depleted = RateWindow(
            usedPercent: 100,
            windowMinutes: previousPrimary.windowMinutes,
            resetsAt: previousPrimary.resetsAt,
            resetDescription: previousPrimary.resetDescription)
        return current.with(primary: depleted, secondary: current.secondary)
    }

    func refreshForSettingsChange() async {
        await self.runRefresh(
            startupConnectivityRetryAttempt: nil,
            coalesceProviderRefreshesOverride: false)
    }

    func prepareRefreshState(for provider: UsageProvider? = nil) {
        guard provider == nil || provider == .codex else { return }
        _ = self.settings.persistResolvedCodexActiveSourceCorrectionIfNeeded()
    }

    /// Force refresh Augment session (called from UI button)
    func forceRefreshAugmentSession() async {
        await self.performRuntimeAction(.forceSessionRefresh, for: .augment)
    }

    private func providerRefreshSpec(_ provider: UsageProvider) async -> ProviderSpec? {
        if let override = self._test_providerRefreshOverride {
            await override(provider)
            return nil
        }
        return self.providerSpecs[provider]
    }

    func refreshProvider(
        _ provider: UsageProvider,
        allowDisabled: Bool = false,
        coalesceIfRefreshing: Bool = false) async
    {
        while coalesceIfRefreshing,
              let existingState = self.providerRefreshCoordinator.coalescingState(for: provider)
        {
            switch await self.providerRefreshCoordinator.wait(for: provider, state: existingState) {
            case .cancelled:
                return
            case .retryRequired:
                self.providerRefreshCoordinator.remove(existingState, for: provider)
                continue
            case .completed:
                return
            }
        }

        let request = self.providerRefreshCoordinator.beginReplacingRequest(for: provider)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshotUpdatedAtBeforeRefresh: Date?
            var didStartRefresh = false
            for predecessorState in request.predecessorStates {
                await predecessorState.waitForTaskCompletion()
            }
            if !Task.isCancelled, self.isCurrentProviderRefreshGeneration(provider, generation: request.generation) {
                snapshotUpdatedAtBeforeRefresh = self.snapshot(for: provider)?.updatedAt
                didStartRefresh = true
                await self.refreshProviderTracked(
                    provider,
                    allowDisabled: allowDisabled,
                    generation: request.generation)
            }
            let publishedNewSnapshot = didStartRefresh &&
                self.snapshot(for: provider)?.updatedAt != snapshotUpdatedAtBeforeRefresh
            let retryRequired = Task.isCancelled && !publishedNewSnapshot
            self.providerRefreshCoordinator.complete(
                request.state,
                for: provider,
                retryRequired: retryRequired)
        }
        request.state.install(task: task)
        _ = await self.providerRefreshCoordinator.wait(for: provider, state: request.state)
    }

    func isCurrentProviderRefreshGeneration(_ provider: UsageProvider, generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return self.providerRefreshCoordinator.isCurrent(generation, for: provider)
    }

    private func refreshProviderTracked(
        _ provider: UsageProvider,
        allowDisabled: Bool,
        generation: UInt64) async
    {
        if self.providerRefreshCoordinator.beginActivity(for: provider) {
            self.refreshingProviders.insert(provider)
        }
        defer {
            if self.providerRefreshCoordinator.endActivity(for: provider) {
                self.refreshingProviders.remove(provider)
            }
        }
        await self.refreshProviderNow(
            provider,
            allowDisabled: allowDisabled,
            generation: generation)
    }

    private func refreshProviderNow(
        _ provider: UsageProvider,
        allowDisabled: Bool,
        generation: UInt64) async
    {
        self.prepareRefreshState(for: provider)
        guard let spec = await self.providerRefreshSpec(provider) else { return }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        let codexExpectedGuard = provider == .codex ? self.freshCodexAccountScopedRefreshGuard() : nil

        if !spec.isEnabled(), !allowDisabled {
            await self.clearDisabledProviderRefreshState(provider)
            return
        }

        if provider == .codex, self.shouldFetchAllCodexVisibleAccounts() {
            await self.refreshCodexVisibleAccountsForMenu(generation: generation)
            return
        } else if provider == .codex {
            self.codexAccountSnapshots = []
        }

        if provider == .kilo, self.shouldFanOutKiloScopes() {
            await self.refreshKiloScopes(generation: generation)
            guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
            // Continue to also fetch the personal snapshot through the regular path
            // so the existing single-card render keeps working when only personal is shown.
            // The presence of multi-element kiloScopeSnapshots triggers stacked rendering.
        } else if provider == .kilo {
            await MainActor.run { self.kiloScopeSnapshots = [] }
        }

        if provider == .claude {
            self.scheduleClaudeSwapAccountRefresh(generation: generation)
        }

        let tokenAccounts = self.tokenAccounts(for: provider)
        if self.shouldFetchAllTokenAccounts(provider: provider, accounts: tokenAccounts) {
            await self.refreshTokenAccounts(
                provider: provider,
                accounts: tokenAccounts,
                generation: generation)
            return
        } else {
            _ = await MainActor.run {
                self.accountSnapshots.removeValue(forKey: provider)
            }
        }

        let claudeAuthStateBeforeFetch = provider == .claude
            ? await Self.captureClaudeRefreshAuthState(invalidateCredentialsFile: true)
            : nil
        let fetchContext = self.makeFetchContext(provider: provider, override: nil)
        let descriptor = spec.descriptor
        let codexResetCreditsFetcher = self.codexResetCreditsFetcher()
        // Keep provider fetch work off MainActor so slow keychain/process reads don't stall menu/UI responsiveness.
        let outcome = await withTaskGroup(
            of: ProviderFetchOutcome.self,
            returning: ProviderFetchOutcome.self)
        { group in
            group.addTask {
                let outcome = await descriptor.fetchOutcome(context: fetchContext)
                guard provider == .codex else { return outcome }
                return await Self.attachingCodexResetCreditsIfNeeded(
                    to: outcome,
                    env: fetchContext.env,
                    fetcher: codexResetCreditsFetcher)
            }
            return await group.next()!
        }
        let claudeHistoryAccountState = provider == .claude
            ? await Self.captureClaudeHistoryAccountState()
            : nil
        let claudeAuthFingerprintAfterFetch = claudeHistoryAccountState?.fingerprintToken
        let claudeAuthChangedDuringFetch = Self.claudeAuthChangedDuringFetch(
            provider: provider,
            beforeFetch: claudeAuthStateBeforeFetch,
            afterFetchFingerprintToken: claudeAuthFingerprintAfterFetch)
        await Self.invalidateClaudeCredentialsFileCacheIfNeeded(changedDuringFetch: claudeAuthChangedDuringFetch)
        let claudeCredentialsChanged = Self.claudeCredentialsChanged(
            beforeFetch: claudeAuthStateBeforeFetch,
            changedDuringFetch: claudeAuthChangedDuringFetch)
        let shouldConsumeClaudeKeychainFingerprint = Self.shouldConsumeClaudeKeychainFingerprintChange(
            beforeFetch: claudeAuthStateBeforeFetch,
            changedDuringFetch: claudeAuthChangedDuringFetch)
        let claudeOAuthHistoryPersistentRefHash = Self.stableClaudeKeychainPersistentRefHash(
            beforeFetch: claudeAuthStateBeforeFetch,
            afterFetchFingerprintToken: claudeAuthFingerprintAfterFetch,
            afterFetchPersistentRefHash: claudeHistoryAccountState?.keychainPersistentRefHash,
            accountStateWasStable: claudeHistoryAccountState?.wasStable == true)
        let claudeOAuthActiveAccountObservation = Self.claudeOAuthActiveAccountObservation(
            beforeFetch: claudeAuthStateBeforeFetch,
            afterFetch: claudeHistoryAccountState)
        // Credential detection consumes change markers. Clean up before rejecting a superseded generation;
        // replacement refreshes wait for their predecessor, so they cannot race this state reset.
        if claudeCredentialsChanged {
            await self.clearClaudeCredentialDerivedStateForCredentialSwap()
        }
        if shouldConsumeClaudeKeychainFingerprint {
            _ = await Self.consumeClaudeKeychainFingerprintChangeWithoutPrompt()
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        await self.applyProviderRefreshOutcome(
            provider: provider,
            outcome: outcome,
            context: ProviderRefreshOutcomeContext(
                generation: generation,
                codexExpectedGuard: codexExpectedGuard,
                claudeOAuthHistoryPersistentRefHash: claudeOAuthHistoryPersistentRefHash,
                claudeOAuthActiveAccountObservation: claudeOAuthActiveAccountObservation))
    }

    private func applyProviderRefreshOutcome(
        provider: UsageProvider,
        outcome: ProviderFetchOutcome,
        context: ProviderRefreshOutcomeContext) async
    {
        await MainActor.run {
            self.lastFetchAttempts[provider] = outcome.attempts
        }

        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            if provider == .codex,
               let codexExpectedGuard = context.codexExpectedGuard,
               !self.shouldApplyCodexUsageResult(expectedGuard: codexExpectedGuard, usage: scoped)
            {
                return
            }
            let backfilled = await MainActor.run { () -> UsageSnapshot? in
                guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else {
                    return nil
                }
                let resetBackfillSource = provider == .codex
                    ? self.codexLastKnownResetSnapshot(matching: context.codexExpectedGuard)
                    : self.lastKnownResetSnapshots[provider]
                let stabilized = Self.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
                    current: scoped,
                    previous: self.snapshots[provider])
                let backfilled = stabilized.backfillingResetTimes(from: resetBackfillSource)
                self.handleQuotaWarningTransitions(provider: provider, snapshot: backfilled)
                self.handleSessionQuotaTransition(provider: provider, snapshot: backfilled)
                if provider == .codex {
                    self.handleCodexResetCreditNotifications(snapshot: backfilled)
                }
                self.lastKnownResetSnapshots[provider] = backfilled
                self.snapshots[provider] = backfilled
                if let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: backfilled, provider: provider) {
                    self.tokenSnapshots[provider] = tokenSnapshot
                    self.tokenErrors[provider] = nil
                    self.tokenFailureGates[provider]?.recordSuccess()
                } else if Self.tokenCostRequiresProviderSnapshot(provider) {
                    self.tokenSnapshots.removeValue(forKey: provider)
                    self.tokenErrors[provider] = nil
                }
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
                self.failureGates[provider]?.recordSuccess()
                if provider == .codex {
                    self.rememberLiveSystemCodexEmailIfNeeded(scoped.accountEmail(for: .codex))
                    self.seedCodexAccountScopedRefreshGuard(accountEmail: scoped.accountEmail(for: .codex))
                }
                return backfilled
            }
            guard let backfilled else { return }
            let isClaudeOAuthSample = provider == .claude
                && result.strategyKind == .oauth
            let claudeOAuthPersistentRefHash: String? = if isClaudeOAuthSample,
                                                           result.claudeOAuthKeychainPersistentRefHash == context
                                                               .claudeOAuthHistoryPersistentRefHash
            {
                result.claudeOAuthKeychainPersistentRefHash
            } else {
                nil
            }
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: backfilled,
                claudeOAuthPersistentRefHash: claudeOAuthPersistentRefHash,
                claudeOAuthHistoryOwnerIdentifier: isClaudeOAuthSample
                    ? result.claudeOAuthHistoryOwnerIdentifier
                    : nil,
                claudeOAuthKeychainCredentialMismatch: isClaudeOAuthSample
                    && result.claudeOAuthKeychainCredentialMismatch,
                claudeOAuthKeychainCredentialAbsent: isClaudeOAuthSample
                    && result.claudeOAuthKeychainCredentialAbsent,
                claudeOAuthKeychainCredentialUnavailable: isClaudeOAuthSample
                    && (result.claudeOAuthKeychainCredentialUnavailable
                        || (result.claudeOAuthKeychainPersistentRefHash != nil
                            && claudeOAuthPersistentRefHash == nil)),
                claudeOAuthActiveAccountObservation: context.claudeOAuthActiveAccountObservation,
                isClaudeOAuthSample: isClaudeOAuthSample)
            guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(
                    provider: provider, settings: self.settings, store: self)
                runtime.providerDidRefresh(context: context, provider: provider)
            }
            if provider == .codex {
                self.recordCodexHistoricalSampleIfNeeded(snapshot: backfilled)
            }
        case let .failure(error):
            // Credential-change cleanup already ran above; cancellation is now safe to suppress.
            guard !Self.errorIsCancellation(error) else { return }
            if provider == .codex,
               let codexExpectedGuard = context.codexExpectedGuard,
               !self.shouldApplyCodexScopedFailure(expectedGuard: codexExpectedGuard)
            {
                return
            }
            guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
            self.recordStartupConnectivityRetryableFailure(error)
            await self.handleProviderFetchFailure(
                provider: provider,
                error: error,
                generation: context.generation)
        }
    }

    private func clearDisabledProviderRefreshState(_ provider: UsageProvider) async {
        self.refreshingProviders.remove(provider)
        await MainActor.run {
            self.snapshots.removeValue(forKey: provider)
            self.lastKnownResetSnapshots.removeValue(forKey: provider)
            self.errors[provider] = nil
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
            self.lastSourceLabels.removeValue(forKey: provider)
            self.lastFetchAttempts.removeValue(forKey: provider)
            self.accountSnapshots.removeValue(forKey: provider)
            if provider == .codex {
                self.codexAccountSnapshots = []
            }
            if provider == .kilo {
                self.kiloScopeSnapshots = []
            }
            if provider == .claude {
                self.clearClaudeSwapAccountState()
            }
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.failureGates[provider]?.reset()
            self.tokenFailureGates[provider]?.reset()
            self.statuses.removeValue(forKey: provider)
            self.statusComponents.removeValue(forKey: provider)
            self.lastKnownSessionRemaining.removeValue(forKey: provider)
            self.lastKnownSessionWindowSource.removeValue(forKey: provider)
            self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider }
            self.lastTokenFetchAt.removeValue(forKey: provider)
        }
    }

    private struct ClaudeRefreshAuthState {
        let fingerprintToken: String
        let credentialsFileChanged: Bool
        let keychainFingerprintChanged: Bool
        let keychainPersistentRefHash: String?
        let activeAccountIdentity: String?
        let accountStateWasStable: Bool
    }

    private struct ClaudeHistoryAccountState {
        let fingerprintToken: String
        let keychainPersistentRefHash: String?
        let activeAccountIdentity: String?
        let wasStable: Bool
    }

    private nonisolated static func claudeCredentialsChanged(
        beforeFetch: ClaudeRefreshAuthState?,
        changedDuringFetch: Bool) -> Bool
    {
        beforeFetch?.credentialsFileChanged == true ||
            beforeFetch?.keychainFingerprintChanged == true ||
            changedDuringFetch
    }

    private nonisolated static func shouldConsumeClaudeKeychainFingerprintChange(
        beforeFetch: ClaudeRefreshAuthState?,
        changedDuringFetch: Bool) -> Bool
    {
        beforeFetch?.keychainFingerprintChanged == true || changedDuringFetch
    }

    private nonisolated static func claudeAuthChangedDuringFetch(
        provider: UsageProvider,
        beforeFetch: ClaudeRefreshAuthState?,
        afterFetchFingerprintToken: String?) -> Bool
    {
        provider == .claude && afterFetchFingerprintToken != beforeFetch?.fingerprintToken
    }

    private nonisolated static func captureClaudeRefreshAuthState(
        invalidateCredentialsFile: Bool) async -> ClaudeRefreshAuthState
    {
        await withTaskGroup(of: ClaudeRefreshAuthState.self, returning: ClaudeRefreshAuthState.self) { group in
            group.addTask {
                let credentialsFileChanged = invalidateCredentialsFile
                    ? ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
                    : false
                let keychainFingerprintChanged = ClaudeOAuthCredentialsStore
                    .claudeKeychainFingerprintChangedWithoutConsuming()
                let fingerprintBefore = ClaudeOAuthCredentialsStore.authFingerprintToken()
                let persistentRefBefore = ClaudeOAuthCredentialsStore
                    .claudeKeychainPersistentRefHashWithoutPrompt()
                let activeAccountIdentity = Self.activeClaudeAccountIdentity()
                let persistentRefAfter = ClaudeOAuthCredentialsStore
                    .claudeKeychainPersistentRefHashWithoutPrompt()
                let fingerprintAfter = ClaudeOAuthCredentialsStore.authFingerprintToken()
                let accountStateWasStable = fingerprintBefore == fingerprintAfter
                    && persistentRefBefore == persistentRefAfter
                return ClaudeRefreshAuthState(
                    fingerprintToken: fingerprintAfter,
                    credentialsFileChanged: credentialsFileChanged,
                    keychainFingerprintChanged: keychainFingerprintChanged,
                    keychainPersistentRefHash: persistentRefAfter,
                    activeAccountIdentity: activeAccountIdentity,
                    accountStateWasStable: accountStateWasStable)
            }
            return await group.next()!
        }
    }

    private nonisolated static func captureClaudeHistoryAccountState() async -> ClaudeHistoryAccountState {
        await withTaskGroup(of: ClaudeHistoryAccountState.self, returning: ClaudeHistoryAccountState.self) { group in
            group.addTask {
                let fingerprintBefore = ClaudeOAuthCredentialsStore.authFingerprintToken()
                let persistentRefBefore = ClaudeOAuthCredentialsStore
                    .claudeKeychainPersistentRefHashWithoutPrompt()
                let activeAccountIdentity = Self.activeClaudeAccountIdentity()
                let persistentRefAfter = ClaudeOAuthCredentialsStore
                    .claudeKeychainPersistentRefHashWithoutPrompt()
                let fingerprintAfter = ClaudeOAuthCredentialsStore.authFingerprintToken()
                let wasStable = fingerprintBefore == fingerprintAfter && persistentRefBefore == persistentRefAfter
                return ClaudeHistoryAccountState(
                    fingerprintToken: fingerprintAfter,
                    keychainPersistentRefHash: persistentRefAfter,
                    activeAccountIdentity: activeAccountIdentity,
                    wasStable: wasStable)
            }
            return await group.next()!
        }
    }

    private nonisolated static func claudeOAuthActiveAccountObservation(
        beforeFetch: ClaudeRefreshAuthState?,
        afterFetch: ClaudeHistoryAccountState?) -> ClaudeOAuthActiveAccountObservation
    {
        guard let beforeFetch,
              beforeFetch.accountStateWasStable,
              let afterFetch,
              afterFetch.wasStable,
              beforeFetch.activeAccountIdentity == afterFetch.activeAccountIdentity
        else {
            return .changed
        }
        return .stable(identity: afterFetch.activeAccountIdentity)
    }

    private nonisolated static func stableClaudeKeychainPersistentRefHash(
        beforeFetch: ClaudeRefreshAuthState?,
        afterFetchFingerprintToken: String?,
        afterFetchPersistentRefHash: String?,
        accountStateWasStable: Bool) -> String?
    {
        guard accountStateWasStable,
              let beforeFetch,
              beforeFetch.accountStateWasStable,
              beforeFetch.fingerprintToken == afterFetchFingerprintToken,
              let beforeFetchPersistentRefHash = beforeFetch.keychainPersistentRefHash,
              beforeFetchPersistentRefHash == afterFetchPersistentRefHash
        else {
            return nil
        }
        return beforeFetchPersistentRefHash
    }

    #if DEBUG
    nonisolated static func _stableClaudeKeychainPersistentRefHashForTesting(
        beforeFetchFingerprintToken: String,
        afterFetchFingerprintToken: String,
        beforeFetchPersistentRefHash: String?,
        afterFetchPersistentRefHash: String?) -> String?
    {
        self.stableClaudeKeychainPersistentRefHash(
            beforeFetch: ClaudeRefreshAuthState(
                fingerprintToken: beforeFetchFingerprintToken,
                credentialsFileChanged: false,
                keychainFingerprintChanged: false,
                keychainPersistentRefHash: beforeFetchPersistentRefHash,
                activeAccountIdentity: nil,
                accountStateWasStable: true),
            afterFetchFingerprintToken: afterFetchFingerprintToken,
            afterFetchPersistentRefHash: afterFetchPersistentRefHash,
            accountStateWasStable: true)
    }

    nonisolated static func _claudeOAuthActiveAccountObservationForTesting(
        identityBeforeFetch: String?,
        identityAfterFetch: String?,
        beforeFetchWasStable: Bool = true,
        afterFetchWasStable: Bool = true) -> ClaudeOAuthActiveAccountObservation
    {
        self.claudeOAuthActiveAccountObservation(
            beforeFetch: ClaudeRefreshAuthState(
                fingerprintToken: "before",
                credentialsFileChanged: false,
                keychainFingerprintChanged: false,
                keychainPersistentRefHash: "before-ref",
                activeAccountIdentity: identityBeforeFetch,
                accountStateWasStable: beforeFetchWasStable),
            afterFetch: ClaudeHistoryAccountState(
                fingerprintToken: "after",
                keychainPersistentRefHash: "after-ref",
                activeAccountIdentity: identityAfterFetch,
                wasStable: afterFetchWasStable))
    }
    #endif

    private nonisolated static func invalidateClaudeCredentialsFileCacheIfChanged() async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
            }
            return await group.next()!
        }
    }

    private nonisolated static func invalidateClaudeCredentialsFileCacheIfNeeded(changedDuringFetch: Bool) async {
        guard changedDuringFetch else { return }
        _ = await self.invalidateClaudeCredentialsFileCacheIfChanged()
    }

    private nonisolated static func consumeClaudeKeychainFingerprintChangeWithoutPrompt() async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.consumeClaudeKeychainFingerprintChangeWithoutPrompt()
            }
            return await group.next()!
        }
    }

    private func clearClaudeCredentialDerivedStateForCredentialSwap() async {
        await MainActor.run {
            self.clearClaudeCredentialDerivedStateForCredentialSwapNow()
        }
    }

    private func clearClaudeCredentialDerivedStateForCredentialSwapNow() {
        self.snapshots.removeValue(forKey: .claude)
        self.lastKnownResetSnapshots.removeValue(forKey: .claude)
        self.errors[.claude] = nil
        self.knownLimitsAvailabilityByProvider.removeValue(forKey: .claude)
        self.lastSourceLabels.removeValue(forKey: .claude)
        self.accountSnapshots.removeValue(forKey: .claude)
        self.tokenSnapshots.removeValue(forKey: .claude)
        self.tokenErrors[.claude] = nil
        self.failureGates[.claude]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        self.lastKnownSessionRemaining.removeValue(forKey: .claude)
        self.lastKnownSessionWindowSource.removeValue(forKey: .claude)
        self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != .claude }
        self.lastTokenFetchAt.removeValue(forKey: .claude)
    }

    private func handleProviderFetchFailure(
        provider: UsageProvider,
        error: Error,
        generation: UInt64) async
    {
        let shouldNotifyPermissionPrompt = Self.isPermissionPromptWaiting(error)
        await MainActor.run {
            guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
            let hadKnownUnavailableLimits = self.knownLimitsAvailabilityByProvider[provider]?.isUnavailable == true
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
            if provider == .claude,
               ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(error.localizedDescription)
            {
                // This is a successful answer about quota availability, not a transient probe failure.
                // Drop prior limits immediately so an Education subscription notice cannot leave stale bars visible.
                self.snapshots.removeValue(forKey: provider)
                self.lastKnownResetSnapshots.removeValue(forKey: provider)
                self.lastKnownSessionRemaining.removeValue(forKey: provider)
                self.lastKnownSessionWindowSource.removeValue(forKey: provider)
                self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider }
                self.lastSourceLabels.removeValue(forKey: provider)
                self.errors[provider] = nil
                self.knownLimitsAvailabilityByProvider[provider] = .unavailable
                self.failureGates[provider]?.reset()
                return
            }
            if provider == .claude,
               hadKnownUnavailableLimits,
               Self.shouldPreservePriorSnapshot(after: error, hadPriorData: true) ||
               Self.isClaudeCLIRateLimitFailure(error)
            {
                self.errors[provider] = nil
                self.knownLimitsAvailabilityByProvider[provider] = .unavailable
                return
            }
            let hadPriorData = self.snapshots[provider] != nil
            let preservesPriorData = Self.shouldPreservePriorSnapshot(
                after: error,
                hadPriorData: hadPriorData) ||
                (provider == .claude &&
                    hadPriorData &&
                    Self.isClaudeCLIRateLimitFailure(error))
            let shouldSurface =
                self.failureGates[provider]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
            let preservesClaudeWebSessionFailure =
                provider == .claude &&
                hadPriorData &&
                Self.isClaudeWebSessionRefreshFailure(error)
            if preservesClaudeWebSessionFailure,
               !shouldSurface
            {
                self.errors[provider] = nil
                return
            }
            if provider == .claude,
               preservesPriorData,
               Self.isClaudeUsageProbeTimeout(error) || Self.isClaudeCLIRateLimitFailure(error)
            {
                self.errors[provider] = nil
                return
            }
            if preservesPriorData, !shouldSurface {
                self.errors[provider] = nil
                return
            }
            if shouldSurface {
                self.errors[provider] = error.localizedDescription
                if !preservesPriorData, !preservesClaudeWebSessionFailure {
                    self.snapshots.removeValue(forKey: provider)
                }
            } else {
                self.errors[provider] = nil
            }
            if shouldNotifyPermissionPrompt {
                self.postPermissionPromptNotificationIfNeeded(provider: provider, error: error)
            }
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        if let runtime = self.providerRuntimes[provider] {
            let context = ProviderRuntimeContext(
                provider: provider, settings: self.settings, store: self)
            runtime.providerDidFail(context: context, provider: provider, error: error)
        }
    }

    private static func shouldPreservePriorSnapshot(after error: Error, hadPriorData: Bool) -> Bool {
        guard hadPriorData else { return false }
        if error is CancellationError { return true }
        if self.isPreservableNetworkTransportError(error) { return true }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") ||
            message.contains("timeout") ||
            message.contains("cancelled") ||
            message.contains("network connection was lost") ||
            message.contains("not connected to the internet")
    }

    static func isPreservableNetworkTransportError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCancelled,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    static func startupConnectivityRetryDelay(forAttempt attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [15, 45, 120, 300]
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }

    static func isStartupConnectivityRetryableError(_ error: Error) -> Bool {
        if error is CancellationError { return false }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return true
            default:
                return false
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") ||
            message.contains("timeout") ||
            message.contains("network connection was lost") ||
            message.contains("not connected to the internet") ||
            message.contains("cannot find host") ||
            message.contains("cannot connect to host") ||
            message.contains("dns lookup")
    }

    private static func isClaudeUsageProbeTimeout(_ error: Error) -> Bool {
        if case ClaudeStatusProbeError.timedOut = error { return true }
        return error.localizedDescription == ClaudeStatusProbeError.timedOut.localizedDescription
    }

    private static func isClaudeCLIRateLimitFailure(_ error: Error) -> Bool {
        ClaudeUsageFetcher.isCLIRateLimitError(error)
    }

    private static func isClaudeWebSessionRefreshFailure(_ error: Error) -> Bool {
        if case ClaudeWebAPIFetcher.FetchError.unauthorized = error { return true }
        return error.localizedDescription == ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription
    }

    nonisolated static func isPermissionPromptWaiting(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return (message.contains("prompt") && message.contains("waiting")) ||
            message.contains("permission prompt") ||
            message.contains("folder trust prompt")
    }

    private func postPermissionPromptNotificationIfNeeded(provider: UsageProvider, error: Error) {
        let now = Date()
        if let last = self.lastPermissionPromptNotificationAt[provider],
           now.timeIntervalSince(last) < 10 * 60
        {
            return
        }
        self.lastPermissionPromptNotificationAt[provider] = now
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        AppNotifications.shared.post(
            idPrefix: "permission-prompt-\(provider.rawValue)",
            title: L("%@ is waiting for permission", providerName),
            body: error.localizedDescription,
            soundEnabled: false)
    }
}
