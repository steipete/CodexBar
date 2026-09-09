import CodexBarCore
import Foundation

// Provider-specific by design: Hugging Face's browser-session prepaid wallet is one provider-level
// value. These helpers own its deterministic publication, configuration-driven clearing, and the
// stacked-batch attribution post-pass. The wallet is never cached as a token-account snapshot.

struct HuggingFaceWalletAttributionReconciliation {
    let results: [TokenAccountFetchResult]
    let decision: HuggingFaceWalletBatchDecision
    let composedAccountID: UUID?
}

extension UsageStore {
    /// Reconciles Hugging Face's provider-level Web wallet before refresh routing branches into
    /// stacked fan-out or ordinary selected-account reconciliation. Explicit Web never displaces
    /// its own live snapshot, explicit API clears Web authority, and only Auto with an effective
    /// selected token account can begin an API replacement that may need failure recovery.
    func prepareHuggingFaceWalletRefresh(
        provider: UsageProvider,
        context: ProviderFetchContext,
        selectedTokenAccount: ProviderTokenAccount?)
    {
        self.reconcileHuggingFaceWalletEligibility(provider: provider, context: context)
        guard provider == .huggingface,
              context.sourceMode == .auto,
              selectedTokenAccount != nil
        else { return }
        self.beginHuggingFaceWebSnapshotDisplacement(provider: provider)
    }

    func applyHuggingFaceWalletOutcome(provider: UsageProvider, result: ProviderFetchResult) {
        // Provider-specific by design: Hugging Face publishes one provider-level browser wallet.
        guard provider == .huggingface else { return }
        // Web-kind success (explicit Web mode and cookie-only Auto): the fresh browser snapshot
        // itself owns the visible wallet. Clear the prior provider-level auxiliary publication and
        // record the observed wallet so a later failed Auto/API refresh cannot hide the validated
        // Credits behind a wallet-less cached account snapshot.
        if result.strategyKind == .web, let balance = result.usage.providerCost?.balance {
            self.huggingFaceBrowserWallets[provider.instanceID] = nil
            self.huggingFaceWebOwnedWallets[provider.instanceID] = HuggingFaceWalletSnapshot(
                balanceUSD: balance,
                observedAt: result.usage.providerCost?.balanceUpdatedAt ?? result.usage.updatedAt)
            self.huggingFaceLiveWebSnapshotOwners.insert(provider.instanceID)
            return
        }
        // API-kind success: every non-failure outcome supersedes any recorded Web-owned wallet and
        // any pending displacement. Source labels are the deterministic owner: Web-kind successes
        // keep the live-Web marker; anything else clears it. A Web-kind success that carries no
        // balance (e.g. a degraded snapshot) also clears the stale record so it can never
        // resurrect an older wallet.
        self.huggingFaceWebOwnedWallets[provider.instanceID] = nil
        self.huggingFaceLiveWebSnapshotOwners.remove(provider.instanceID)
        self.huggingFacePendingWebSnapshotDisplacement.remove(provider.instanceID)
        // Deterministic publication rules for the provider-level browser wallet:
        // composed → clear (the wallet lives on the matching account card);
        // observed → publish fresh; unavailable/notAttempted → clear. A nil outcome (API failure
        // before wallet work) makes no transition.
        switch result.huggingFaceWalletOutcome {
        case .localMatchComposed, .unavailable, .notAttempted:
            self.huggingFaceBrowserWallets[provider.instanceID] = nil
        case let .providerLevel(publication):
            self.huggingFaceBrowserWallets[provider.instanceID] = publication
        case nil:
            break
        }
    }

