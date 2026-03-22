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
    /// Codex multi-account support is built by reusing the shared token-account pipeline:
    /// fetch once per stored account, keep the resulting snapshots separate, and let the
    /// menu render multiple account cards at the same time instead of collapsing Codex
    /// into a single usage view.
    private static let tokenAccountFetchConcurrencyLimit = 5

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
        return self.settings.tokenAccounts(for: provider)
    }

    func shouldFetchAllTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) -> Bool {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return false }
        return self.settings.showAllTokenAccountsInMenu && accounts.count > 1
    }

    func refreshTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) async {
        let selectedAccount = self.settings.selectedTokenAccount(for: provider)
        let limitedAccounts = self.limitedTokenAccounts(accounts, selected: selectedAccount)
        let effectiveSelected = selectedAccount ?? limitedAccounts.first

        var snapshotsByID: [UUID: TokenAccountUsageSnapshot] = [:]

        if let effectiveSelected {
            let override = TokenAccountOverride(provider: provider, account: effectiveSelected)
            let outcome = await self.fetchOutcome(provider: provider, override: override)
            let resolved = self.resolveAccountOutcome(outcome, provider: provider, account: effectiveSelected)
            snapshotsByID[effectiveSelected.id] = resolved.snapshot
            await self.applySelectedOutcome(
                outcome,
                provider: provider,
                account: effectiveSelected,
                fallbackSnapshot: resolved.usage)
        }

        let remainingAccounts = limitedAccounts.filter { $0.id != effectiveSelected?.id }
        if !remainingAccounts.isEmpty {
            let additionalSnapshots = await self.fetchTokenAccountSnapshotsInBatches(
                provider: provider,
                accounts: remainingAccounts,
                maxConcurrent: Self.tokenAccountFetchConcurrencyLimit)
            for (accountID, snapshot) in additionalSnapshots {
                snapshotsByID[accountID] = snapshot
            }
        }

        let orderedSnapshots = limitedAccounts.compactMap { snapshotsByID[$0.id] }
        await MainActor.run {
            self.accountSnapshots[provider] = orderedSnapshots
        }
    }

    func fetchOutcome(
        provider: UsageProvider,
        override: TokenAccountOverride?) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let sourceMode: ProviderSourceMode = if provider == .codex, override != nil {
            .web
        } else {
            self.sourceMode(for: provider)
        }
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: self.settings, tokenOverride: override)
        let env = ProviderRegistry.makeEnvironment(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            settings: self.settings,
            tokenOverride: override)
        let verbose = self.settings.isVerboseLoggingEnabled
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: verbose,
            env: env,
            settings: snapshot,
            fetcher: self.codexFetcher,
            claudeFetcher: self.claudeFetcher,
            browserDetection: self.browserDetection)
        return await descriptor.fetchOutcome(context: context)
    }

    func sourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        ProviderCatalog.implementation(for: provider)?
            .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: self.settings))
            ?? .auto
    }

    @MainActor
    func applyCachedTokenAccountSnapshot(provider: UsageProvider, accountID: UUID?) {
        guard let accountID,
              let cached = self.accountSnapshots[provider]?.first(where: { $0.account.id == accountID })
        else {
            return
        }

        if let snapshot = cached.snapshot {
            self.handleSessionQuotaTransition(provider: provider, snapshot: snapshot)
            self.snapshots[provider] = snapshot
            self.lastSourceLabels[provider] = cached.sourceLabel
            self.errors[provider] = nil
            self.failureGates[provider]?.recordSuccess()
        } else if let error = cached.error, !error.isEmpty {
            self.errors[provider] = error
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
            await MainActor.run {
                self.handleSessionQuotaTransition(provider: provider, snapshot: labeled)
                self.snapshots[provider] = labeled
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
            }
        case let .failure(error):
            await MainActor.run {
                let hadPriorData = self.snapshots[provider] != nil || fallbackSnapshot != nil
                let shouldSurface = self.failureGates[provider]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
                if shouldSurface {
                    self.errors[provider] = error.localizedDescription
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

        let parsed = CodexAccountLabel.parse(label)

        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = existing?.accountOrganization?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? (parsed.email ?? label) : email
        let resolvedOrganization = (organization?.isEmpty ?? true) ? parsed.workspace : organization
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: resolvedEmail,
            accountOrganization: resolvedOrganization,
            loginMethod: existing?.loginMethod)
        return snapshot.withIdentity(identity)
    }
}
