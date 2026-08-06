import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static func codexSessionQuotaOwnerKey(
        for refreshGuard: CodexAccountScopedRefreshGuard?) -> CodexSessionQuotaOwnerKey?
    {
        guard let refreshGuard else { return nil }
        return CodexSessionQuotaOwnerKey(refreshGuard: refreshGuard)
    }

    nonisolated static func codexSessionQuotaOwnersMatch(
        _ lhs: CodexAccountScopedRefreshGuard?,
        _ rhs: CodexAccountScopedRefreshGuard?) -> Bool
    {
        guard let lhsKey = self.codexSessionQuotaOwnerKey(for: lhs),
              let rhsKey = self.codexSessionQuotaOwnerKey(for: rhs)
        else {
            return false
        }
        return lhsKey == rhsKey
    }

    private struct ProviderRefreshOutcomeContext {
        let generation: UInt64
        let codexExpectedGuard: CodexAccountScopedRefreshGuard?
        let tokenAccount: ProviderTokenAccount?
        let priorTokenAccountSnapshot: TokenAccountUsageSnapshot?
        let codexLimitResetOwnerKey: CodexLimitResetOwnerKey?
        let claudeOAuthHistoryPersistentRefHash: String?
        let claudeOAuthActiveAccountObservation: ClaudeOAuthActiveAccountObservation

        var codexSessionQuotaOwnerKey: CodexSessionQuotaOwnerKey? {
            UsageStore.codexSessionQuotaOwnerKey(for: self.codexExpectedGuard)
        }
    }

    private struct CodexRefreshPublicationPreparation {
        let expectedGuard: CodexAccountScopedRefreshGuard
        let limitResetOwnerKey: CodexLimitResetOwnerKey?
        let previousSnapshot: UsageSnapshot?
        let missingWindowBackfillSnapshot: UsageSnapshot?
    }

    private struct ClaudeRefreshReconciliation {
        let disposition: ClaudeRefreshDisposition
        let oauthHistoryPersistentRefHash: String?
        let oauthActiveAccountObservation: ClaudeOAuthActiveAccountObservation
    }

    private enum ClaudeRefreshDisposition {
        case apply
        case retry
        case retryOwnerCLI
        case discard
    }

    private enum ProviderRefreshRetryMode {
        case ordinary
        case claudeOwnerCLIRecovery
    }

    private struct ClaudeRefreshReconciliationInput {
        let provider: UsageProvider
        let outcome: ProviderFetchOutcome
        let environment: [String: String]
        let dataSource: ClaudeUsageDataSource?
        let priorSourceLabel: String?
        let beforeFetch: ClaudeRefreshAuthState?
        let activeAccountIdentitySourceEligible: Bool
        let ownerCLIRecoveryPass: Bool
        let generation: UInt64
    }

    private static func warningAccountDiscriminator(
        provider: UsageProvider,
        tokenAccount: ProviderTokenAccount?,
        result: ProviderFetchResult,
        context: ProviderRefreshOutcomeContext) -> String?
    {
        if let tokenAccount {
            return self.warningTokenAccountDiscriminator(tokenAccount)
        }
        // Provider-specific by design: Codex owner keys and Claude OAuth observations scope warning deduplication.
        if provider == .codex {
            return context.codexSessionQuotaOwnerKey?.rawValue
        }
        guard provider == .claude else { return nil }
        return self.warningClaudeAccountDiscriminator(
            strategyKind: result.strategyKind,
            observation: context.claudeOAuthActiveAccountObservation,
            oauthHistoryOwnerIdentifier: result.claudeOAuthHistoryOwnerIdentifier)
    }

    static func commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
        current: UsageSnapshot,
        previous: UsageSnapshot?) -> UsageSnapshot
    {
        let previousProvesPaidDepletion = previous?.commandCodeHasSubscriptionPlan == true ||
            (previous?.commandCodeSubscriptionEnrichmentUnavailable == true &&
                previous?.commandCodeMonthlyGrantDepleted == true &&
                previous?.tertiary?.usedPercent == 100)
        guard current.commandCodeSubscriptionEnrichmentUnavailable,
              current.commandCodeMonthlyGrantDepleted,
              previousProvesPaidDepletion,
              let previousMonthly = previous?.tertiary
        else {
            return current
        }
        let depleted = RateWindow(
            usedPercent: 100,
            windowMinutes: previousMonthly.windowMinutes,
            resetsAt: previousMonthly.resetsAt,
            resetDescription: previousMonthly.resetDescription)
        return current.with(tertiary: depleted)
    }

    func refreshForSettingsChange() async {
        await self.runRefresh(
            startupConnectivityRetryAttempt: nil,
            coalesceProviderRefreshesOverride: false,
            waitForRefreshAvailability: true)
    }

    func prepareRefreshState(for provider: UsageProvider? = nil) {
        // Provider-specific by design: Codex active-source correction reconciles managed profile filesystem state.
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
        // Codex source reconciliation can persist a settings correction. Perform it before
        // capturing the publication revision so the request cannot invalidate itself.
        self.prepareRefreshState(for: provider)
        while coalesceIfRefreshing,
              let existingState = self.providerRefreshCoordinator.coalescingState(for: provider.instanceID)
        {
            switch await self.providerRefreshCoordinator.wait(for: provider.instanceID, state: existingState) {
            case .cancelled:
                return
            case .retryRequired:
                self.providerRefreshCoordinator.remove(existingState, for: provider.instanceID)
                continue
            case .completed:
                return
            }
        }

        let request = self.providerRefreshCoordinator.beginReplacingRequest(for: provider.instanceID)
        self.providerRefreshPublicationContexts[provider.instanceID] = ProviderRefreshPublicationContext(
            generation: request.generation,
            enablementRevision: self.settings.providerEnablementRevision(for: provider),
            configRevision: self.settings.providerConfigRevision(for: provider),
            tokenCostScopeSignature: Self.tokenCostRequiresProviderSnapshot(provider)
                ? self.tokenSnapshotScopeSignature(for: provider)
                : nil,
            allowDisabled: allowDisabled)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshotUpdatedAtBeforeRefresh: Date?
            var didStartRefresh = false
            for predecessorState in request.predecessorStates {
                await predecessorState.waitForTaskCompletion()
            }
            if !Task.isCancelled,
               self.providerRefreshCoordinator.isCurrent(request.generation, for: provider.instanceID)
            {
                // A replacement can wait behind a predecessor while Settings changes. Capture
                // the publication inputs at actual fetch start so that queued work uses the new
                // configuration, while later changes still reject its suspended result.
                self.providerRefreshPublicationContexts[provider.instanceID] = ProviderRefreshPublicationContext(
                    generation: request.generation,
                    enablementRevision: self.settings.providerEnablementRevision(for: provider),
                    configRevision: self.settings.providerConfigRevision(for: provider),
                    tokenCostScopeSignature: Self.tokenCostRequiresProviderSnapshot(provider)
                        ? self.tokenSnapshotScopeSignature(for: provider)
                        : nil,
                    allowDisabled: allowDisabled)
                snapshotUpdatedAtBeforeRefresh = self.snapshot(for: provider.instanceID)?.updatedAt
                didStartRefresh = true
                await ProviderRefreshRequestContext.withNewRequest {
                    await self.refreshProviderTracked(
                        provider,
                        allowDisabled: allowDisabled,
                        generation: request.generation)
                }
            }
            let publishedNewSnapshot = didStartRefresh &&
                self.snapshot(for: provider.instanceID)?.updatedAt != snapshotUpdatedAtBeforeRefresh
            let retryRequired = !publishedNewSnapshot &&
                (Task.isCancelled || !self.isCurrentProviderRefreshGeneration(
                    provider,
                    generation: request.generation))
            self.providerRefreshCoordinator.complete(
                request.state,
                for: provider.instanceID,
                retryRequired: retryRequired)
        }
        request.state.install(task: task)
        _ = await self.providerRefreshCoordinator.wait(for: provider.instanceID, state: request.state)
    }

    func isCurrentProviderRefreshGeneration(_ provider: UsageProvider, generation: UInt64?) -> Bool {
        guard let generation else { return true }
        guard self.providerRefreshCoordinator.isCurrent(generation, for: provider.instanceID),
              let context = self.providerRefreshPublicationContexts[provider.instanceID],
              context.generation == generation
        else {
            return false
        }
        return context.enablementRevision == self.settings.providerEnablementRevision(for: provider) &&
            context.configRevision == self.settings.providerConfigRevision(for: provider) &&
            (context.tokenCostScopeSignature == nil ||
                context.tokenCostScopeSignature == self.tokenSnapshotScopeSignature(for: provider))
    }

    func currentProviderRefreshAllowsDisabledPublication(_ provider: UsageProvider) -> Bool {
        guard let context = self.providerRefreshPublicationContexts[provider.instanceID],
              context.allowDisabled,
              let state = self.providerRefreshCoordinator.coalescingState(for: provider.instanceID),
              state.generation == context.generation
        else {
            return false
        }
        return true
    }

    private func refreshProviderTracked(
        _ provider: UsageProvider,
        allowDisabled: Bool,
        generation: UInt64) async
    {
        if self.providerRefreshCoordinator.beginActivity(for: provider.instanceID) {
            self.refreshingProviders.insert(provider.instanceID)
        }
        defer {
            if self.providerRefreshCoordinator.endActivity(for: provider.instanceID) {
                self.refreshingProviders.remove(provider.instanceID)
            }
        }
        var retryMode: ProviderRefreshRetryMode?
        while !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(provider, generation: generation)
        {
            retryMode = await self.refreshProviderPass(
                provider,
                allowDisabled: allowDisabled,
                generation: generation,
                retryMode: retryMode)
            if retryMode == nil {
                break
            }
        }
    }

    private func prepareCodexRefreshPublication() -> CodexRefreshPublicationPreparation {
        let previousGuard = self.lastCodexUsagePublicationGuard
        let expectedGuard = self.freshCodexAccountScopedRefreshGuard()
        let hydrationCandidates = self.codexAccountSnapshots
        let projection = self.settings.codexVisibleAccountProjection
        let visibleAccounts = projection.visibleAccounts
        let ownerKey = self.codexLimitResetOwnerKey(
            expectedGuard: expectedGuard,
            visibleAccounts: visibleAccounts)
        let previousOwnerKey = previousGuard.flatMap {
            CodexLimitResetOwnerKey(identity: $0.identity, accountEmail: $0.accountKey)
        }
        let ownerMatchesPrevious = ownerKey != nil && ownerKey == previousOwnerKey
        self.reconcileCodexAccountStateForUsageOwner(expectedGuard)

        let hydratedPrior: CodexAccountUsageSnapshot? = {
            guard let ownerKey, let activeVisibleAccountID = projection.activeVisibleAccountID else { return nil }
            let matches = hydrationCandidates.filter { row in
                row.snapshot != nil &&
                    row.id == activeVisibleAccountID &&
                    self.codexLimitResetOwnerKey(
                        forVisibleAccount: row.account,
                        visibleAccounts: visibleAccounts) == ownerKey
            }
            guard matches.count == 1 else { return nil }
            return matches[0]
        }()
        // Provider-specific by design: Codex account refresh hydrates only a uniquely matching reconciled owner.
        if self.snapshots[.codex] == nil,
           let hydratedPrior,
           let hydratedSnapshot = hydratedPrior.snapshot
        {
            self.snapshots[.codex] = hydratedSnapshot
            self.lastKnownResetSnapshots[.codex] = hydratedSnapshot
            self.errors[.codex] = hydratedPrior.error
            self.lastSourceLabels[.codex] = hydratedPrior.sourceLabel
            self.lastCodexUsagePublicationGuard = expectedGuard
            self.lastCodexAccountScopedRefreshGuard = expectedGuard
        }

        var trustedCandidates = ownerMatchesPrevious
            ? [self.snapshots[.codex], self.lastKnownResetSnapshots[.codex]].compactMap(\.self)
            : []
        if let hydratedSnapshot = hydratedPrior?.snapshot {
            trustedCandidates.append(hydratedSnapshot)
        }
        let weeklyCandidates = trustedCandidates.filter {
            CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: $0) != nil
        }
        let previousSnapshot = (weeklyCandidates.isEmpty ? trustedCandidates : weeklyCandidates)
            .max { $0.updatedAt < $1.updatedAt }
        let missingWindowBackfillSnapshot = Self.codexMergedResetBackfillSnapshot(trustedCandidates)
        return CodexRefreshPublicationPreparation(
            expectedGuard: expectedGuard,
            limitResetOwnerKey: ownerKey,
            previousSnapshot: previousSnapshot,
            missingWindowBackfillSnapshot: missingWindowBackfillSnapshot)
    }

    /// Runs one provider fetch pass. A nonnil result keeps the retry inside the current coordinator request, so
    /// callers (including `runRefresh`) remain suspended until the account-stable replacement pass completes.
    private func refreshProviderPass(
        _ provider: UsageProvider,
        allowDisabled: Bool,
        generation: UInt64,
        retryMode: ProviderRefreshRetryMode?) async -> ProviderRefreshRetryMode?
    {
        guard let spec = await self.providerRefreshSpec(provider) else { return nil }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return nil }
        let codexPreparation = provider == .codex ? self.prepareCodexRefreshPublication() : nil
        let codexExpectedGuard = codexPreparation?.expectedGuard
        let codexLimitResetOwnerKey = codexPreparation?.limitResetOwnerKey

        if !spec.isEnabled(), !allowDisabled {
            await self.clearDisabledProviderRefreshState(provider)
            return nil
        }

        if provider == .codex, self.shouldFetchAllCodexVisibleAccounts() {
            await self.refreshCodexVisibleAccountsForMenu(generation: generation)
            return nil
        } else if provider == .codex {
            self.codexAccountSnapshots = []
        }

        if provider == .kilo, self.shouldFanOutKiloScopes() {
            await self.refreshKiloScopes(generation: generation)
            guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return nil }
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
            return nil
        } else {
            _ = await MainActor.run {
                self.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
                    provider: provider,
                    accounts: tokenAccounts)
            }
        }

        let tokenAccount = self.settings.effectiveSelectedTokenAccount(for: provider)
        let fetchContext = self.makeFetchContext(
            provider: provider,
            override: nil,
            claudeOwnerCLIRecoveryOnly: retryMode == .claudeOwnerCLIRecovery)
        let claudeHasAdminAPIKey = ClaudeAdminAPISettingsReader.apiKey(environment: fetchContext.env) != nil
        let claudeActiveAccountIdentitySourceEligible = Self.shouldTrackClaudeActiveAccountIdentity(
            provider: provider,
            dataSource: fetchContext.settings?.claude?.usageDataSource,
            hasSelectedTokenAccount: tokenAccount != nil,
            hasAdminAPIKey: claudeHasAdminAPIKey)
        let priorClaudeSourceLabel = provider == .claude ? self.lastSourceLabels[.claude] : nil
        self.diagnostics[provider.instanceID] = nil
        let claudeAuthStateBeforeFetch = claudeActiveAccountIdentitySourceEligible
            ? await Self.captureClaudeRefreshAuthState(
                invalidateCredentialsFile: true,
                environment: fetchContext.env)
            : nil
        let priorTokenAccountSnapshot = self.tokenAccountSnapshot(provider: provider, account: tokenAccount)
        let descriptor = spec.descriptor
        let codexResetCreditsFetcher = self.codexResetCreditsFetcher()
        let previousCodexSnapshot = codexPreparation?.previousSnapshot
        let codexMissingWindowBackfillSnapshot = codexPreparation?.missingWindowBackfillSnapshot
        let fetchOutcome: @Sendable () async -> ProviderFetchOutcome = {
            let outcome = await descriptor.fetchOutcome(context: fetchContext)
            guard provider == .codex else { return outcome }
            return await Self.attachingCodexResetCreditsIfNeeded(
                to: outcome,
                env: fetchContext.env,
                fetcher: codexResetCreditsFetcher)
        }
        // Keep provider fetch work off MainActor so slow keychain/process reads don't stall menu/UI responsiveness.
        let initialOutcome: ProviderFetchOutcome = if let override = self._test_providerFetchOutcomeOverride {
            await override(provider)
        } else {
            await withTaskGroup(
                of: ProviderFetchOutcome.self,
                returning: ProviderFetchOutcome.self)
            { group in
                group.addTask(operation: fetchOutcome)
                return await group.next()!
            }
        }
        let outcome: ProviderFetchOutcome
        if provider == .codex {
            if case let .success(result) = initialOutcome.result,
               let codexExpectedGuard,
               !self.shouldApplyCodexUsageResult(
                   expectedGuard: codexExpectedGuard,
                   usage: result.usage.scoped(to: .codex))
            {
                self.retireCodexStateIfRefreshOwnerChanged(
                    expectedGuard: codexExpectedGuard,
                    generation: generation)
                return nil
            }
            guard let admittedOutcome = await Self.codexOutcomeAdmittedForPublication(
                initialOutcome: initialOutcome,
                previousSnapshot: previousCodexSnapshot,
                missingWindowBackfillSnapshot: codexMissingWindowBackfillSnapshot,
                fetchConfirmation: fetchOutcome)
            else {
                if let codexExpectedGuard {
                    self.retireCodexStateIfRefreshOwnerChanged(
                        expectedGuard: codexExpectedGuard,
                        generation: generation)
                }
                return nil
            }
            if case let .success(result) = admittedOutcome.result,
               let codexExpectedGuard,
               !self.shouldApplyCodexUsageResult(
                   expectedGuard: codexExpectedGuard,
                   usage: result.usage.scoped(to: .codex))
            {
                self.retireCodexStateIfRefreshOwnerChanged(
                    expectedGuard: codexExpectedGuard,
                    generation: generation)
                return nil
            }
            outcome = admittedOutcome
        } else {
            outcome = initialOutcome
        }
        let claudeReconciliation = await self.reconcileClaudeRefreshAfterFetch(input: .init(
            provider: provider,
            outcome: outcome,
            environment: fetchContext.env,
            dataSource: fetchContext.settings?.claude?.usageDataSource,
            priorSourceLabel: priorClaudeSourceLabel,
            beforeFetch: claudeAuthStateBeforeFetch,
            activeAccountIdentitySourceEligible: claudeActiveAccountIdentitySourceEligible,
            ownerCLIRecoveryPass: retryMode == .claudeOwnerCLIRecovery,
            generation: generation))
        let outcomeContext = ProviderRefreshOutcomeContext(
            generation: generation,
            codexExpectedGuard: codexExpectedGuard,
            tokenAccount: tokenAccount,
            priorTokenAccountSnapshot: priorTokenAccountSnapshot,
            codexLimitResetOwnerKey: codexLimitResetOwnerKey,
            claudeOAuthHistoryPersistentRefHash: claudeReconciliation.oauthHistoryPersistentRefHash,
            claudeOAuthActiveAccountObservation: claudeReconciliation.oauthActiveAccountObservation)
        return await self.completeProviderRefreshPass(
            provider: provider,
            outcome: outcome,
            reconciliation: claudeReconciliation,
            context: outcomeContext)
    }

    private func completeProviderRefreshPass(
        provider: UsageProvider,
        outcome: ProviderFetchOutcome,
        reconciliation: ClaudeRefreshReconciliation,
        context: ProviderRefreshOutcomeContext) async -> ProviderRefreshRetryMode?
    {
        switch reconciliation.disposition {
        case .retry:
            return .ordinary
        case .retryOwnerCLI:
            return .claudeOwnerCLIRecovery
        case .discard:
            return nil
        case .apply:
            break
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return nil }
        await self.applyProviderRefreshOutcome(
            provider: provider,
            outcome: outcome,
            context: context)
        return nil
    }

    private func reconcileClaudeRefreshAfterFetch(
        input: ClaudeRefreshReconciliationInput) async -> ClaudeRefreshReconciliation
    {
        guard input.provider == .claude else {
            return ClaudeRefreshReconciliation(
                disposition: .apply,
                oauthHistoryPersistentRefHash: nil,
                oauthActiveAccountObservation: .changed)
        }
        let historyAccountState = await Self.captureClaudeHistoryAccountState(environment: input.environment)
        guard self.isCurrentProviderRefreshGeneration(input.provider, generation: input.generation) else {
            return ClaudeRefreshReconciliation(
                disposition: .discard,
                oauthHistoryPersistentRefHash: nil,
                oauthActiveAccountObservation: .changed)
        }
        let fingerprintAfterFetch = historyAccountState.fingerprintToken
        let authChangedDuringFetch = Self.claudeAuthChangedDuringFetch(
            provider: input.provider,
            beforeFetch: input.beforeFetch,
            afterFetchFingerprintToken: fingerprintAfterFetch)
        let shouldTrackActiveAccount = Self.shouldReconcileClaudeActiveAccountIdentity(
            sourceEligible: input.activeAccountIdentitySourceEligible,
            dataSource: input.dataSource,
            outcome: input.outcome,
            priorSourceLabel: input.priorSourceLabel)
        await Self.invalidateClaudeCredentialsFileCacheIfNeeded(
            changedDuringFetch: shouldTrackActiveAccount && authChangedDuringFetch,
            environment: input.environment)
        guard self.isCurrentProviderRefreshGeneration(input.provider, generation: input.generation) else {
            return ClaudeRefreshReconciliation(
                disposition: .discard,
                oauthHistoryPersistentRefHash: nil,
                oauthActiveAccountObservation: .changed)
        }
        let activeAccountChangedDuringFetch = Self.claudeActiveAccountChangedDuringFetch(
            beforeFetch: input.beforeFetch?.activeAccountIdentity,
            afterFetch: historyAccountState.activeAccountIdentity,
            shouldTrack: shouldTrackActiveAccount,
            successfulCLIOutcome: Self.isSuccessfulClaudeCLIOutcome(input.outcome))
        let activeAccountReconciliation = self.reconcileClaudeActiveAccountIdentity(
            beforeFetch: input.beforeFetch?.activeAccountIdentity,
            afterFetch: historyAccountState.activeAccountIdentity,
            observedAccountUuids: [input.beforeFetch?.activeAccountUuid, historyAccountState.activeAccountUuid]
                .compactMap(\.self),
            shouldTrack: shouldTrackActiveAccount,
            environment: input.environment)
        let credentialsChanged = shouldTrackActiveAccount && (
            Self.claudeCredentialsChanged(
                beforeFetch: input.beforeFetch,
                changedDuringFetch: authChangedDuringFetch) || activeAccountReconciliation.changed)
        let successfulOAuth = Self.isSuccessfulClaudeOAuthOutcome(input.outcome)
        let successfulOAuthCredentialOwner = Self.successfulClaudeOAuthCredentialOwner(input.outcome)
        let activeAccountMismatch = successfulOAuth && (
            activeAccountChangedDuringFetch || activeAccountReconciliation.changedFromPersistedIdentity)
        let quarantinedCredentialsFile = if successfulOAuthCredentialOwner == .claudeCLI {
            await Self.isClaudeCredentialsFileQuarantinedForOAuth(environment: input.environment)
        } else {
            false
        }
        let oauthAccountMismatch = activeAccountMismatch || quarantinedCredentialsFile
        if oauthAccountMismatch {
            if activeAccountMismatch, successfulOAuthCredentialOwner == .claudeCLI {
                await Self.quarantineClaudeCredentialsFileForOAuth(environment: input.environment)
            }
            await Self.invalidateClaudeOAuthCache(environment: input.environment)
            guard self.isCurrentProviderRefreshGeneration(input.provider, generation: input.generation) else {
                return ClaudeRefreshReconciliation(
                    disposition: .discard,
                    oauthHistoryPersistentRefHash: nil,
                    oauthActiveAccountObservation: .changed)
            }
        }
        let ownerCLIRecoverySucceeded = !input.ownerCLIRecoveryPass || Self.isSuccessfulClaudeCLIOutcome(input.outcome)
        if !oauthAccountMismatch, !activeAccountChangedDuringFetch, ownerCLIRecoverySucceeded {
            self.persistClaudeActiveAccountIdentity(
                activeAccountReconciliation.newestIdentity,
                environment: input.environment)
        }
        let sourceAuthorityChanged = Self.claudeSourceAuthorityChanged(
            priorSourceLabel: input.priorSourceLabel,
            dataSource: input.dataSource,
            outcome: input.outcome)
        let persistentRefHash = Self.stableClaudeKeychainPersistentRefHash(
            beforeFetch: input.beforeFetch,
            afterFetchFingerprintToken: fingerprintAfterFetch,
            afterFetchPersistentRefHash: historyAccountState.keychainPersistentRefHash,
            accountStateWasStable: historyAccountState.wasStable)
        let activeAccountObservation = Self.claudeOAuthActiveAccountObservation(
            beforeFetch: input.beforeFetch,
            afterFetch: historyAccountState)

        // Only the ambient CLI authority observes Claude's account/config files. Source-authority changes apply to
        // every Claude route, but retire only the live projection; configured token-account caches remain isolated.
        if credentialsChanged || activeAccountChangedDuringFetch || sourceAuthorityChanged {
            self.clearClaudeCredentialDerivedStateForCredentialSwap()
        }
        let disposition: ClaudeRefreshDisposition = if oauthAccountMismatch {
            .retryOwnerCLI
        } else if activeAccountChangedDuringFetch {
            .retry
        } else {
            .apply
        }
        return ClaudeRefreshReconciliation(
            disposition: disposition,
            oauthHistoryPersistentRefHash: persistentRefHash,
            oauthActiveAccountObservation: activeAccountObservation)
    }

    private func applyProviderRefreshOutcome(
        provider: UsageProvider,
        outcome: ProviderFetchOutcome,
        context: ProviderRefreshOutcomeContext) async
    {
        switch outcome.result {
        case let .success(result):
            await self.applyProviderRefreshSuccess(
                provider: provider,
                result: result,
                attempts: outcome.attempts,
                context: context)
        case let .failure(error):
            await self.applyProviderRefreshFailure(
                provider: provider,
                error: error,
                attempts: outcome.attempts,
                context: context)
        }
    }

    private func applyProviderRefreshSuccess(
        provider: UsageProvider,
        result: ProviderFetchResult,
        attempts: [ProviderFetchAttempt],
        context: ProviderRefreshOutcomeContext) async
    {
        let rawScoped = result.usage.scoped(to: provider)
        // Provider-specific by design: Codex results are discarded when managed-account ownership changes mid-fetch.
        if provider == .codex,
           let codexExpectedGuard = context.codexExpectedGuard,
           !self.shouldApplyCodexUsageResult(expectedGuard: codexExpectedGuard, usage: rawScoped)
        {
            self.retireCodexStateIfRefreshOwnerChanged(
                expectedGuard: codexExpectedGuard,
                generation: context.generation)
            return
        }
        let scoped = Self.codexUsageWithExpectedEmailIfMissing(
            provider: provider,
            usage: rawScoped,
            expectedGuard: context.codexExpectedGuard)
        let currentTokenAccount = context.tokenAccount.flatMap { account in
            self.uniqueTokenAccount(provider: provider, accountID: account.id)
        }
        if context.tokenAccount != nil, currentTokenAccount == nil {
            return
        }
        let accountScoped = if let tokenAccount = currentTokenAccount {
            self.applyAccountLabel(scoped, provider: provider, account: tokenAccount)
        } else {
            scoped
        }
        let backfilled = await MainActor.run { () -> UsageSnapshot? in
            guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else {
                return nil
            }
            if provider == .codex,
               let codexExpectedGuard = context.codexExpectedGuard,
               !self.shouldApplyCodexUsageResult(expectedGuard: codexExpectedGuard, usage: rawScoped)
            {
                self.retireCodexStateIfRefreshOwnerChanged(
                    expectedGuard: codexExpectedGuard,
                    generation: context.generation)
                return nil
            }
            self.lastFetchAttempts[provider.instanceID] = attempts
            let resetBackfillSource = if provider == .codex {
                context.codexLimitResetOwnerKey == nil
                    ? nil
                    : self.codexLastKnownResetSnapshot(matching: context.codexExpectedGuard)
            } else {
                self.lastKnownResetSnapshots[provider.instanceID]
            }
            let profileStable = self.preservingDeepSeekProfileCatalog(in: accountScoped, provider: provider)
            let stabilized = Self.commandCodeSnapshotResolvingDepletionOnEnrichmentFailure(
                current: profileStable,
                previous: self.snapshots[provider.instanceID])
            let backfilled = stabilized.backfillingResetTimes(from: resetBackfillSource)
            let warningAccountDiscriminator = Self.warningAccountDiscriminator(
                provider: provider,
                tokenAccount: currentTokenAccount,
                result: result,
                context: context)
            self.handleQuotaWarningTransitions(
                provider: provider,
                snapshot: backfilled,
                accountDiscriminator: warningAccountDiscriminator)
            self.handleSessionQuotaTransition(
                provider: provider,
                snapshot: backfilled,
                codexOwnerKey: provider == .codex ? context.codexSessionQuotaOwnerKey : nil)
            self.handlePredictivePaceWarningTransitions(
                provider: provider,
                snapshot: backfilled,
                accountDiscriminatorOverride: provider == .claude ? warningAccountDiscriminator : nil)
            if provider == .codex {
                self.handleCodexResetCreditNotifications(snapshot: backfilled)
            }
            self.lastKnownResetSnapshots[provider.instanceID] = backfilled
            self.snapshots[provider.instanceID] = backfilled
            self.widgetUsagePreservationBlockedProviders.remove(provider.instanceID)
            if provider == .deepseek {
                self.clearDeepSeekProfileTransition()
            }
            if let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: backfilled, provider: provider) {
                self.publishTokenSnapshot(tokenSnapshot, for: provider)
                self.tokenErrors[provider.instanceID] = nil
                self.tokenFailureGates[provider.instanceID]?.recordSuccess()
            } else if Self.tokenCostRequiresProviderSnapshot(provider) {
                self.publishConfirmedEmptyTokenSnapshot(for: provider)
                self.tokenErrors[provider.instanceID] = nil
            }
            self.lastSourceLabels[provider.instanceID] = result.sourceLabel
            self.errors[provider.instanceID] = nil
            self.diagnostics[provider.instanceID] = result.diagnostic
            if let tokenAccount = currentTokenAccount {
                self.cacheTokenAccountSnapshot(
                    provider: provider,
                    account: tokenAccount,
                    snapshot: backfilled,
                    sourceLabel: result.sourceLabel)
            }
            if provider == .gemini {
                self.clearGeminiConsumerTierDeprecationObservation()
            }
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
            self.failureGates[provider.instanceID]?.recordSuccess()
            if provider == .codex {
                self.rememberLiveSystemCodexEmailIfNeeded(scoped.accountEmail(for: .codex))
                self.seedCodexAccountScopedRefreshGuard(accountEmail: scoped.accountEmail(for: .codex))
                self.lastCodexUsagePublicationGuard = self.lastCodexAccountScopedRefreshGuard
                self.persistSingleCodexAccountSnapshot(
                    backfilled,
                    sourceLabel: result.sourceLabel,
                    expectedGuard: context.codexExpectedGuard,
                    expectedOwnerKey: context.codexLimitResetOwnerKey)
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
            isClaudeOAuthSample: isClaudeOAuthSample,
            codexLimitResetOwnerKey: context.codexLimitResetOwnerKey)
        guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
        if let runtime = self.providerRuntimes[provider.instanceID] {
            let runtimeContext = ProviderRuntimeContext(
                provider: provider, settings: self.settings, store: self)
            runtime.providerDidRefresh(context: runtimeContext, provider: provider)
        }
        if provider == .codex {
            self.recordCodexHistoricalSampleIfNeeded(snapshot: backfilled)
        }
    }

    private func applyProviderRefreshFailure(
        provider: UsageProvider,
        error: Error,
        attempts: [ProviderFetchAttempt],
        context: ProviderRefreshOutcomeContext) async
    {
        if provider == .codex,
           let codexExpectedGuard = context.codexExpectedGuard,
           !self.shouldApplyCodexScopedFailure(expectedGuard: codexExpectedGuard)
        {
            self.retireCodexStateIfRefreshOwnerChanged(
                expectedGuard: codexExpectedGuard,
                generation: context.generation)
            return
        }
        // Credential-change cleanup already ran above; cancellation is now safe to suppress.
        if Self.errorIsCancellation(error) {
            if provider == .deepseek,
               self.isCurrentProviderRefreshGeneration(provider, generation: context.generation)
            {
                self.markDeepSeekProfileTransitionUnavailable()
            }
            return
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
        if provider == .deepseek {
            self.markDeepSeekProfileTransitionUnavailable()
        }
        self.bindCodexFailurePublicationOwner(
            provider: provider,
            expectedGuard: context.codexExpectedGuard)
        self.lastFetchAttempts[provider.instanceID] = attempts
        self.recordStartupConnectivityRetryableFailure(error)
        await self.handleProviderFetchFailure(
            provider: provider,
            error: error,
            attempts: attempts,
            context: context)
    }

    private func preservingDeepSeekProfileCatalog(
        in snapshot: UsageSnapshot,
        provider: UsageProvider) -> UsageSnapshot
    {
        guard provider == .deepseek else { return snapshot }
        return snapshot.preservingDeepSeekPlatformProfiles(from: self.presentationSnapshot(for: .deepseek))
    }

    private func bindCodexFailurePublicationOwner(
        provider: UsageProvider,
        expectedGuard: CodexAccountScopedRefreshGuard?)
    {
        guard provider == .codex, let expectedGuard else { return }
        self.lastCodexUsagePublicationGuard = expectedGuard
    }

    private func retireCodexStateIfRefreshOwnerChanged(
        expectedGuard: CodexAccountScopedRefreshGuard,
        generation: UInt64)
    {
        guard self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
        let currentGuard = self.freshCodexAccountScopedRefreshGuard()
        guard !Self.codexScopedRefreshGuardsMatchAccount(expectedGuard, currentGuard) else { return }
        self.reconcileCodexAccountStateForUsageOwner(currentGuard)
    }

    private nonisolated static func codexUsageWithExpectedEmailIfMissing(
        provider: UsageProvider,
        usage: UsageSnapshot,
        expectedGuard: CodexAccountScopedRefreshGuard?) -> UsageSnapshot
    {
        guard provider == .codex,
              CodexIdentityResolver.normalizeEmail(usage.accountEmail(for: .codex)) == nil,
              let accountEmail = CodexIdentityResolver.normalizeEmail(expectedGuard?.accountKey)
        else {
            return usage
        }
        let identity = usage.identity(for: .codex)
        return usage.withIdentity(ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: accountEmail,
            accountOrganization: identity?.accountOrganization,
            loginMethod: identity?.loginMethod))
    }

    private func persistSingleCodexAccountSnapshot(
        _ snapshot: UsageSnapshot,
        sourceLabel: String,
        expectedGuard: CodexAccountScopedRefreshGuard?,
        expectedOwnerKey: CodexLimitResetOwnerKey?)
    {
        guard let expectedGuard,
              let expectedOwnerKey
        else { return }

        let currentGuard = self.freshCodexAccountScopedRefreshGuard()
        guard Self.codexScopedRefreshGuardsMatchAccount(expectedGuard, currentGuard),
              let currentOwnerKey = CodexLimitResetOwnerKey(
                  identity: currentGuard.identity,
                  accountEmail: currentGuard.accountKey),
              currentOwnerKey == expectedOwnerKey
        else { return }

        let visibleAccounts = self.freshCodexVisibleAccountsForSnapshotHydration()
        let activeMatches = visibleAccounts.filter {
            $0.isActive &&
                $0.selectionSource == currentGuard.source &&
                CodexIdentityResolver.normalizeEmail($0.email) == currentGuard.accountKey
        }
        guard activeMatches.count == 1,
              let account = activeMatches.first,
              let snapshotEmail = CodexIdentityResolver.normalizeEmail(snapshot.accountEmail(for: .codex)),
              snapshotEmail == CodexIdentityResolver.normalizeEmail(currentGuard.accountKey),
              snapshotEmail == CodexIdentityResolver.normalizeEmail(account.email),
              self.codexLimitResetOwnerKey(
                  forVisibleAccount: account,
                  visibleAccounts: visibleAccounts) == currentOwnerKey
        else { return }

        let identity = snapshot.identity(for: .codex)
        let relabeled = snapshot.withIdentity(ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: account.email,
            accountOrganization: identity?.accountOrganization,
            loginMethod: identity?.loginMethod ?? account.workspaceLabel))
        let currentSnapshots = [CodexAccountUsageSnapshot(
            account: account,
            snapshot: relabeled,
            error: nil,
            sourceLabel: sourceLabel)]
        self.codexAccountSnapshots = currentSnapshots
        self.codexAccountUsageSnapshotStore?.store(currentSnapshots)
    }

    private func clearDisabledProviderRefreshState(_ provider: UsageProvider) async {
        self.clearProviderRuntimeState(provider)
    }

    private struct ClaudeRefreshAuthState {
        let fingerprintToken: String
        let credentialsFileChanged: Bool
        let keychainFingerprintChanged: Bool
        let keychainPersistentRefHash: String?
        let activeAccountUuid: String?
        let activeAccountIdentity: String?
        let accountStateWasStable: Bool
    }

    private struct ClaudeHistoryAccountState {
        let fingerprintToken: String
        let keychainPersistentRefHash: String?
        let activeAccountUuid: String?
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

    nonisolated static func shouldTrackClaudeActiveAccountIdentity(
        provider: UsageProvider,
        dataSource: ClaudeUsageDataSource?,
        hasSelectedTokenAccount: Bool,
        hasAdminAPIKey: Bool) -> Bool
    {
        guard provider == .claude, !hasSelectedTokenAccount else { return false }
        switch dataSource {
        case .cli:
            return true
        case .auto:
            return !hasAdminAPIKey
        case .oauth:
            // Explicit OAuth records sourced from the Claude file/cache require a stable account
            // observation before their unavailable-Keychain owner can enter history.
            return true
        case .api, .web, nil:
            return false
        }
    }

    private nonisolated static func shouldReconcileClaudeActiveAccountIdentity(
        sourceEligible: Bool,
        dataSource: ClaudeUsageDataSource?,
        outcome: ProviderFetchOutcome,
        priorSourceLabel: String?) -> Bool
    {
        guard sourceEligible else { return false }
        switch outcome.result {
        case let .success(result):
            // An OAuth result uses the owner-selected Claude profile just as the CLI route does.
            // A successful OAuth result must therefore reconcile a profile/account swap before
            // its reset snapshots can be published or backfilled.
            return result.strategyKind == .cli || result.strategyKind == .oauth
        case .failure:
            if dataSource == .cli {
                return true
            }
            let normalizedPriorSource = priorSourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedPriorSource == "claude" || normalizedPriorSource == "cli"
        }
    }

    private nonisolated static func claudeActiveAccountChangedDuringFetch(
        beforeFetch: String?,
        afterFetch: String?,
        shouldTrack: Bool,
        successfulCLIOutcome: Bool) -> Bool
    {
        guard shouldTrack, let beforeFetch, beforeFetch != afterFetch else { return false }
        return afterFetch != nil || successfulCLIOutcome
    }

    private nonisolated static func isSuccessfulClaudeCLIOutcome(_ outcome: ProviderFetchOutcome) -> Bool {
        guard case let .success(result) = outcome.result else { return false }
        if case .cli = result.strategyKind {
            return true
        }
        return false
    }

    private nonisolated static func isSuccessfulClaudeOAuthOutcome(_ outcome: ProviderFetchOutcome) -> Bool {
        guard case let .success(result) = outcome.result else { return false }
        if case .oauth = result.strategyKind {
            return true
        }
        return false
    }

    private nonisolated static func successfulClaudeOAuthCredentialOwner(
        _ outcome: ProviderFetchOutcome) -> ClaudeOAuthCredentialOwner?
    {
        guard case let .success(result) = outcome.result,
              result.strategyKind == .oauth
        else { return nil }
        return result.claudeOAuthCredentialOwner
    }

    private enum ClaudeSourceAuthority: Equatable {
        case cli
        case web
        case api
        case oauth

        init?(sourceLabel: String?) {
            switch sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "claude", "cli":
                self = .cli
            case "web":
                self = .web
            case "admin-api", "api":
                self = .api
            case "oauth":
                self = .oauth
            default:
                return nil
            }
        }

        init?(result: ProviderFetchResult) {
            switch result.strategyKind {
            case .cli:
                self = .cli
            case .web, .webDashboard:
                self = .web
            case .apiToken:
                self = .api
            case .oauth:
                self = .oauth
            case .localProbe:
                self.init(sourceLabel: result.sourceLabel)
            }
        }

        init?(dataSource: ClaudeUsageDataSource?) {
            switch dataSource {
            case .cli:
                self = .cli
            case .web:
                self = .web
            case .api:
                self = .api
            case .oauth:
                self = .oauth
            case .auto, nil:
                return nil
            }
        }
    }

    private nonisolated static func claudeSourceAuthorityChanged(
        priorSourceLabel: String?,
        dataSource: ClaudeUsageDataSource?,
        outcome: ProviderFetchOutcome) -> Bool
    {
        guard let priorAuthority = ClaudeSourceAuthority(sourceLabel: priorSourceLabel) else { return false }
        let currentAuthority: ClaudeSourceAuthority? = switch outcome.result {
        case let .success(result):
            ClaudeSourceAuthority(result: result)
        case .failure:
            ClaudeSourceAuthority(dataSource: dataSource)
        }
        guard let currentAuthority else { return false }
        return priorAuthority != currentAuthority
    }

    private nonisolated static func claudeAuthChangedDuringFetch(
        provider: UsageProvider,
        beforeFetch: ClaudeRefreshAuthState?,
        afterFetchFingerprintToken: String?) -> Bool
    {
        // Provider-specific by design: Claude credential fingerprints invalidate results produced by an old OAuth key.
        provider == .claude && afterFetchFingerprintToken != beforeFetch?.fingerprintToken
    }

    private nonisolated static func captureClaudeRefreshAuthState(
        invalidateCredentialsFile: Bool,
        environment: [String: String]) async -> ClaudeRefreshAuthState
    {
        await withTaskGroup(of: ClaudeRefreshAuthState.self, returning: ClaudeRefreshAuthState.self) { group in
            group.addTask {
                let credentialsFileChanged = invalidateCredentialsFile
                    ? ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(environment: environment)
                    : false
                let fingerprintBefore = ClaudeOAuthCredentialsStore
                    .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: environment) ?? "none"
                let activeAccountUuid = Self.activeClaudeAccountUuid(environment: environment)
                let activeAccountIdentity = activeAccountUuid.map {
                    Self.claudeAccountIdentity($0, environment: environment)
                }
                let fingerprintAfter = ClaudeOAuthCredentialsStore
                    .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: environment) ?? "none"
                let accountStateWasStable = fingerprintBefore == fingerprintAfter
                return ClaudeRefreshAuthState(
                    fingerprintToken: fingerprintAfter,
                    credentialsFileChanged: credentialsFileChanged,
                    keychainFingerprintChanged: false,
                    keychainPersistentRefHash: nil,
                    activeAccountUuid: activeAccountUuid,
                    activeAccountIdentity: activeAccountIdentity,
                    accountStateWasStable: accountStateWasStable)
            }
            return await group.next()!
        }
    }

    private nonisolated static func captureClaudeHistoryAccountState(
        environment: [String: String]) async -> ClaudeHistoryAccountState
    {
        await withTaskGroup(of: ClaudeHistoryAccountState.self, returning: ClaudeHistoryAccountState.self) { group in
            group.addTask {
                let fingerprintBefore = ClaudeOAuthCredentialsStore
                    .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: environment) ?? "none"
                let activeAccountUuid = Self.activeClaudeAccountUuid(environment: environment)
                let activeAccountIdentity = activeAccountUuid.map {
                    Self.claudeAccountIdentity($0, environment: environment)
                }
                let fingerprintAfter = ClaudeOAuthCredentialsStore
                    .currentCredentialsFileFingerprintWithoutPromptForAuthGate(environment: environment) ?? "none"
                let wasStable = fingerprintBefore == fingerprintAfter
                return ClaudeHistoryAccountState(
                    fingerprintToken: fingerprintAfter,
                    keychainPersistentRefHash: nil,
                    activeAccountUuid: activeAccountUuid,
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
                activeAccountUuid: nil,
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
                activeAccountUuid: nil,
                activeAccountIdentity: identityBeforeFetch,
                accountStateWasStable: beforeFetchWasStable),
            afterFetch: ClaudeHistoryAccountState(
                fingerprintToken: "after",
                keychainPersistentRefHash: "after-ref",
                activeAccountUuid: nil,
                activeAccountIdentity: identityAfterFetch,
                wasStable: afterFetchWasStable))
    }
    #endif

    private nonisolated static func invalidateClaudeCredentialsFileCacheIfChanged(
        environment: [String: String]) async -> Bool
    {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(environment: environment)
            }
            return await group.next()!
        }
    }

    private nonisolated static func invalidateClaudeCredentialsFileCacheIfNeeded(
        changedDuringFetch: Bool,
        environment: [String: String]) async
    {
        guard changedDuringFetch else { return }
        _ = await self.invalidateClaudeCredentialsFileCacheIfChanged(environment: environment)
    }

    private nonisolated static func invalidateClaudeOAuthCache(environment: [String: String]) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.invalidateCache(environment: environment)
            }
            await group.waitForAll()
        }
    }

    private func clearClaudeCredentialDerivedStateForCredentialSwap() {
        // Provider-specific by design: Claude credential swaps invalidate OAuth, swap, widget, quota, and token state.
        self.widgetUsagePreservationBlockedProviders.insert(.claude)
        self.snapshots.removeValue(forKey: .claude)
        self.lastKnownResetSnapshots.removeValue(forKey: .claude)
        self.errors[.claude] = nil
        self.knownLimitsAvailabilityByProvider.removeValue(forKey: .claude)
        self.lastSourceLabels.removeValue(forKey: .claude)
        self.clearTokenSnapshot(for: .claude)
        self.tokenErrors[.claude] = nil
        self.failureGates[.claude]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        self.clearSessionQuotaTransitionState(provider: .claude)
        self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != .claude }
        self.lastTokenFetchAt.removeValue(forKey: .claude)
    }

    private func handleProviderFetchFailure(
        provider: UsageProvider,
        error: Error,
        attempts: [ProviderFetchAttempt],
        context: ProviderRefreshOutcomeContext) async
    {
        let shouldNotifyPermissionPrompt = Self.isPermissionPromptWaiting(error)
        await MainActor.run {
            guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
            self.diagnostics[provider.instanceID] = nil
            if provider == .gemini, Self.isGeminiConsumerTierDeprecationError(error) {
                // This is a durable provider migration signal, not a transient fetch failure.
                // Surface it immediately so a cached snapshot cannot hide the required handoff.
                self.observeGeminiConsumerTierDeprecation(from: error)
                self.errors[provider.instanceID] = error.localizedDescription
                self.snapshots.removeValue(forKey: provider.instanceID)
                self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
                self.lastSourceLabels.removeValue(forKey: provider.instanceID)
                self.failureGates[provider.instanceID]?.reset()
                return
            }
            if provider == .claude,
               ClaudeUsageError.isClaudeOAuthUsageRateLimit(error)
            {
                if let (account, cached) = self.validatedClaudeOAuthTokenAccountFallback(context: context),
                   let snapshot = cached.snapshot
                {
                    self.snapshots[provider.instanceID] = snapshot
                    self.lastKnownResetSnapshots[provider.instanceID] = snapshot
                    self.lastSourceLabels[provider.instanceID] = "oauth"
                    self.cacheTokenAccountSnapshot(
                        provider: provider,
                        account: account,
                        snapshot: snapshot,
                        sourceLabel: "oauth")
                    self.errors[provider.instanceID] = nil
                    self.failureGates[provider.instanceID]?.reset()
                    return
                }
                // Credential-change cleanup runs before failure handling and removes all unscoped Claude state.
                // A surviving OAuth snapshot therefore belongs to the credential observed across this refresh.
                if context.tokenAccount == nil,
                   self.snapshots[provider.instanceID] != nil,
                   self.lastSourceLabels[provider.instanceID] == "oauth"
                {
                    self.errors[provider.instanceID] = nil
                    self.failureGates[provider.instanceID]?.reset()
                    return
                }
            }
            let hadKnownUnavailableLimits = self.knownLimitsAvailabilityByProvider[provider.instanceID]?
                .isUnavailable == true
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
            if provider == .claude,
               ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(error.localizedDescription)
            {
                // This is a successful answer about quota availability, not a transient probe failure.
                // Drop prior limits immediately so an Education subscription notice cannot leave stale bars visible.
                self.snapshots.removeValue(forKey: provider.instanceID)
                self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
                self.clearSessionQuotaTransitionState(provider: provider)
                self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider }
                self.lastSourceLabels.removeValue(forKey: provider.instanceID)
                self.errors[provider.instanceID] = nil
                self.knownLimitsAvailabilityByProvider[provider.instanceID] = .unavailable
                self.widgetUsagePreservationBlockedProviders.insert(provider.instanceID)
                self.failureGates[provider.instanceID]?.reset()
                return
            }
            if provider == .claude,
               hadKnownUnavailableLimits,
               Self.shouldPreservePriorSnapshot(after: error, hadPriorData: true) ||
               Self.isClaudeCLIRateLimitFailure(error)
            {
                self.errors[provider.instanceID] = nil
                self.knownLimitsAvailabilityByProvider[provider.instanceID] = .unavailable
                return
            }
            let hadPriorData = self.snapshots[provider.instanceID] != nil
            let isTerminalClaudeCLIParseFailure =
                provider == .claude &&
                hadPriorData &&
                Self.lastAvailableFailedFetchKind(from: attempts) == .cli &&
                Self.isClaudeCLIUsageParseFailure(error)
            let preservesPriorData = Self.shouldPreservePriorSnapshot(
                after: error,
                hadPriorData: hadPriorData) ||
                (provider == .claude &&
                    hadPriorData &&
                    (Self.isClaudeCLIRateLimitFailure(error) ||
                        isTerminalClaudeCLIParseFailure))
            let shouldSurface =
                self.failureGates[provider.instanceID]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
            let preservesClaudeWebSessionFailure =
                provider == .claude &&
                hadPriorData &&
                Self.isClaudeWebSessionRefreshFailure(error)
            if preservesClaudeWebSessionFailure,
               !shouldSurface
            {
                self.errors[provider.instanceID] = nil
                return
            }
            if provider == .claude,
               preservesPriorData,
               Self.isClaudeUsageProbeTimeout(error) || Self.isClaudeCLIRateLimitFailure(error)
            {
                self.errors[provider.instanceID] = nil
                return
            }
            if preservesPriorData, !shouldSurface {
                self.errors[provider.instanceID] = nil
                return
            }
            if shouldSurface {
                self.errors[provider.instanceID] = error.localizedDescription
                if !preservesPriorData, !preservesClaudeWebSessionFailure {
                    self.snapshots.removeValue(forKey: provider.instanceID)
                    if Self.tokenCostRequiresProviderSnapshot(provider) {
                        self.clearTokenSnapshot(for: provider)
                    }
                }
                self.emitHook(
                    .refreshFailed,
                    provider: provider,
                    status: Self.refreshFailureHookStatus(error))
            } else {
                self.errors[provider.instanceID] = nil
            }
            if shouldNotifyPermissionPrompt {
                self.postPermissionPromptNotificationIfNeeded(provider: provider, error: error)
            }
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: context.generation) else { return }
        if let runtime = self.providerRuntimes[provider.instanceID] {
            let context = ProviderRuntimeContext(
                provider: provider, settings: self.settings, store: self)
            runtime.providerDidFail(context: context, provider: provider, error: error)
        }
    }

    private func validatedClaudeOAuthTokenAccountFallback(
        context: ProviderRefreshOutcomeContext) -> (ProviderTokenAccount, TokenAccountUsageSnapshot)?
    {
        guard let fetchedAccount = context.tokenAccount,
              let cached = context.priorTokenAccountSnapshot,
              cached.account.id == fetchedAccount.id,
              cached.sourceLabel == "oauth",
              cached.snapshot != nil,
              let currentAccount = self.uniqueTokenAccount(provider: .claude, accountID: fetchedAccount.id),
              cached.cacheKey == self.tokenAccountSnapshotCacheKey(provider: .claude, account: currentAccount)
        else {
            return nil
        }
        return (currentAccount, cached)
    }

    private func tokenAccountSnapshot(
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> TokenAccountUsageSnapshot?
    {
        guard let account else { return nil }
        return self.accountSnapshots[provider.instanceID]?.first { cached in
            cached.account.id == account.id &&
                cached.cacheKey == self.tokenAccountSnapshotCacheKey(provider: provider, account: account)
        }
    }

    private static func shouldPreservePriorSnapshot(after error: Error, hadPriorData: Bool) -> Bool {
        guard hadPriorData else { return false }
        if error is CancellationError {
            return true
        }
        if self.isPreservableNetworkTransportError(error) {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") ||
            message.contains("timeout") ||
            message.contains("cancelled") ||
            message.contains("network connection was lost") ||
            message.contains("not connected to the internet")
    }

    private static func lastAvailableFailedFetchKind(from attempts: [ProviderFetchAttempt]) -> ProviderFetchKind? {
        attempts.last { attempt in
            attempt.wasAvailable && attempt.errorDescription != nil
        }?.kind
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
        if error is CancellationError {
            return false
        }

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
        if case ClaudeStatusProbeError.timedOut = error {
            return true
        }
        return error.localizedDescription == ClaudeStatusProbeError.timedOut.localizedDescription
    }

    private static func isClaudeCLIRateLimitFailure(_ error: Error) -> Bool {
        ClaudeUsageFetcher.isCLIRateLimitError(error)
    }

    private static func isClaudeCLIUsageParseFailure(_ error: Error) -> Bool {
        if case let ClaudeStatusProbeError.parseFailed(message) = error {
            return !ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(message)
        }
        if case let ClaudeUsageError.parseFailed(message) = error {
            return !ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(message)
        }
        return false
    }

    private static func isClaudeWebSessionRefreshFailure(_ error: Error) -> Bool {
        if case ClaudeWebAPIFetcher.FetchError.unauthorized = error {
            return true
        }
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
        if let last = self.lastPermissionPromptNotificationAt[provider.instanceID],
           now.timeIntervalSince(last) < 10 * 60
        {
            return
        }
        self.lastPermissionPromptNotificationAt[provider.instanceID] = now
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        AppNotifications.shared.post(
            idPrefix: "permission-prompt-\(provider.rawValue)",
            title: L("%@ is waiting for permission", providerName),
            body: error.localizedDescription,
            soundEnabled: false)
    }
}
