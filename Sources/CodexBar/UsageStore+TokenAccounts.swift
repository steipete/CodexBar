import CodexBarCore
import Foundation

struct TokenAccountUsageSnapshot: Identifiable {
    let id: UUID
    let account: ProviderTokenAccount
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?

    init(account: ProviderTokenAccount, snapshot: UsageSnapshot?, error: String?, sourceLabel: String?) {
        self.id = account.id
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
    }
}

extension UsageStore {
    static let tokenAccountMenuSnapshotLimit = 6

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
        return self.settings.tokenAccounts(for: provider)
    }

    func shouldFetchAllTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) -> Bool {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return false }
        if provider == .copilot {
            return accounts.count > 1
        }
        return self.settings.showAllTokenAccountsInMenu && accounts.count > 1
    }

    func refreshTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) async {
        let selectedAccount = self.settings.selectedTokenAccount(for: provider)
        let limitedAccounts = self.limitedTokenAccounts(accounts, selected: selectedAccount)
        let effectiveSelected = selectedAccount ?? limitedAccounts.first

        // Capture the prior per-account snapshot state so we can preserve last-good
        // data when an in-flight refresh is cancelled (e.g. menu tab switches). Without
        // this, cancellation produces empty/error snapshots and the menu briefly shows
        // misleading cards for accounts that previously had valid data.
        let priorSnapshots = await MainActor.run { self.accountSnapshots[provider] ?? [] }
        let priorByAccountID = Dictionary(uniqueKeysWithValues: priorSnapshots.map { ($0.account.id, $0) })

        var snapshots: [TokenAccountUsageSnapshot] = []
        var historySamples: [(account: ProviderTokenAccount, snapshot: UsageSnapshot)] = []
        var selectedOutcome: ProviderFetchOutcome?
        var selectedSnapshot: UsageSnapshot?
        var sawAnyNonCancellationOutcome = false

        for account in limitedAccounts {
            let override = TokenAccountOverride(provider: provider, account: account)
            let outcome = await self.fetchOutcome(provider: provider, override: override)
            let isCancellation = Self.outcomeIsCancellation(outcome)
            if !isCancellation {
                sawAnyNonCancellationOutcome = true
            }
            let resolved = self.resolveAccountOutcome(
                outcome,
                provider: provider,
                account: account,
                priorSnapshot: priorByAccountID[account.id])
            if let snapshot = resolved.snapshot {
                snapshots.append(snapshot)
            }
            if let usage = resolved.usage {
                historySamples.append((account: account, snapshot: usage))
            }
            if account.id == effectiveSelected?.id {
                selectedOutcome = outcome
                selectedSnapshot = resolved.usage
            }
        }

        // If every fetch was cancelled (e.g. the user closed/reopened the menu mid-flight)
        // and we have no usable snapshots, leave the prior per-account state alone.
        // Wiping it would produce a menu of useless "cancelled" placeholders.
        let shouldPreservePriorState = !sawAnyNonCancellationOutcome &&
            snapshots.allSatisfy { $0.snapshot == nil }
        if !shouldPreservePriorState {
            await MainActor.run {
                self.accountSnapshots[provider] = snapshots
            }
        }

        if let selectedOutcome {
            await self.applySelectedOutcome(
                selectedOutcome,
                provider: provider,
                account: effectiveSelected,
                fallbackSnapshot: selectedSnapshot)
        }

        await self.recordFetchedTokenAccountPlanUtilizationHistory(
            provider: provider,
            samples: historySamples,
            selectedAccount: effectiveSelected)
    }

    private static func outcomeIsCancellation(_ outcome: ProviderFetchOutcome) -> Bool {
        if case let .failure(error) = outcome.result, error is CancellationError {
            return true
        }
        return false
    }

    func limitedTokenAccounts(
        _ accounts: [ProviderTokenAccount],
        selected: ProviderTokenAccount?) -> [ProviderTokenAccount]
    {
        let limit = Self.tokenAccountMenuSnapshotLimit
        if accounts.count <= limit { return accounts }
        var limited = Array(accounts.prefix(limit))
        if let selected, !limited.contains(where: { $0.id == selected.id }) {
            limited.removeLast()
            limited.append(selected)
        }
        return limited
    }

    func fetchOutcome(
        provider: UsageProvider,
        override: TokenAccountOverride?) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let context = self.makeFetchContext(provider: provider, override: override)
        return await descriptor.fetchOutcome(context: context)
    }

    func makeFetchContext(
        provider: UsageProvider,
        override: TokenAccountOverride?) -> ProviderFetchContext
    {
        let sourceMode = self.sourceMode(for: provider)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: self.settings, tokenOverride: override)
        let env = ProviderRegistry.makeEnvironment(
            base: self.environmentBase,
            provider: provider,
            settings: self.settings,
            tokenOverride: override)
        let fetcher = ProviderRegistry.makeFetcher(base: self.codexFetcher, provider: provider, env: env)
        let verbose = self.settings.isVerboseLoggingEnabled
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: verbose,
            env: env,
            settings: snapshot,
            fetcher: fetcher,
            claudeFetcher: self.claudeFetcher,
            browserDetection: self.browserDetection)
    }

    func sourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        ProviderCatalog.implementation(for: provider)?
            .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: self.settings))
            ?? .auto
    }

    private struct ResolvedAccountOutcome {
        let snapshot: TokenAccountUsageSnapshot?
        let usage: UsageSnapshot?
    }

    func tokenAccountErrorMessage(_ error: any Error) -> String? {
        guard !(error is CancellationError) else { return nil }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// Per-account snapshot error text. Unlike ``tokenAccountErrorMessage``,
    /// cancellations are preserved as a non-empty marker so the menu does not
    /// silently fall back to the live (selected-account) snapshot when an
    /// individual account refresh is cancelled.
    func tokenAccountSnapshotErrorMessage(_ error: any Error) -> String {
        if error is CancellationError {
            return "Refresh cancelled"
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Refresh failed" : message
    }

    func recordFetchedTokenAccountPlanUtilizationHistory(
        provider: UsageProvider,
        samples: [(account: ProviderTokenAccount, snapshot: UsageSnapshot)],
        selectedAccount: ProviderTokenAccount?) async
    {
        for sample in samples where sample.account.id != selectedAccount?.id {
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: sample.snapshot,
                account: sample.account,
                shouldUpdatePreferredAccountKey: false,
                shouldAdoptUnscopedHistory: false)
        }
    }

    private func resolveAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount,
        priorSnapshot: TokenAccountUsageSnapshot? = nil) -> ResolvedAccountOutcome
    {
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let labeled = self.applyAccountLabel(scoped, provider: provider, account: account)
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: labeled,
                error: nil,
                sourceLabel: result.sourceLabel)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: labeled)
        case let .failure(error):
            // Preserve the last-good snapshot when the refresh was cancelled (e.g. the
            // user switched menu tabs mid-flight). Without this the per-account list
            // would briefly render error chips for accounts that already had data.
            if error is CancellationError {
                if let priorSnapshot, priorSnapshot.snapshot != nil {
                    return ResolvedAccountOutcome(snapshot: priorSnapshot, usage: priorSnapshot.snapshot)
                }
                // No usable prior data: skip this row entirely. The caller will
                // either preserve the existing per-account state or fall back to
                // the single live card. Rendering a "cancelled" placeholder here
                // produces visually duplicate cards with no useful data.
                return ResolvedAccountOutcome(snapshot: nil, usage: nil)
            }
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: nil,
                error: self.tokenAccountSnapshotErrorMessage(error),
                sourceLabel: nil)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: nil)
        }
    }

    func applySelectedOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        fallbackSnapshot: UsageSnapshot?) async
    {
        await MainActor.run {
            self.lastFetchAttempts[provider] = outcome.attempts
        }
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let labeled: UsageSnapshot = if let account {
                self.applyAccountLabel(scoped, provider: provider, account: account)
            } else {
                scoped
            }
            let backfilled = await MainActor.run {
                let backfilled = labeled.backfillingResetTimes(from: self.lastKnownResetSnapshots[provider])
                self.handleQuotaWarningTransitions(provider: provider, snapshot: backfilled)
                self.handleSessionQuotaTransition(provider: provider, snapshot: backfilled)
                self.lastKnownResetSnapshots[provider] = backfilled
                self.snapshots[provider] = backfilled
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
                return backfilled
            }
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: backfilled,
                account: account)
        case let .failure(error):
            await MainActor.run {
                guard let message = self.tokenAccountErrorMessage(error) else {
                    self.errors[provider] = nil
                    return
                }
                let hadPriorData = self.snapshots[provider] != nil || fallbackSnapshot != nil
                let shouldSurface = self.failureGates[provider]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
                if shouldSurface {
                    self.errors[provider] = message
                    self.snapshots.removeValue(forKey: provider)
                } else {
                    self.errors[provider] = nil
                }
            }
        }
    }

    func applyAccountLabel(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> UsageSnapshot
    {
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return snapshot }
        let existing = snapshot.identity(for: provider)
        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? label : email
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: resolvedEmail,
            accountOrganization: existing?.accountOrganization,
            loginMethod: existing?.loginMethod)
        return snapshot.withIdentity(identity)
    }
}