    /// Configuration-driven wallet clearing runs before fetch dispatch so disabling the browser
    /// authority or selecting isolated API mode removes any provider-level wallet even when the
    /// subsequent API request fails.
    func reconcileHuggingFaceWalletEligibility(provider: UsageProvider, context: ProviderFetchContext) {
        // Provider-specific by design: Hugging Face clears its provider-level browser wallet when
        // configuration makes the browser authority ineligible.
        guard provider == .huggingface else { return }
        if !HuggingFaceBrowserWalletPolicy.isWalletEligible(context) || context.sourceMode == .api {
            self.huggingFaceBrowserWallets[provider.instanceID] = nil
            self.huggingFaceWebOwnedWallets[provider.instanceID] = nil
            self.huggingFaceLiveWebSnapshotOwners.remove(provider.instanceID)
            self.huggingFacePendingWebSnapshotDisplacement.remove(provider.instanceID)
        }
    }

    /// Provider-specific by design (FP-194): a per-account Hugging Face Auto fetch can only prove a
    /// *local* bearer/browser identity match. This batch post-pass applies the shared batch-
    /// authoritative decision (`HuggingFaceWalletBatchReconciliation`) exactly once:
    ///
    /// * exactly one composed account → keep that composition, clear provider-level wallet state;
    /// * more than one composed account → strip the wallet from every account snapshot and publish
    ///   one provider-level wallet with `.multipleMatchingAccounts` attribution;
    /// * zero composed accounts → publish the fresh `.unverified` observation when one exists,
    ///   clear on attempted-and-unavailable or not-attempted outcomes, and make no transition when
    ///   every fetch failed before wallet work (no outcome payload).
    func reconcileHuggingFaceWalletAttribution(
        _ results: [TokenAccountFetchResult]) -> HuggingFaceWalletAttributionReconciliation
    {
        // Provider-specific by design: Hugging Face's wallet is one provider-level browser value.
        let walletOutcomes = results.map { result -> HuggingFaceBrowserWalletOutcome? in
            guard case let .success(fetchResult) = result.outcome.result else { return nil }
            return fetchResult.huggingFaceWalletOutcome
        }
        let reconciled = HuggingFaceWalletBatchReconciliation.reconcile(walletOutcomes)

        var rewritten = results
        if reconciled.stripsCompositions {
            // Ambiguous attribution: no account card may own the wallet. Strip every provisional
            // composition so the single browser value renders once at provider level.
            rewritten = results.map { result in
                guard case let .success(fetchResult) = result.outcome.result,
                      fetchResult.huggingFaceWalletOutcome?.isLocalMatchComposed == true
                else { return result }
                let strippedOutcome = fetchResult
                    .replacingUsage(HuggingFaceWalletBatchReconciliation.strippingWalletBalance(
                        from: fetchResult.usage))
                    .replacingSourceLabel("api")
                    .replacingWalletOutcome(nil)
                return TokenAccountFetchResult(
                    index: result.index,
                    account: result.account,
                    outcome: ProviderFetchOutcome(
                        result: .success(strippedOutcome),
                        attempts: result.outcome.attempts))
            }
        }

        // Apply the batch-authoritative publication decision. Every superseding decision also
        // clears the recorded Web-owned wallet and its live marker; only failure transitions
        // preserve them.
        switch reconciled.decision {
        case .composedOnAccount, .clear:
            self.huggingFaceBrowserWallets[.huggingface] = nil
            self.huggingFaceWebOwnedWallets[.huggingface] = nil
            self.huggingFaceLiveWebSnapshotOwners.remove(.huggingface)
            self.huggingFacePendingWebSnapshotDisplacement.remove(.huggingface)
        case let .providerLevel(publication):
            self.huggingFaceBrowserWallets[.huggingface] = publication
            self.huggingFaceWebOwnedWallets[.huggingface] = nil
            self.huggingFaceLiveWebSnapshotOwners.remove(.huggingface)
            self.huggingFacePendingWebSnapshotDisplacement.remove(.huggingface)
        case .noTransition:
            break
        }
        let composedAccountIDs = results.compactMap { result -> UUID? in
            guard case let .success(fetchResult) = result.outcome.result,
                  fetchResult.huggingFaceWalletOutcome?.isLocalMatchComposed == true
            else { return nil }
            return result.account.id
        }
        let composedAccountID: UUID? = if case .composedOnAccount = reconciled.decision,
                                          composedAccountIDs.count == 1
        {
            composedAccountIDs[0]
        } else {
            nil
        }
        return HuggingFaceWalletAttributionReconciliation(
            results: rewritten,
            decision: reconciled.decision,
            composedAccountID: composedAccountID)
    }

