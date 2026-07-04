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
    func activateCachedTokenAccountSnapshot(provider: UsageProvider, accountID: UUID) {
        self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
        guard let cached = self.accountSnapshots[provider]?.first(where: { $0.account.id == accountID }) else {
            self.snapshots.removeValue(forKey: provider)
            self.errors.removeValue(forKey: provider)
            self.lastSourceLabels.removeValue(forKey: provider)
            self.lastKnownResetSnapshots.removeValue(forKey: provider)
            return
        }

        if let snapshot = cached.snapshot {
            self.snapshots[provider] = snapshot
            self.lastKnownResetSnapshots[provider] = snapshot
        } else {
            self.snapshots.removeValue(forKey: provider)
            self.lastKnownResetSnapshots.removeValue(forKey: provider)
        }
        self.errors[provider] = cached.error
        if let sourceLabel = cached.sourceLabel {
            self.lastSourceLabels[provider] = sourceLabel
        } else {
            self.lastSourceLabels.removeValue(forKey: provider)
        }
    }
}

private struct TokenAccountFetchResult {
    let index: Int
    let account: ProviderTokenAccount
    let outcome: ProviderFetchOutcome
}

private struct CodexAccountFetchResult {
    let index: Int
    let account: CodexVisibleAccount
    let outcome: ProviderFetchOutcome
}

private struct CodexManagedVisibleAccountRuntimeState {
    let authFingerprint: String?
    let workspaceAccountID: String?
}

extension UsageStore {
    static let tokenAccountMenuSnapshotLimit = 6
    private static let codexSessionWindowMinutes = 5 * 60
    private static let codexWeeklyWindowMinutes = 7 * 24 * 60

