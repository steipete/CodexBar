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

struct CodexAccountUsageSnapshot: Identifiable {
    let id: String
    let account: CodexVisibleAccount
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?

    init(account: CodexVisibleAccount, snapshot: UsageSnapshot?, error: String?, sourceLabel: String?) {
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
        return self.settings.multiAccountMenuLayout == .stacked && accounts.count > 1
    }

    func shouldFetchAllCodexVisibleAccounts() -> Bool {
        self.settings.multiAccountMenuLayout == .stacked &&
            self.settings.codexVisibleAccountProjection.visibleAccounts.count > 1
    }

    func refreshCodexVisibleAccountsForMenu() async {
        let projection = self.settings.codexVisibleAccountProjection
        let accounts = self.limitedCodexVisibleAccounts(
            projection.visibleAccounts,
            activeVisibleAccountID: projection.activeVisibleAccountID)
        guard accounts.count > 1 else {
            self.codexAccountSnapshots = []
            return
        }

        let originalSource = self.settings.codexActiveSource
        let originalVisibleAccountID = projection.activeVisibleAccountID
        let priorByAccountID = Dictionary(uniqueKeysWithValues: self.codexAccountSnapshots.map { ($0.id, $0) })
        var snapshots: [CodexAccountUsageSnapshot] = []
        var selectedOutcome: ProviderFetchOutcome?
        var selectedSnapshot: UsageSnapshot?
        var selectedSourceLabel: String?
        var sawAnyNonCancellationOutcome = false

        let restoreOriginalSelection = {
            var restoredSelection = false
            if let originalVisibleAccountID,
               self.settings.selectCodexVisibleAccount(id: originalVisibleAccountID)
            {
                restoredSelection = true
            }
            if !restoredSelection {
                self.settings.codexActiveSource = originalSource
            }
        }
        defer { restoreOriginalSelection() }

        for account in accounts {
            guard self.settings.selectCodexVisibleAccount(id: account.id) else { continue }
            let outcome = await self.fetchOutcome(provider: .codex, override: nil)
            let isCancellation = Self.outcomeIsCancellation(outcome)
            if !isCancellation {
                sawAnyNonCancellationOutcome = true
            }
            let resolved = self.resolveCodexAccountOutcome(
                outcome,
                account: account,
                priorSnapshot: priorByAccountID[account.id])
            if let snapshot = resolved.snapshot {
                snapshots.append(snapshot)
            }
            if account.id == originalVisibleAccountID {
                selectedOutcome = outcome
                selectedSnapshot = resolved.usage
                selectedSourceLabel = resolved.sourceLabel
            }
        }

        let shouldPreservePriorState = !sawAnyNonCancellationOutcome &&
            snapshots.allSatisfy { $0.snapshot == nil }
        if !shouldPreservePriorState {
            self.codexAccountSnapshots = snapshots
        }

        restoreOriginalSelection()
        if let selectedOutcome {
            await self.applySelectedCodexVisibleAccountOutcome(
                selectedOutcome,
                snapshot: selectedSnapshot,
                sourceLabel: selectedSourceLabel)
        }
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
        if case let .failure(error) = outcome.result {
            return self.errorIsCancellation(error)
        }
        return false
    }

    private static func errorIsCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return message == "cancelled" ||
            message.contains("cancellationerror") ||
            message.contains("cancelled")
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