    /// Applies the fresh batch decision to a prior account snapshot restored after a failed fetch.
    /// A retained Hugging Face wallet is only valid when the current batch still gives that account
    /// the unique composition. Otherwise, preserve the API spend and remove the browser-wallet
    /// balance and its `api+web` attribution together.
    func reconcileHuggingFacePrior(
        _ snapshot: TokenAccountUsageSnapshot?,
        _ reconciliation: HuggingFaceWalletAttributionReconciliation?) -> TokenAccountUsageSnapshot?
    {
        guard let snapshot, let reconciliation else { return snapshot }
        let shouldStripWallet: Bool = switch reconciliation.decision {
        case .composedOnAccount:
            reconciliation.composedAccountID.map { $0 != snapshot.account.id } ?? true
        case .providerLevel, .clear:
            true
        case .noTransition:
            false
        }
        guard shouldStripWallet, snapshot.sourceLabel == "api+web" else { return snapshot }
        return TokenAccountUsageSnapshot(
            account: snapshot.account,
            snapshot: snapshot.snapshot.map(HuggingFaceWalletBatchReconciliation.strippingWalletBalance),
            error: snapshot.error,
            sourceLabel: "api",
            cacheKey: snapshot.cacheKey)
    }

    /// Provider-specific by design (FP-194): recovery publication for a failed Auto/API refresh
    /// that provably displaced the validated Web-owned live snapshot. The store records the
    /// pending displacement when the API replacement begins and only this narrow transition
    /// consumes it:
    ///
    /// * `begin` runs before token-account routing starts an Auto replacement while the recorded
    ///   Web snapshot is live: the replacement displaces
    ///   the Web-owned live snapshot by definition, so `begin` arms the pending flag;
    /// * the failure-path call publishes the recorded wallet once at provider level **only when
    ///   the pending displacement is armed**. A failed Web refresh, a cancellation, or a failure
    ///   without a recorded-and-armed pending displacement makes no transition, so the Web
    ///   snapshot can never duplicate its own wallet into auxiliary state.
    ///
    /// A successful replacement Auto/API result supersedes and clears the recovery state, and a
    /// successful later Web result owns the wallet directly.
    func beginHuggingFaceWebSnapshotDisplacement(provider: UsageProvider) {
        // Provider-specific by design: only Hugging Face's Web-owned live snapshot can pend
        // displacement for failure recovery.
        guard provider == .huggingface,
              self.huggingFaceWebOwnedWallets[provider.instanceID] != nil,
              self.huggingFaceLiveWebSnapshotOwners.contains(provider.instanceID)
        else { return }
        self.huggingFaceLiveWebSnapshotOwners.remove(provider.instanceID)
        self.huggingFacePendingWebSnapshotDisplacement.insert(provider.instanceID)
    }

    func reconcileHuggingFaceWalletAfterFetchFailure(provider: UsageProvider, error: any Error) {
        // Provider-specific by design: Hugging Face is the only provider whose browser wallet can
        // outlive a failed refresh through this recovery publication.
        guard provider == .huggingface else { return }
        guard !Self.errorIsCancellation(error) else { return }
        // Recovery requires actual displacement provenance: a pending Auto/API replacement must
        // have started while the recorded Web snapshot was live. A failed Web refresh (which
        // leaves the Web snapshot live) or an ineligible configuration never arms this.
        guard self.huggingFacePendingWebSnapshotDisplacement.remove(provider.instanceID) != nil,
              let wallet = self.huggingFaceWebOwnedWallets[provider.instanceID]
        else { return }
        self.huggingFaceBrowserWallets[provider.instanceID] = HuggingFaceBrowserWalletPublication(
            balanceUSD: wallet.balanceUSD,
            observedAt: wallet.observedAt,
            attribution: .webSession)
    }
}
