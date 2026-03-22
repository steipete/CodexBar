import CodexBarCore
import Foundation

struct TokenAccountUsageSnapshot: Identifiable, Sendable {
    let id: UUID
    let account: ProviderTokenAccount
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?
    let credits: CreditsSnapshot?
    let dashboard: OpenAIDashboardSnapshot?

    init(
        account: ProviderTokenAccount,
        snapshot: UsageSnapshot?,
        error: String?,
        sourceLabel: String?,
        credits: CreditsSnapshot? = nil,
        dashboard: OpenAIDashboardSnapshot? = nil)
    {
        self.id = account.id
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
        self.credits = credits
        self.dashboard = dashboard
    }
}

extension UsageStore {
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
        let prioritizedAccounts = self.prioritizedTokenAccounts(limitedAccounts, selected: effectiveSelected)
        var snapshotsByAccountID: [UUID: TokenAccountUsageSnapshot] = [:]

        for account in prioritizedAccounts {
            let override = TokenAccountOverride(provider: provider, account: account)
            let initialOutcome = await self.fetchOutcome(provider: provider, override: override)
            let outcome = await self.repairTokenAccountOutcomeIfNeeded(
                initialOutcome,
                provider: provider,
                account: account)
            let resolved = self.resolveAccountOutcome(outcome, provider: provider, account: account)
            snapshotsByAccountID[account.id] = resolved.snapshot
            if account.id == effectiveSelected?.id {
                await self.applySelectedOutcome(
                    outcome,
                    provider: provider,
                    account: effectiveSelected,
                    fallbackSnapshot: resolved.usage)
            } else {
                await MainActor.run {
                    self.upsertTokenAccountSnapshot(
                        provider: provider,
                        account: account,
                        snapshot: resolved.snapshot.snapshot,
                        error: resolved.snapshot.error,
                        sourceLabel: resolved.snapshot.sourceLabel,
                        credits: resolved.snapshot.credits,
                        dashboard: resolved.snapshot.dashboard)
                }
            }
        }