    func freshCodexVisibleAccountsForSnapshotHydration() -> [CodexVisibleAccount] {
        self.freshCodexVisibleAccountProjectionForAccountRefresh().visibleAccounts
    }

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
        return self.settings.tokenAccounts(for: provider)
    }

    func shouldFetchAllTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) -> Bool {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return false }
        return self.settings.multiAccountMenuLayout == .stacked && accounts.count > 1
    }

    func shouldFetchAllCodexVisibleAccounts() -> Bool {
        let projection = self.freshCodexVisibleAccountProjectionForAccountRefresh()
        return self.settings.multiAccountMenuLayout == .stacked &&
            projection.visibleAccounts.count > 1
    }

    func refreshCodexVisibleAccountsForMenu(generation: UInt64? = nil) async {
        let projection = self.freshCodexVisibleAccountProjectionForAccountRefresh()
        let accounts = self.limitedCodexVisibleAccounts(
            projection.visibleAccounts,
            snapshots: self.codexAccountSnapshots,
            activeVisibleAccountID: projection.activeVisibleAccountID)
        guard accounts.count > 1 else {
            self.codexAccountSnapshots = []
            return
        }
        let managedAccountIDsWithReadableAuthAtStart = self.codexManagedAccountIDsWithReadableAuth()

        let originalVisibleAccountID = projection.activeVisibleAccountID
        let originalSelectionSource = originalVisibleAccountID.flatMap {
            projection.source(forVisibleAccountID: $0)
        }
        let originalVisibleAccount = originalVisibleAccountID.flatMap { id in
            accounts.first { $0.id == id }
        }
        let priorByAccountID = Dictionary(uniqueKeysWithValues: self.codexAccountSnapshots.map { ($0.id, $0) })
        var snapshots: [CodexAccountUsageSnapshot] = []
        var selectedOutcome: ProviderFetchOutcome?
        var selectedAccount: CodexVisibleAccount?
        var selectedSnapshot: UsageSnapshot?
        var selectedSourceLabel: String?
        var sawAnyNonCancellationOutcome = false

        let results = await self.fetchCodexVisibleAccountOutcomes(accounts)
        for result in results {
            let account = result.account
            let outcome = result.outcome
            let isCancellation = Self.outcomeIsCancellation(outcome)
            if !isCancellation {
                sawAnyNonCancellationOutcome = true
            }
            let resolved = self.resolveCodexAccountOutcome(
                outcome,
                account: account,
                priorSnapshot: priorByAccountID[account.id],
                resetBackfillSnapshots: self.codexResetBackfillSnapshots(
                    for: account,
                    priorSnapshot: priorByAccountID[account.id],
                    activeVisibleAccountID: originalVisibleAccountID))
            if let snapshot = resolved.snapshot {
                snapshots.append(snapshot)
            }
            if account.id == originalVisibleAccountID {
                selectedOutcome = outcome
                selectedAccount = account
                selectedSnapshot = resolved.usage
                selectedSourceLabel = resolved.sourceLabel
            }
        }

        let currentProjection = self.freshCodexVisibleAccountProjectionForAccountRefresh(
            requireLiveManagedAuthFor: managedAccountIDsWithReadableAuthAtStart)
        guard self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
        let currentSnapshots = snapshots.compactMap { snapshot -> CodexAccountUsageSnapshot? in
            guard let currentAccount = Self.currentCodexVisibleAccount(
                matching: snapshot.account,
                projection: currentProjection,
                allowProviderAccountAuthFingerprintMismatch: snapshot.error == nil)
            else {
                return nil
            }
            guard currentAccount != snapshot.account else { return snapshot }
            return CodexAccountUsageSnapshot(
                account: currentAccount,
                snapshot: Self.codexVisibleAccountSnapshotRelabeledForCurrentProjection(
                    snapshot.snapshot,
                    account: currentAccount),
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
        let shouldPreservePriorState = !sawAnyNonCancellationOutcome &&
            currentSnapshots.allSatisfy { $0.snapshot == nil }
        if !shouldPreservePriorState {
            self.codexAccountSnapshots = currentSnapshots
            self.codexAccountUsageSnapshotStore?.store(currentSnapshots)
        }

        let selectionStillMatches = self.codexVisibleSelectionStillMatches(
            originalVisibleAccountID: originalVisibleAccountID,
            originalSelectionSource: originalSelectionSource,
            originalAccount: originalVisibleAccount,
            currentProjection: currentProjection)
        guard let selectedOutcome, let selectedAccount else { return }
        guard selectionStillMatches else {
            _ = self.prepareCodexAccountScopedRefreshIfNeeded()
            return
        }

        let allowSelectedAuthFingerprintMismatch = switch selectedOutcome.result {
        case .success:
            true
        case .failure:
            false
        }
        let currentSelectedAccount = Self.currentCodexVisibleAccount(
            matching: selectedAccount,
            projection: currentProjection,
            allowProviderAccountAuthFingerprintMismatch: allowSelectedAuthFingerprintMismatch)
        if let currentSelectedAccount {
            let currentSelectedSnapshot = Self.codexVisibleAccountSnapshotRelabeledForCurrentProjection(
                selectedSnapshot,
                account: currentSelectedAccount)
            if self.shouldApplySelectedCodexVisibleAccountOutcome(
                selectedOutcome,
                snapshot: currentSelectedSnapshot)
            {
                await self.applySelectedCodexVisibleAccountOutcome(
                    selectedOutcome,
                    account: currentSelectedAccount,
                    snapshot: currentSelectedSnapshot,
                    sourceLabel: selectedSourceLabel,
                    generation: generation)
            }
        } else {
            _ = self.prepareCodexAccountScopedRefreshIfNeeded()
        }
    }

    func codexVisibleSelectionStillMatches(
        originalVisibleAccountID: String?,
        originalSelectionSource: CodexActiveSource?,
        originalAccount: CodexVisibleAccount? = nil,
        currentProjection: CodexVisibleAccountProjection? = nil) -> Bool
    {
        let currentProjection = currentProjection ?? self.settings.codexVisibleAccountProjection
        let currentActiveAccount = currentProjection.activeVisibleAccountID.flatMap { id in
            currentProjection.visibleAccounts.first { $0.id == id }
        }
        let currentSelectionSource = currentActiveAccount?.selectionSource
        if currentProjection.activeVisibleAccountID == originalVisibleAccountID,
           currentSelectionSource == originalSelectionSource
        {
            return true
        }
        guard let originalAccount, let currentActiveAccount, currentSelectionSource == originalSelectionSource else {
            return false
        }
        return Self.codexVisibleAccountMatchesCurrentProjection(originalAccount, account: currentActiveAccount)
    }

    private func freshCodexVisibleAccountProjectionForAccountRefresh(
        requireLiveManagedAuthFor accountIDs: Set<UUID> = []) -> CodexVisibleAccountProjection
    {
        // Auth files can change while account fetches are in flight, so account refreshes bypass the
        // short-lived reconciliation cache used for normal menu rendering and stale-result guards.
        self.settings.invalidateCodexAccountReconciliationSnapshotCache()
        let snapshot = self.settings.codexAccountReconciliationSnapshot
        return Self.codexVisibleAccountProjectionWithFreshManagedAuthFingerprints(
            CodexVisibleAccountProjection.make(from: snapshot),
            snapshot: snapshot,
            requireLiveManagedAuthFor: accountIDs)
    }

    private func codexManagedAccountIDsWithReadableAuth() -> Set<UUID> {
        Set(self.settings.codexAccountReconciliationSnapshot.storedAccounts.compactMap { account in
            CodexAuthFingerprint.fingerprint(homePath: account.managedHomePath) == nil ? nil : account.id
        })
    }

    private nonisolated static func codexVisibleAccountProjectionWithFreshManagedAuthFingerprints(
        _ projection: CodexVisibleAccountProjection,
        snapshot: CodexAccountReconciliationSnapshot,
        requireLiveManagedAuthFor accountIDs: Set<UUID> = []) -> CodexVisibleAccountProjection
    {
        let managedRuntimeStates = Dictionary(
            uniqueKeysWithValues: snapshot.storedAccounts.map { account in
                let workspaceAccountID: String? = switch snapshot.runtimeIdentity(for: account) {
                case let .providerAccount(id):
                    id
                case .emailOnly, .unresolved:
                    nil
                }
                let authFingerprint = CodexAuthFingerprint.fingerprint(homePath: account.managedHomePath)
                let requiresLiveAuth = accountIDs.contains(account.id)
                return (account.id, CodexManagedVisibleAccountRuntimeState(
                    authFingerprint: authFingerprint ?? (requiresLiveAuth ? nil : account.authFingerprint),
                    workspaceAccountID: authFingerprint == nil && requiresLiveAuth
                        ? nil
                        : (workspaceAccountID ?? account.workspaceAccountID)))
            })
        let visibleAccounts = projection.visibleAccounts.map { account in
            guard case let .managedAccount(id) = account.selectionSource else { return account }
            let accountWorkspaceAccountID = account.workspaceAccountID
                .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
            let runtimeWorkspaceAccountID = managedRuntimeStates[id]?.workspaceAccountID
                .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
            guard let runtimeState = managedRuntimeStates[id],
                  runtimeState.authFingerprint != account.authFingerprint ||
                  runtimeWorkspaceAccountID != accountWorkspaceAccountID
            else {
                return account
            }
            return CodexVisibleAccount(
                id: account.id,
                email: account.email,
                workspaceLabel: account.workspaceLabel,
                workspaceAccountID: runtimeState.workspaceAccountID,
                authFingerprint: runtimeState.authFingerprint,
                storedAccountID: account.storedAccountID,
                selectionSource: account.selectionSource,
                isActive: account.isActive,
                isLive: account.isLive,
                canReauthenticate: account.canReauthenticate,
                canRemove: account.canRemove)
        }
        return CodexVisibleAccountProjection(
            visibleAccounts: visibleAccounts,
            activeVisibleAccountID: projection.activeVisibleAccountID,
            liveVisibleAccountID: projection.liveVisibleAccountID,
            hasUnreadableAddedAccountStore: projection.hasUnreadableAddedAccountStore)
    }

    private static func currentCodexVisibleAccount(
        matching account: CodexVisibleAccount,
        projection: CodexVisibleAccountProjection,
        allowProviderAccountAuthFingerprintMismatch: Bool = true) -> CodexVisibleAccount?
    {
        if let currentAccount = projection.visibleAccounts.first(where: { $0.id == account.id }),
           self.codexVisibleAccountMatchesCurrentProjection(
               account,
               account: currentAccount,
               allowProviderAccountAuthFingerprintMismatch: allowProviderAccountAuthFingerprintMismatch)
        {
            return currentAccount
        }
        return projection.visibleAccounts.first {
            self.codexVisibleAccountMatchesCurrentProjection(
                account,
                account: $0,
                allowProviderAccountAuthFingerprintMismatch: allowProviderAccountAuthFingerprintMismatch)
        }
    }

    private static func codexVisibleAccountSnapshotRelabeledForCurrentProjection(
        _ snapshot: UsageSnapshot?,
        account: CodexVisibleAccount) -> UsageSnapshot?
    {
        guard let snapshot else { return nil }
        let existing = snapshot.identity(for: .codex)
        return snapshot.withIdentity(ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: account.email,
            accountOrganization: existing?.accountOrganization,
            loginMethod: existing?.loginMethod ?? account.workspaceLabel))
    }

    private static func codexVisibleAccountMatchesCurrentProjection(
        _ prior: CodexVisibleAccount,
        account: CodexVisibleAccount,
        allowProviderAccountAuthFingerprintMismatch: Bool = true) -> Bool
    {
        guard prior.selectionSource == account.selectionSource else { return false }

        let priorEmail = CodexIdentityResolver.normalizeEmail(prior.email)
        let accountEmail = CodexIdentityResolver.normalizeEmail(account.email)

        let priorWorkspaceID = self.normalizedCodexVisibleAccountText(prior.workspaceAccountID)
            .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
        let accountWorkspaceID = self.normalizedCodexVisibleAccountText(account.workspaceAccountID)
            .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
        if priorWorkspaceID != nil || accountWorkspaceID != nil {
            guard priorWorkspaceID == accountWorkspaceID else { return false }
            if !allowProviderAccountAuthFingerprintMismatch {
                guard self.codexVisibleAccountAuthFingerprintMatches(prior, account: account) else { return false }
            }
            switch account.selectionSource {
            case .managedAccount:
                if !self.codexVisibleAccountAuthFingerprintMatches(prior, account: account) {
                    return priorEmail != nil && priorEmail == accountEmail
                }
                return true
            case .liveSystem:
                return priorEmail != nil && priorEmail == accountEmail
            case .profileHome:
                if !allowProviderAccountAuthFingerprintMismatch {
                    guard self.codexVisibleAccountAuthFingerprintMatches(prior, account: account) else { return false }
                }
                return priorEmail != nil && priorEmail == accountEmail
            }
        }

        let priorAuthFingerprint = CodexAuthFingerprint.normalize(prior.authFingerprint)
        let accountAuthFingerprint = CodexAuthFingerprint.normalize(account.authFingerprint)
        if priorAuthFingerprint != nil || accountAuthFingerprint != nil {
            guard priorAuthFingerprint == accountAuthFingerprint else { return false }
        }

        return priorEmail != nil && priorEmail == accountEmail
    }

    private static func codexVisibleAccountAuthFingerprintMatches(
        _ prior: CodexVisibleAccount,
        account: CodexVisibleAccount) -> Bool
    {
        let priorAuthFingerprint = CodexAuthFingerprint.normalize(prior.authFingerprint)
        let accountAuthFingerprint = CodexAuthFingerprint.normalize(account.authFingerprint)
        if priorAuthFingerprint != nil || accountAuthFingerprint != nil {
            return priorAuthFingerprint == accountAuthFingerprint
        }
        return true
    }

    func shouldApplySelectedCodexVisibleAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        snapshot: UsageSnapshot?) -> Bool
    {
        switch outcome.result {
        case .success:
            snapshot != nil
        case .failure:
            true
        }
    }

    func refreshTokenAccounts(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount],
        generation: UInt64? = nil) async
    {
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

        let results = await self.fetchTokenAccountOutcomes(provider: provider, accounts: limitedAccounts)
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        for result in results {
            let account = result.account
            let outcome = result.outcome
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
                fallbackSnapshot: selectedSnapshot,
                generation: generation)
        }

        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
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

    nonisolated static func errorIsCancellation(_ error: any Error) -> Bool {
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
        snapshots: [CodexAccountUsageSnapshot] = [],
        activeVisibleAccountID: String?) -> [CodexVisibleAccount]
    {
        let accounts = CodexAccountPresentationOrdering.orderedAccounts(
            accounts,
            snapshots: snapshots,
            activeVisibleAccountID: activeVisibleAccountID)
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
        override: TokenAccountOverride?,
        codexActiveSourceOverride: CodexActiveSource? = nil) async -> ProviderFetchOutcome
    {
        let descriptor = self.providerSpecs[provider]?.descriptor ?? ProviderDescriptorRegistry
            .descriptor(for: provider)
        let context = self.makeFetchContext(
            provider: provider,
            override: override,
            codexActiveSourceOverride: codexActiveSourceOverride)
        let outcome = await descriptor.fetchOutcome(context: context)
        guard provider == .codex else { return outcome }
        return await Self.attachingCodexResetCreditsIfNeeded(
            to: outcome,
            env: context.env,
            fetcher: self.codexResetCreditsFetcher())
    }

    private func fetchTokenAccountOutcomes(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount]) async -> [TokenAccountFetchResult]
    {
        let requests: [(
            index: Int,
            account: ProviderTokenAccount,
            descriptor: ProviderDescriptor,
            context: ProviderFetchContext)] =
            accounts.enumerated().map { index, account in
                let override = TokenAccountOverride(provider: provider, account: account)
                let descriptor = self.providerSpecs[provider]?.descriptor ?? ProviderDescriptorRegistry
                    .descriptor(for: provider)
                let context = self.makeFetchContext(provider: provider, override: override)
                return (index, account, descriptor, context)
            }

        return await withTaskGroup(
            of: TokenAccountFetchResult.self,
            returning: [TokenAccountFetchResult].self)
        { group in
            for request in requests {
                group.addTask {
                    let outcome = await request.descriptor.fetchOutcome(context: request.context)
                    return TokenAccountFetchResult(
                        index: request.index,
                        account: request.account,
                        outcome: outcome)
                }
            }

            var results: [TokenAccountFetchResult] = []
            results.reserveCapacity(requests.count)
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private func fetchCodexVisibleAccountOutcomes(_ accounts: [CodexVisibleAccount]) async
    -> [CodexAccountFetchResult] {
        let resetCreditsFetcher = self.codexResetCreditsFetcher()
        let requests: [(
            index: Int,
            account: CodexVisibleAccount,
            descriptor: ProviderDescriptor,
            context: ProviderFetchContext)] =
            accounts.enumerated().map { index, account in
                let descriptor = self.providerSpecs[.codex]?.descriptor ?? ProviderDescriptorRegistry
                    .descriptor(for: .codex)
                let context = self.makeFetchContext(
                    provider: .codex,
                    override: nil,
                    codexActiveSourceOverride: account.selectionSource)
                return (index, account, descriptor, context)
            }

        return await withTaskGroup(
            of: CodexAccountFetchResult.self,
            returning: [CodexAccountFetchResult].self)
        { group in
            for request in requests {
                group.addTask {
                    let baseOutcome = await request.descriptor.fetchOutcome(context: request.context)
                    let outcome = await Self.attachingCodexResetCreditsIfNeeded(
                        to: baseOutcome,
                        env: request.context.env,
                        fetcher: resetCreditsFetcher)
                    return CodexAccountFetchResult(
                        index: request.index,
                        account: request.account,
                        outcome: outcome)
                }
            }

            var results: [CodexAccountFetchResult] = []
            results.reserveCapacity(requests.count)
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    func makeFetchContext(
        provider: UsageProvider,
        override: TokenAccountOverride?,
        codexActiveSourceOverride: CodexActiveSource? = nil,
        includeCredits: Bool = false) -> ProviderFetchContext
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: provider,
            settings: self.settings,
            override: override)
        let sourceMode = self.sourceMode(for: provider)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(
            settings: self.settings,
            tokenOverride: override,
            codexActiveSourceOverride: codexActiveSourceOverride)
        let env = ProviderRegistry.makeEnvironment(
            base: self.environmentBase,
            provider: provider,
            settings: self.settings,
            tokenOverride: override,
            codexActiveSourceOverride: codexActiveSourceOverride)
        let fetcher = ProviderRegistry.makeFetcher(base: self.codexFetcher, provider: provider, env: env)
        let verbose = self.settings.isVerboseLoggingEnabled
        let contextProvider = provider
        let originalAccountToken = account?.token
        let originalManualToken = provider == .stepfun ? self.settings.stepfunToken : nil
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: includeCredits,
            includeOptionalUsage: self.settings.showOptionalCreditsAndExtraUsage,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: verbose,
            env: env,
            settings: snapshot,
            fetcher: fetcher,
            claudeFetcher: self.claudeFetcher,
            browserDetection: self.browserDetection,
            selectedTokenAccountID: account?.id,
            tokenAccountTokenUpdater: { [weak self] provider, accountID, token in
                await MainActor.run {
                    guard let self, provider == contextProvider,
                          self.settings.tokenAccounts(for: provider)
                              .first(where: { $0.id == accountID })?.token == originalAccountToken
                    else {
                        return
                    }
                    self.settings.updateTokenAccount(
                        provider: provider,
                        accountID: accountID,
                        token: token)
                }
            },
            providerManualTokenUpdater: { [weak self] provider, token in
                await MainActor.run {
                    guard let self, provider == .stepfun,
                          self.settings.stepfunToken == originalManualToken
                    else { return }
                    self.settings.stepfunToken = token
                }
            },
            costUsageHistoryDays: self.settings.costUsageHistoryDays,
            persistsCLISessions: true,
            persistentCLISessionIdleWindow: ProviderRegistry.persistentCLISessionIdleWindow(
                refreshInterval: self.normalRefreshIntervalForHeuristics()))
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

    private struct CodexResetBackfillWindowCandidate {
        let window: RateWindow
        let capturedAt: Date
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

    private func codexResetBackfillSnapshots(
        for account: CodexVisibleAccount,
        priorSnapshot: CodexAccountUsageSnapshot?,
        activeVisibleAccountID: String?) -> [UsageSnapshot]
    {
        var snapshots: [UsageSnapshot] = []
        if let priorSnapshot,
           Self.codexPriorSnapshotAccountMatches(priorSnapshot.account, account: account),
           let prior = priorSnapshot.snapshot
        {
            snapshots.append(prior)
        }
        if account.id == activeVisibleAccountID,
           let lastKnown = self.codexLastKnownResetSnapshot(for: account)
        {
            snapshots.append(lastKnown)
        }
        if account.id != activeVisibleAccountID || self.codexCanUseHistoricalResetBackfill(for: account),
           let history = self.codexPlanHistoryResetBackfillSnapshot(for: account)
        {
            snapshots.append(history)
        }
        return snapshots
    }

    private func codexCanUseHistoricalResetBackfill(for account: CodexVisibleAccount) -> Bool {
        let authFingerprint = CodexAuthFingerprint.normalize(account.authFingerprint)
        let workspaceAccountID = Self.normalizedCodexVisibleAccountText(account.workspaceAccountID)
            .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
        guard authFingerprint != nil, workspaceAccountID == nil else { return true }
        return Self.codexScopedGuard(self.lastCodexAccountScopedRefreshGuard, matches: account)
    }

    private func codexPlanHistoryResetBackfillSnapshot(for account: CodexVisibleAccount) -> UsageSnapshot? {
        let histories = self.codexPlanUtilizationHistories(forVisibleAccount: account)
        guard !histories.isEmpty
        else {
            return nil
        }

        let now = Date()
        let primaryCandidate = Self.codexResetBackfillWindowCandidate(
            from: histories,
            name: .session,
            windowMinutes: Self.codexSessionWindowMinutes,
            now: now)
        let secondaryCandidate = Self.codexResetBackfillWindowCandidate(
            from: histories,
            name: .weekly,
            windowMinutes: Self.codexWeeklyWindowMinutes,
            now: now)
        let primary = primaryCandidate?.window
        let secondary = secondaryCandidate?.window
        guard primary != nil || secondary != nil else { return nil }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: [primaryCandidate?.capturedAt, secondaryCandidate?.capturedAt].compactMap(\.self).max() ?? now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: account.email,
                accountOrganization: nil,
                loginMethod: account.workspaceLabel))
    }

    private func codexLastKnownResetSnapshot(for account: CodexVisibleAccount) -> UsageSnapshot? {
        guard let snapshot = self.lastKnownResetSnapshots[.codex],
              Self.codexVisibleAccountEmailMatches(snapshot: snapshot, account: account),
              Self.codexScopedGuard(self.lastCodexAccountScopedRefreshGuard, matches: account)
        else {
            return nil
        }
        return snapshot
    }

    func codexLastKnownResetSnapshot(matching guardValue: CodexAccountScopedRefreshGuard?) -> UsageSnapshot? {
        guard let guardValue,
              let lastGuard = self.lastCodexAccountScopedRefreshGuard,
              Self.codexScopedRefreshGuardAllowsResetBackfill(lastGuard, matching: guardValue)
        else {
            return nil
        }
        return self.lastKnownResetSnapshots[.codex]
    }

    private nonisolated static func codexVisibleAccountEmailMatches(
        snapshot: UsageSnapshot,
        account: CodexVisibleAccount) -> Bool
    {
        guard let identity = snapshot.identity(for: .codex),
              let identityEmail = CodexIdentityResolver.normalizeEmail(identity.accountEmail),
              let accountEmail = CodexIdentityResolver.normalizeEmail(account.email),
              identityEmail == accountEmail
        else {
            return false
        }
        return true
    }

    private nonisolated static func codexPriorSnapshotAccountMatches(
        _ prior: CodexVisibleAccount,
        account: CodexVisibleAccount) -> Bool
    {
        guard let priorEmail = CodexIdentityResolver.normalizeEmail(prior.email),
              let accountEmail = CodexIdentityResolver.normalizeEmail(account.email),
              priorEmail == accountEmail
        else {
            return false
        }

        let priorWorkspaceID = self.normalizedCodexVisibleAccountText(prior.workspaceAccountID)
            .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
        let accountWorkspaceID = self.normalizedCodexVisibleAccountText(account.workspaceAccountID)
            .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
        if priorWorkspaceID != nil || accountWorkspaceID != nil {
            return priorWorkspaceID == accountWorkspaceID
        }

        let priorAuthFingerprint = CodexAuthFingerprint.normalize(prior.authFingerprint)
        let accountAuthFingerprint = CodexAuthFingerprint.normalize(account.authFingerprint)
        if priorAuthFingerprint != nil || accountAuthFingerprint != nil {
            guard priorAuthFingerprint == accountAuthFingerprint else { return false }
        }

        if prior.selectionSource == account.selectionSource {
            switch account.selectionSource {
            case .managedAccount:
                return true
            case .liveSystem:
                return prior.id == account.id
            case .profileHome:
                return true
            }
        }

        guard prior.id != prior.email, account.id != account.email else { return false }
        return prior.id == account.id
    }

    private nonisolated static func codexScopedGuard(
        _ guardValue: CodexAccountScopedRefreshGuard?,
        matches account: CodexVisibleAccount) -> Bool
    {
        guard let guardValue, guardValue.source == account.selectionSource else { return false }
        let guardAuthFingerprint = CodexAuthFingerprint.normalize(guardValue.authFingerprint)
        let accountAuthFingerprint = CodexAuthFingerprint.normalize(account.authFingerprint)
        if guardAuthFingerprint != nil || accountAuthFingerprint != nil {
            guard guardAuthFingerprint == accountAuthFingerprint else { return false }
        }
        let identity = self.codexVisibleAccountIdentity(for: account)
        if identity != .unresolved {
            return guardValue.identity == identity
        }
        guard let accountKey = CodexIdentityResolver.normalizeEmail(account.email) else { return false }
        return guardValue.accountKey == accountKey
    }

    private nonisolated static func codexScopedRefreshGuardAllowsResetBackfill(
        _ lastGuard: CodexAccountScopedRefreshGuard,
        matching expectedGuard: CodexAccountScopedRefreshGuard) -> Bool
    {
        self.codexScopedRefreshGuardsMatchAccount(lastGuard, expectedGuard)
    }

    private nonisolated static func codexScopedRefreshGuard(for account: CodexVisibleAccount)
        -> CodexAccountScopedRefreshGuard
    {
        let accountEmail = CodexIdentityResolver.normalizeEmail(account.email)
        return CodexAccountScopedRefreshGuard(
            source: account.selectionSource,
            identity: self.codexVisibleAccountIdentity(for: account),
            accountKey: accountEmail,
            authFingerprint: account.authFingerprint)
    }

    private nonisolated static func codexVisibleAccountIdentity(for account: CodexVisibleAccount) -> CodexIdentity {
        if let workspaceAccountID = self.normalizedCodexVisibleAccountText(account.workspaceAccountID) {
            return .providerAccount(id: CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID(workspaceAccountID))
        }
        return CodexIdentityResolver.resolve(accountId: nil, email: account.email)
    }

    private nonisolated static func normalizedCodexVisibleAccountText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private nonisolated static func codexResetBackfillWindowCandidate(
        from histories: [PlanUtilizationSeriesHistory],
        name: PlanUtilizationSeriesName,
        windowMinutes: Int,
        now: Date) -> CodexResetBackfillWindowCandidate?
    {
        let candidate = histories.lazy
            .filter { $0.name == name && name.canonicalWindowMinutes($0.windowMinutes) == windowMinutes }
            .flatMap { history in
                history.entries.map { entry in
                    (capturedAt: entry.capturedAt, usedPercent: entry.usedPercent, resetsAt: entry.resetsAt)
                }
            }
            .filter { $0.resetsAt.map { $0 > now } ?? false }
            .max { lhs, rhs in
                if lhs.capturedAt != rhs.capturedAt {
                    return lhs.capturedAt < rhs.capturedAt
                }
                return (lhs.resetsAt ?? .distantPast) < (rhs.resetsAt ?? .distantPast)
            }

        guard let candidate, let resetsAt = candidate.resetsAt else { return nil }
        return CodexResetBackfillWindowCandidate(
            window: RateWindow(
                usedPercent: candidate.usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt,
                resetDescription: nil),
            capturedAt: candidate.capturedAt)
    }

    private nonisolated static func codexBackfillingResetWindows(
        _ snapshot: UsageSnapshot,
        from cached: UsageSnapshot) -> UsageSnapshot
    {
        let primary = self.codexBackfillingResetWindow(snapshot.primary, from: cached.primary)
        let secondary = self.codexBackfillingResetWindow(snapshot.secondary, from: cached.secondary)
        guard primary != snapshot.primary || secondary != snapshot.secondary else { return snapshot }
        return snapshot.with(primary: primary, secondary: secondary)
    }

    private nonisolated static func codexMergedResetBackfillSnapshot(
        _ snapshots: [UsageSnapshot],
        now: Date = Date()) -> UsageSnapshot?
    {
        let primary = self.codexPreferredResetBackfillWindow(
            snapshots.enumerated().compactMap { index, snapshot in
                snapshot.primary.map { (window: $0, updatedAt: snapshot.updatedAt, priority: index) }
            },
            now: now)
        let secondary = self.codexPreferredResetBackfillWindow(
            snapshots.enumerated().compactMap { index, snapshot in
                snapshot.secondary.map { (window: $0, updatedAt: snapshot.updatedAt, priority: index) }
            },
            now: now)
        guard primary != nil || secondary != nil else { return nil }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: snapshots.map(\.updatedAt).max() ?? now)
    }

    private nonisolated static func codexPreferredResetBackfillWindow(
        _ windows: [(window: RateWindow, updatedAt: Date, priority: Int)],
        now: Date) -> RateWindow?
    {
        windows
            .filter { ($0.window.resetsAt ?? .distantPast) > now }
            .max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                let lhsReset = lhs.window.resetsAt ?? .distantPast
                let rhsReset = rhs.window.resetsAt ?? .distantPast
                if lhsReset != rhsReset {
                    return lhsReset < rhsReset
                }
                return (lhs.window.windowMinutes ?? 0) < (rhs.window.windowMinutes ?? 0)
            }
            .map(\.window)
    }

    private nonisolated static func codexBackfillingResetWindow(
        _ window: RateWindow?,
        from cached: RateWindow?) -> RateWindow?
    {
        guard let cached,
              let resetsAt = cached.resetsAt,
              resetsAt > Date()
        else {
            return window
        }
        if let window {
            return window.backfillingResetTime(from: cached)
        }
        guard let windowMinutes = cached.windowMinutes, windowMinutes > 0 else { return nil }
        return RateWindow(
            usedPercent: cached.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: cached.resetDescription)
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
        priorSnapshot: CodexAccountUsageSnapshot? = nil,
        resetBackfillSnapshots: [UsageSnapshot] = []) -> ResolvedCodexAccountOutcome
    {
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: .codex)
            let labeled = self.applyCodexVisibleAccountLabel(scoped, account: account)
            let backfilled = Self.codexMergedResetBackfillSnapshot(resetBackfillSnapshots)
                .map { Self.codexBackfillingResetWindows(labeled, from: $0) } ?? labeled
            let snapshot = CodexAccountUsageSnapshot(
                account: account,
                snapshot: backfilled,
                error: nil,
                sourceLabel: result.sourceLabel)
            return ResolvedCodexAccountOutcome(
                snapshot: snapshot,
                usage: backfilled,
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
            let errorMessage = self.tokenAccountSnapshotErrorMessage(error)
            if Self.shouldPreserveCodexAccountSnapshotOnFailure(errorMessage),
               let priorSnapshot,
               let priorUsage = priorSnapshot.snapshot
            {
                let snapshot = CodexAccountUsageSnapshot(
                    account: account,
                    snapshot: priorUsage,
                    error: errorMessage,
                    sourceLabel: priorSnapshot.sourceLabel)
                return ResolvedCodexAccountOutcome(
                    snapshot: snapshot,
                    usage: priorUsage,
                    sourceLabel: priorSnapshot.sourceLabel)
            }
            let snapshot = CodexAccountUsageSnapshot(
                account: account,
                snapshot: nil,
                error: errorMessage,
                sourceLabel: nil)
            return ResolvedCodexAccountOutcome(snapshot: snapshot, usage: nil, sourceLabel: nil)
        }
    }

    private static func shouldPreserveCodexAccountSnapshotOnFailure(_ message: String) -> Bool {
        guard CodexAccountHealth.status(forError: message) == .unavailable else { return false }
        let normalized = message.lowercased()
        return normalized.contains("network") ||
            normalized.contains("internet connection") ||
            normalized.contains("offline") ||
            normalized.contains("timed out") ||
            normalized.contains("timeout") ||
            normalized.contains("connection was lost") ||
            normalized.contains("could not connect") ||
            normalized.contains("not connected") ||
            normalized.contains("hostname") ||
            normalized.contains("dns") ||
            normalized.contains("temporarily unavailable")
    }

    func applySelectedCodexVisibleAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        account: CodexVisibleAccount,
        snapshot: UsageSnapshot?,
        sourceLabel: String?,
        generation: UInt64? = nil) async
    {
        guard self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
        self.lastFetchAttempts[.codex] = outcome.attempts
        switch outcome.result {
        case .success:
            guard let snapshot else { return }
            self.handleCodexResetCreditNotifications(snapshot: snapshot)
            self.handleSessionQuotaTransition(provider: .codex, snapshot: snapshot)
            self.lastKnownResetSnapshots[.codex] = snapshot
            self.lastCodexAccountScopedRefreshGuard = Self.codexScopedRefreshGuard(for: account)
            self.snapshots[.codex] = snapshot
            if let sourceLabel {
                self.lastSourceLabels[.codex] = sourceLabel
            }
            self.errors[.codex] = nil
            self.failureGates[.codex]?.recordSuccess()
            self.rememberLiveSystemCodexEmailIfNeeded(snapshot.accountEmail(for: .codex))
            self.seedCodexAccountScopedRefreshGuard(accountEmail: account.email)
            await self.recordPlanUtilizationHistorySample(provider: .codex, snapshot: snapshot)
            guard self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
            self.recordCodexHistoricalSampleIfNeeded(snapshot: snapshot)
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
        fallbackSnapshot: UsageSnapshot?,
        generation: UInt64? = nil) async
    {
        await MainActor.run {
            guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
            self.lastFetchAttempts[provider] = outcome.attempts
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let labeled: UsageSnapshot = if let account {
                self.applyAccountLabel(scoped, provider: provider, account: account)
            } else {
                scoped
            }
            let backfilled = await MainActor.run {
                guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else {
                    return nil as UsageSnapshot?
                }
                let backfilled = labeled.backfillingResetTimes(from: self.lastKnownResetSnapshots[provider])
                self.handleQuotaWarningTransitions(provider: provider, snapshot: backfilled)
                self.handleSessionQuotaTransition(provider: provider, snapshot: backfilled)
                self.lastKnownResetSnapshots[provider] = backfilled
                self.snapshots[provider] = backfilled
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
                self.failureGates[provider]?.recordSuccess()
                return backfilled
            }
            guard let backfilled else { return }
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: backfilled,
                account: account)
        case let .failure(error):
            await MainActor.run {
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
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