    func limitedCodexVisibleAccounts(
        _ accounts: [CodexVisibleAccount],
        activeVisibleAccountID: String?) -> [CodexVisibleAccount]
    {
        let limit = Self.tokenAccountMenuSnapshotLimit
        if accounts.count <= limit { return accounts }
        var limited = Array(accounts.prefix(limit))
        if let activeVisibleAccountID,
           let active = accounts.first(where: { $0.id == activeVisibleAccountID }),
           !limited.contains(where: { $0.id == activeVisibleAccountID })
        {
            limited.removeLast()
            limited.append(active)
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

    private struct ResolvedCodexAccountOutcome {
        let snapshot: CodexAccountUsageSnapshot?
        let usage: UsageSnapshot?
        let sourceLabel: String?
    }

    func tokenAccountErrorMessage(_ error: any Error) -> String? {
        guard !Self.errorIsCancellation(error) else { return nil }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// Per-account snapshot error text. Cancellation is handled before this path so
    /// transient menu refresh cancellation does not render as a user-facing error.
    func tokenAccountSnapshotErrorMessage(_ error: any Error) -> String {
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
            if Self.errorIsCancellation(error) {
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

    private func resolveCodexAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        account: CodexVisibleAccount,
        priorSnapshot: CodexAccountUsageSnapshot? = nil) -> ResolvedCodexAccountOutcome
    {
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: .codex)
            let labeled = self.applyCodexVisibleAccountLabel(scoped, account: account)
            let snapshot = CodexAccountUsageSnapshot(
                account: account,
                snapshot: labeled,
                error: nil,
                sourceLabel: result.sourceLabel)
            return ResolvedCodexAccountOutcome(
                snapshot: snapshot,
                usage: labeled,
                sourceLabel: result.sourceLabel)
        case let .failure(error):
            if Self.errorIsCancellation(error) {
                if let priorSnapshot, priorSnapshot.snapshot != nil {
                    return ResolvedCodexAccountOutcome(
                        snapshot: priorSnapshot,
                        usage: priorSnapshot.snapshot,
                        sourceLabel: priorSnapshot.sourceLabel)
                }
                return ResolvedCodexAccountOutcome(snapshot: nil, usage: nil, sourceLabel: nil)
            }
            let snapshot = CodexAccountUsageSnapshot(
                account: account,
                snapshot: nil,
                error: self.tokenAccountSnapshotErrorMessage(error),
                sourceLabel: nil)
            return ResolvedCodexAccountOutcome(snapshot: snapshot, usage: nil, sourceLabel: nil)
        }
    }

    func applySelectedCodexVisibleAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        snapshot: UsageSnapshot?,
        sourceLabel: String?) async
    {
        self.lastFetchAttempts[.codex] = outcome.attempts
        switch outcome.result {
        case .success:
            guard let snapshot else { return }
            let backfilled = snapshot.backfillingResetTimes(from: self.lastKnownResetSnapshots[.codex])
            self.handleSessionQuotaTransition(provider: .codex, snapshot: backfilled)
            self.lastKnownResetSnapshots[.codex] = backfilled
            self.snapshots[.codex] = backfilled
            if let sourceLabel {
                self.lastSourceLabels[.codex] = sourceLabel
            }
            self.errors[.codex] = nil
            self.failureGates[.codex]?.recordSuccess()
            self.rememberLiveSystemCodexEmailIfNeeded(backfilled.accountEmail(for: .codex))
            self.seedCodexAccountScopedRefreshGuard(accountEmail: backfilled.accountEmail(for: .codex))
            await self.recordPlanUtilizationHistorySample(provider: .codex, snapshot: backfilled)
            self.recordCodexHistoricalSampleIfNeeded(snapshot: backfilled)
        case let .failure(error):
            guard let message = self.tokenAccountErrorMessage(error) else {
                self.errors[.codex] = nil
                return
            }
            let hadPriorData = self.snapshots[.codex] != nil
            let shouldSurface =
                self.failureGates[.codex]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
            if shouldSurface {
                self.errors[.codex] = message
                self.snapshots.removeValue(forKey: .codex)
            } else {
                self.errors[.codex] = nil
            }
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

    func applyCodexVisibleAccountLabel(_ snapshot: UsageSnapshot, account: CodexVisibleAccount) -> UsageSnapshot {
        let existing = snapshot.identity(for: .codex)
        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? account.email : email
        let loginMethod = existing?.loginMethod ?? account.workspaceLabel
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: resolvedEmail,
            accountOrganization: existing?.accountOrganization,
            loginMethod: loginMethod)
        return snapshot.withIdentity(identity)
    }
}