        await MainActor.run {
            let orderedSnapshots = limitedAccounts.compactMap { snapshotsByAccountID[$0.id] }
            if !orderedSnapshots.isEmpty {
                self.accountSnapshots[provider] = orderedSnapshots
            }
        }
    }

    func limitedTokenAccounts(
        _ accounts: [ProviderTokenAccount],
        selected: ProviderTokenAccount?) -> [ProviderTokenAccount]
    {
        let limit = 6
        if accounts.count <= limit { return accounts }
        var limited = Array(accounts.prefix(limit))
        if let selected, !limited.contains(where: { $0.id == selected.id }) {
            limited.removeLast()
            limited.append(selected)
        }
        return limited
    }

    func prioritizedTokenAccounts(
        _ accounts: [ProviderTokenAccount],
        selected: ProviderTokenAccount?) -> [ProviderTokenAccount]
    {
        guard let selected else { return accounts }
        guard let selectedIndex = accounts.firstIndex(where: { $0.id == selected.id }) else { return accounts }
        if selectedIndex == 0 { return accounts }

        var prioritized = accounts
        prioritized.remove(at: selectedIndex)
        prioritized.insert(selected, at: 0)
        return prioritized
    }

    func fetchOutcome(
        provider: UsageProvider,
        override: TokenAccountOverride?) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let sourceMode = self.sourceMode(for: provider, override: override)
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

    func sourceMode(for provider: UsageProvider, override: TokenAccountOverride? = nil) -> ProviderSourceMode {
        if provider == .codex,
           let account = ProviderTokenAccountSelection.selectedAccount(
               provider: provider,
               settings: self.settings,
               override: override),
           (try? CodexOAuthCredentialsStore.load(rawSource: account.token)) != nil
        {
            return .oauth
        }

        if let support = TokenAccountSupportCatalog.support(for: provider),
           support.requiresManualCookieSource,
           override != nil || self.settings.selectedTokenAccount(for: provider) != nil
        {
            return .web
        }

        return ProviderCatalog.implementation(for: provider)?
            .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: self.settings))
            ?? .auto
    }

    private func repairTokenAccountOutcomeIfNeeded(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount) async -> ProviderFetchOutcome
    {
        guard provider == .codex,
              self.settings.codexCookieSource == .manual,
              ProviderInteractionContext.current == .userInitiated,
              case .failure = outcome.result
        else {
            return outcome
        }

        if (try? CodexOAuthCredentialsStore.load(rawSource: account.token)) != nil {
            return outcome
        }

        guard let targetEmail = self.tokenAccountEmailHint(provider: provider, account: account),
              !targetEmail.isEmpty
        else {
            return outcome
        }

        let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: self.browserDetection)

        do {
            let result = try await importer.importBestCookies(
                intoAccountEmail: targetEmail,
                allowAnyAccount: false)
            guard let cookieHeader = result.cookieHeader,
                  !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return outcome
            }

            await MainActor.run {
                self.settings.updateTokenAccount(provider: provider, accountID: account.id, token: cookieHeader)
            }

            let updatedAccount = await MainActor.run {
                self.settings.tokenAccounts(for: provider).first(where: { $0.id == account.id })
            } ?? account
            let override = TokenAccountOverride(provider: provider, account: updatedAccount)
            return await self.fetchOutcome(provider: provider, override: override)
        } catch {
            return outcome
        }
    }

    private func tokenAccountEmailHint(provider: UsageProvider, account: ProviderTokenAccount) -> String? {
        if let cached = self.tokenAccountUsageSnapshot(provider: provider, accountID: account.id) {
            if let signedInEmail = cached.dashboard?.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !signedInEmail.isEmpty
            {
                return signedInEmail
            }
            if let email = cached.snapshot?.identity(for: provider)?.accountEmail?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !email.isEmpty
            {
                return email
            }
        }

        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.contains("@") {
            return label
        }

        return nil
    }

    private struct ResolvedAccountOutcome {
        let snapshot: TokenAccountUsageSnapshot
        let usage: UsageSnapshot?
        let credits: CreditsSnapshot?
        let dashboard: OpenAIDashboardSnapshot?
    }

    private func resolveAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> ResolvedAccountOutcome
    {
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let labeled = self.applyAccountLabel(scoped, provider: provider, account: account)
            let credits = result.credits ?? result.dashboard?.toCreditsSnapshot()
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: labeled,
                error: nil,
                sourceLabel: result.sourceLabel,
                credits: credits,
                dashboard: result.dashboard)
            return ResolvedAccountOutcome(
                snapshot: snapshot,
                usage: labeled,
                credits: credits,
                dashboard: result.dashboard)
        case let .failure(error):
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: nil,
                error: error.localizedDescription,
                sourceLabel: nil)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: nil, credits: nil, dashboard: nil)
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
            let credits = result.credits ?? result.dashboard?.toCreditsSnapshot()
            let labeled: UsageSnapshot = if let account {
                self.applyAccountLabel(scoped, provider: provider, account: account)
            } else {
                scoped
            }
            await MainActor.run {
                if let account {
                    self.upsertTokenAccountSnapshot(
                        provider: provider,
                        account: account,
                        snapshot: labeled,
                        error: nil,
                        sourceLabel: result.sourceLabel,
                        credits: credits,
                        dashboard: result.dashboard)
                }
                self.handleSessionQuotaTransition(provider: provider, snapshot: labeled)
                self.snapshots[provider] = labeled
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
                self.applyProviderSupplementaryData(
                    provider: provider,
                    credits: credits,
                    dashboard: result.dashboard,
                    preserveExisting: true)
            }
        case let .failure(error):
            await MainActor.run {
                let selectedAccountID = self.settings.selectedTokenAccount(for: provider)?.id
                let isSelectedTokenAccountFailure = account?.id == selectedAccountID
                if let account {
                    self.upsertTokenAccountSnapshot(
                        provider: provider,
                        account: account,
                        snapshot: nil,
                        error: error.localizedDescription,
                        sourceLabel: nil,
                        credits: nil,
                        dashboard: nil)
                }
                let hadPriorData = self.snapshots[provider] != nil || fallbackSnapshot != nil
                let shouldSurface = self.failureGates[provider]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
                if shouldSurface || isSelectedTokenAccountFailure {
                    self.errors[provider] = error.localizedDescription
                    self.snapshots.removeValue(forKey: provider)
                    self.applyProviderSupplementaryData(
                        provider: provider,
                        credits: nil,
                        dashboard: nil,
                        preserveExisting: false)
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

    func upsertTokenAccountSnapshot(
        provider: UsageProvider,
        account: ProviderTokenAccount,
        snapshot: UsageSnapshot?,
        error: String?,
        sourceLabel: String?,
        credits: CreditsSnapshot?,
        dashboard: OpenAIDashboardSnapshot?)
    {
        let entry = TokenAccountUsageSnapshot(
            account: account,
            snapshot: snapshot,
            error: error,
            sourceLabel: sourceLabel,
            credits: credits,
            dashboard: dashboard)
        var snapshots = self.accountSnapshots[provider] ?? []
        if let index = snapshots.firstIndex(where: { $0.account.id == account.id }) {
            snapshots[index] = entry
        } else {
            snapshots.append(entry)
        }
        self.accountSnapshots[provider] = snapshots
    }

    func tokenAccountUsageSnapshot(provider: UsageProvider, accountID: UUID) -> TokenAccountUsageSnapshot? {
        self.accountSnapshots[provider]?
            .first(where: { $0.account.id == accountID })
    }

    func applyCachedTokenAccountState(provider: UsageProvider, accountID: UUID) {
        guard let cached = self.tokenAccountUsageSnapshot(provider: provider, accountID: accountID) else {
            self.snapshots.removeValue(forKey: provider)
            self.errors.removeValue(forKey: provider)
            self.applyProviderSupplementaryData(
                provider: provider,
                credits: nil,
                dashboard: nil,
                preserveExisting: false)
            return
        }

        if let snapshot = cached.snapshot {
            self.snapshots[provider] = snapshot
            self.errors[provider] = nil
        } else {
            self.snapshots.removeValue(forKey: provider)
            if let error = cached.error, !error.isEmpty {
                self.errors[provider] = error
            } else {
                self.errors.removeValue(forKey: provider)
            }
        }

        self.applyProviderSupplementaryData(
            provider: provider,
            credits: cached.credits,
            dashboard: cached.dashboard,
            preserveExisting: false)
    }
}
