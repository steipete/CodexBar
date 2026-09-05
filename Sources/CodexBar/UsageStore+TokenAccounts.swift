import CodexBarCore
import Foundation

struct TokenAccountUsageSnapshot: Identifiable {
    let id: UUID
    let account: ProviderTokenAccount
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?
    let cacheKey: String

    init(
        account: ProviderTokenAccount,
        snapshot: UsageSnapshot?,
        error: String?,
        sourceLabel: String?,
        cacheKey: String)
    {
        self.id = account.id
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
        self.cacheKey = cacheKey
    }
}

extension UsageStore {
    func activateCachedTokenAccountSnapshot(provider: UsageProvider, accountID: UUID) {
        guard self.settings.effectiveSelectedTokenAccount(for: provider)?.id == accountID else { return }
        self.tokenAccountLiveStateProviders.insert(provider.instanceID)
        guard let account = self.uniqueTokenAccount(provider: provider, accountID: accountID),
              let cached = self.accountSnapshots[provider.instanceID]?.first(where: {
                  $0.account.id == accountID
                      && $0.cacheKey
                      == self.tokenAccountSnapshotCacheKey(
                          provider: provider,
                          account: account)
              })
        else {
            self.accountSnapshots[provider.instanceID]?.removeAll { $0.account.id == accountID }
            self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
            // Never show the previous account's usage under the newly selected account. Segmented layouts only
            // fetch the active account, so an uncached selection must render as refreshing until its fetch completes.
            self.clearTokenAccountLiveSnapshot(provider: provider)
            return
        }

        self.knownLimitsAvailabilityByProvider[provider.instanceID] = .resolve(
            provider: provider,
            snapshot: cached.snapshot,
            lastErrorDescription: cached.error)

        if let snapshot = cached.snapshot {
            self.snapshots[provider.instanceID] = snapshot
            self.lastKnownResetSnapshots[provider.instanceID] = snapshot
            self.installProviderDerivedTokenSnapshot(from: snapshot, for: provider)
        } else {
            self.snapshots.removeValue(forKey: provider.instanceID)
            self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
            self.resetProviderDerivedTokenSnapshot(for: provider)
        }
        self.errors[provider.instanceID] = cached.error
        if let sourceLabel = cached.sourceLabel {
            self.lastSourceLabels[provider.instanceID] = sourceLabel
        } else {
            self.lastSourceLabels.removeValue(forKey: provider.instanceID)
        }
    }

    func cacheTokenAccountSnapshot(
        provider: UsageProvider,
        account: ProviderTokenAccount,
        snapshot: UsageSnapshot,
        sourceLabel: String?)
    {
        let support = TokenAccountSupportCatalog.support(for: provider)
        let cookieSource = self.settings.providerConfig(for: provider)?.cookieSource ?? .auto
        guard support?.selectedAccountRequiresManualCookieSource != true || cookieSource != .auto else {
            return
        }
        let cached = TokenAccountUsageSnapshot(
            account: account,
            snapshot: snapshot,
            error: nil,
            sourceLabel: sourceLabel,
            cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account))
        var snapshots = self.accountSnapshots[provider.instanceID] ?? []
        if let index = snapshots.firstIndex(where: { $0.account.id == account.id }) {
            snapshots[index] = cached
        } else {
            snapshots.append(cached)
        }
        self.accountSnapshots[provider.instanceID] = snapshots
    }

    func pruneTokenAccountSnapshots(provider: UsageProvider, accounts: [ProviderTokenAccount]) {
        let retained = self.validTokenAccountSnapshots(provider: provider, accounts: accounts)
        if retained.isEmpty {
            self.accountSnapshots.removeValue(forKey: provider.instanceID)
        } else {
            self.accountSnapshots[provider.instanceID] = retained
        }
    }

    func reconcileSelectedTokenAccountSnapshotBeforeRefresh(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount])
    {
        self.pruneTokenAccountSnapshots(provider: provider, accounts: accounts)
        guard let selectedAccount = self.settings.effectiveSelectedTokenAccount(for: provider) else {
            if self.tokenAccountLiveStateProviders.remove(provider.instanceID) != nil {
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
                self.clearTokenAccountLiveSnapshot(provider: provider)
            }
            return
        }
        // A Settings edit can invalidate the selected credential or endpoint before its replacement refresh
        // completes. Reconcile the live card now so a failed/cancelled fetch cannot retain old-account data.
        self.activateCachedTokenAccountSnapshot(provider: provider, accountID: selectedAccount.id)
    }

    private func clearTokenAccountLiveSnapshot(provider: UsageProvider) {
        self.snapshots.removeValue(forKey: provider.instanceID)
        self.resetProviderDerivedTokenSnapshot(for: provider)
        self.errors.removeValue(forKey: provider.instanceID)
        self.lastSourceLabels.removeValue(forKey: provider.instanceID)
        self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
    }

    func validTokenAccountSnapshots(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount]) -> [TokenAccountUsageSnapshot]
    {
        let accountsByID = Dictionary(grouping: accounts, by: \.id).compactMapValues { matches in
            matches.count == 1 ? matches[0] : nil
        }
        return (self.accountSnapshots[provider.instanceID] ?? []).filter { cached in
            guard let account = accountsByID[cached.account.id] else { return false }
            return cached.cacheKey == self.tokenAccountSnapshotCacheKey(provider: provider, account: account)
        }
    }

    func uniqueTokenAccount(provider: UsageProvider, accountID: UUID) -> ProviderTokenAccount? {
        let matches = self.settings.tokenAccounts(for: provider).filter { $0.id == accountID }
        return matches.count == 1 ? matches[0] : nil
    }
}

private struct TokenAccountFetchResult {
    let index: Int
    let account: ProviderTokenAccount
    let outcome: ProviderFetchOutcome
}

private struct CodexManagedVisibleAccountRuntimeState {
    let authFingerprint: String?
    let workspaceAccountID: String?
}

extension UsageStore {
    static let tokenAccountMenuSnapshotLimit = 6

    func freshCodexVisibleAccountsForSnapshotHydration() -> [CodexVisibleAccount] {
        self.freshCodexVisibleAccountProjectionForAccountRefresh().visibleAccounts
    }

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
        return self.settings.tokenAccounts(for: provider)
    }

    func shouldFetchAllTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) -> Bool {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return false }
        guard let selectedAccount = self.settings.effectiveSelectedTokenAccount(for: provider) else { return false }
        guard self.settings.multiAccountMenuLayout == .stacked, accounts.count > 1 else { return false }
        guard provider == .huggingface else { return true }
        // Hugging Face's browser-session wallet carries no identifier that can be correlated with any
        // API token account, so a Web-authority refresh (explicit Web mode or Cookie source Refresh's
        // override) must not fan out across stacked accounts the way ordinary Auto/API refreshes do.
        let sourceMode = Self.requestedSourceModeOverride ?? ProviderRegistry.resolvedSourceMode(
            provider: provider, settings: self.settings, account: selectedAccount)
        return sourceMode != .web
    }

    func shouldFetchAllCodexVisibleAccounts() -> Bool {
        // PAT is not a per-visible-account credential. Fan-out would fetch the same token for
        // every row and then reject its whoami identity against other accounts.
        guard !self.shouldUseAmbientCodexPATForUsage() else { return false }
        let projection = self.freshCodexVisibleAccountProjectionForAccountRefresh()
        return self.settings.multiAccountMenuLayout == .stacked && projection.visibleAccounts.count > 1
    }

    func shouldUseAmbientCodexPATForUsage() -> Bool {
        switch self.settings.codexUsageDataSource {
        case .pat:
            true
        case .auto:
            (try? CodexOAuthCredentialsStore.loadPATResolvingScopedHome(env: self.codexFetchEnvironment()))
                != nil
        case .oauth, .cli:
            false
        }
    }

    func codexFetchEnvironment() -> [String: String] {
        // Provider-specific by design: PAT admission reads the selected Codex CODEX_HOME fetch environment.
        ProviderRegistry.makeEnvironment(
            base: self.environmentBase,
            provider: .codex,
            settings: self.settings,
            tokenOverride: nil)
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
        let priorSnapshots = self.codexAccountSnapshots
        var snapshots: [CodexAccountUsageSnapshot] = []
        var selectedOutcome: ProviderFetchOutcome?
        var selectedAccount: CodexVisibleAccount?
        var selectedSnapshot: UsageSnapshot?
        var selectedSourceLabel: String?
        var selectedLimitResetOwnerKey: CodexLimitResetOwnerKey?
        var selectedWithheldSuccess = false

        let results = await self.fetchCodexVisibleAccountOutcomes(
            accounts,
            allVisibleAccounts: projection.visibleAccounts,
            priorSnapshots: priorSnapshots,
            activeVisibleAccountID: originalVisibleAccountID)
        // Provider-specific by design: Codex fan-out checks the refresh generation before updating account rows.
        guard !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(.codex, generation: generation)
        else { return }
        let currentProjection = self.freshCodexVisibleAccountProjectionForAccountRefresh(
            requireLiveManagedAuthFor: managedAccountIDsWithReadableAuthAtStart)
        for result in results {
            let account = result.account
            let priorSnapshot = Self.codexPriorAccountSnapshot(
                matching: account,
                in: priorSnapshots)
            guard let outcome = result.outcome else {
                let authorizedSuccess = result.withheldSuccess != nil && Self.currentCodexVisibleAccount(
                    matching: account,
                    projection: currentProjection,
                    allowProviderAccountAuthFingerprintMismatch: false) != nil
                snapshots += Self.codexSnapshotsRetainingCandidate(
                    authorizedSuccess ? priorSnapshot.map(Self.clearingCodexConnectivityError) : priorSnapshot,
                    candidate: result.pendingWeeklyResetCandidate)
                if account.id == originalVisibleAccountID {
                    selectedWithheldSuccess = authorizedSuccess
                    selectedAccount = account
                    selectedLimitResetOwnerKey = result.limitResetOwnerKey
                }
                continue
            }
            let resolved = self.resolveCodexAccountOutcome(
                outcome,
                account: account,
                priorSnapshot: priorSnapshot,
                resetBackfillSnapshots: result.limitResetOwnerKey == nil
                    ? []
                    : self.codexResetBackfillSnapshots(
                        for: account,
                        priorSnapshot: priorSnapshot,
                        activeVisibleAccountID: originalVisibleAccountID))
            if let snapshot = resolved.snapshot {
                snapshots.append(CodexAccountUsageSnapshot(
                    account: snapshot.account,
                    snapshot: snapshot.snapshot,
                    error: snapshot.error,
                    sourceLabel: snapshot.sourceLabel,
                    credits: snapshot.credits,
                    weeklyResetCandidate: result.pendingWeeklyResetCandidate))
            }
            if account.id == originalVisibleAccountID {
                selectedOutcome = outcome
                selectedAccount = account
                selectedSnapshot = resolved.usage
                selectedSourceLabel = resolved.sourceLabel
                selectedLimitResetOwnerKey = result.limitResetOwnerKey
            }
        }

        let currentSnapshots = Self.codexAccountSnapshots(snapshots, reconciledWith: currentProjection)
        self.codexAccountSnapshots = currentSnapshots
        self.codexAccountUsageSnapshotStore?.store(currentSnapshots)

        let selectionStillMatches = self.codexVisibleSelectionStillMatches(
            originalVisibleAccountID: originalVisibleAccountID,
            originalSelectionSource: originalSelectionSource,
            originalAccount: originalVisibleAccount,
            currentProjection: currentProjection)
        guard let selectedOutcome, let selectedAccount else {
            if selectionStillMatches, selectedWithheldSuccess {
                self.recordCodexWithheldFetchSuccess()
            }
            if selectionStillMatches,
               let selectedID = currentProjection.activeVisibleAccountID,
               let preserved = currentSnapshots.first(where: { $0.id == selectedID }),
               let snapshot = preserved.snapshot
            {
                self.snapshots[.codex] = snapshot
                self.lastKnownResetSnapshots[.codex] = snapshot
                let publicationGuard = Self.codexScopedRefreshGuard(for: preserved.account)
                self.lastCodexUsagePublicationGuard = publicationGuard
                self.lastCodexAccountScopedRefreshGuard = publicationGuard
            } else if !selectionStillMatches {
                self.reconcileCodexAccountStateForUsageOwner(self.freshCodexAccountScopedRefreshGuard())
            }
            return
        }
        guard selectionStillMatches else {
            self.reconcileCodexAccountStateForUsageOwner(self.freshCodexAccountScopedRefreshGuard())
            return
        }

        let allowSelectedAuthFingerprintMismatch =
            switch selectedOutcome.result {
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
                    limitResetOwnerKey: selectedLimitResetOwnerKey,
                    generation: generation)
            }
        } else {
            self.reconcileCodexAccountStateForUsageOwner(self.freshCodexAccountScopedRefreshGuard())
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
            guard let originalAccount else { return true }
            guard let currentActiveAccount else { return false }
            return Self.codexVisibleAccountMatchesCurrentProjection(
                originalAccount,
                account: currentActiveAccount)
        }
        guard let originalAccount, let currentActiveAccount,
              currentSelectionSource == originalSelectionSource
        else {
            return false
        }
        return Self.codexVisibleAccountMatchesCurrentProjection(
            originalAccount, account: currentActiveAccount)
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
        Set(
            self.settings.codexAccountReconciliationSnapshot.storedAccounts.compactMap { account in
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
                let authWorkspaceAccountID: String? =
                    switch snapshot.runtimeIdentity(for: account) {
                    case let .providerAccount(id):
                        id
                    case .emailOnly, .unresolved:
                        nil
                    }
                let authFingerprint = CodexAuthFingerprint.fingerprint(homePath: account.managedHomePath)
                let requiresLiveAuth = accountIDs.contains(account.id)
                return (
                    account.id,
                    CodexManagedVisibleAccountRuntimeState(
                        authFingerprint: authFingerprint ?? (requiresLiveAuth ? nil : account.authFingerprint),
                        workspaceAccountID: authFingerprint == nil && requiresLiveAuth
                            ? nil
                            : (account.effectiveWorkspaceAccountID ?? authWorkspaceAccountID)))
            })
        let visibleAccounts = projection.visibleAccounts.map { account in
            guard case let .managedAccount(id) = account.selectionSource else { return account }
            let accountWorkspaceAccountID = account.workspaceAccountID
                .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
            let runtimeWorkspaceAccountID = managedRuntimeStates[id]?.workspaceAccountID
                .map(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID)
            guard let runtimeState = managedRuntimeStates[id],
                  runtimeState.authFingerprint != account.authFingerprint
                  || runtimeWorkspaceAccountID != accountWorkspaceAccountID
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

    static func currentCodexVisibleAccount(
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

    static func codexVisibleAccountSnapshotRelabeledForCurrentProjection(
        _ snapshot: UsageSnapshot?,
        account: CodexVisibleAccount) -> UsageSnapshot?
    {
        // Provider-specific by design: Codex managed profiles relabel fetched identity from reconciled workspace data.
        guard let snapshot else { return nil }
        let existing = snapshot.identity(for: .codex)
        return snapshot.withIdentity(
            ProviderIdentitySnapshot(
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
            guard priorWorkspaceID == accountWorkspaceID else { return false }
            if !allowProviderAccountAuthFingerprintMismatch {
                guard self.codexVisibleAccountAuthFingerprintMatches(prior, account: account) else {
                    return false
                }
            }
            return true
        }

        let priorAuthFingerprint = CodexAuthFingerprint.normalize(prior.authFingerprint)
        let accountAuthFingerprint = CodexAuthFingerprint.normalize(account.authFingerprint)
        if priorAuthFingerprint != nil || accountAuthFingerprint != nil {
            guard priorAuthFingerprint == accountAuthFingerprint else { return false }
        }

        return true
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
        guard let selectedAccount = self.settings.effectiveSelectedTokenAccount(for: provider) else {
            await MainActor.run {
                self.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
                    provider: provider,
                    accounts: accounts)
            }
            return
        }
        let limitedAccounts = self.limitedTokenAccounts(accounts, selected: selectedAccount)
        let effectiveSelected = selectedAccount

        // Capture the prior per-account snapshot state so we can preserve last-good
        // data when an in-flight refresh is cancelled (e.g. menu tab switches). Without
        // this, cancellation produces empty/error snapshots and the menu briefly shows
        // misleading cards for accounts that previously had valid data.
        let priorSnapshots = await MainActor.run {
            self.pruneTokenAccountSnapshots(provider: provider, accounts: accounts)
            self.activateCachedTokenAccountSnapshot(provider: provider, accountID: effectiveSelected.id)
            return self.accountSnapshots[provider.instanceID] ?? []
        }
        let priorByAccountID = Dictionary(
            uniqueKeysWithValues: priorSnapshots.map { ($0.account.id, $0) })

        var snapshots: [TokenAccountUsageSnapshot] = []
        var historySamples: [(account: ProviderTokenAccount, snapshot: UsageSnapshot)] = []
        var selectedOutcome: ProviderFetchOutcome?
        var resolvedSelectedAccount: ProviderTokenAccount?
        var selectedSnapshot: UsageSnapshot?
        var selectedAccountSnapshot: TokenAccountUsageSnapshot?
        var sawAnyNonCancellationOutcome = false

        let results = await self.fetchTokenAccountOutcomes(provider: provider, accounts: limitedAccounts)
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        for result in results {
            guard let account = self.uniqueTokenAccount(provider: provider, accountID: result.account.id)
            else { continue }
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
            if let usage = resolved.freshUsage {
                historySamples.append((account: account, snapshot: usage))
            }
            if account.id == effectiveSelected.id {
                selectedOutcome = outcome
                resolvedSelectedAccount = account
                selectedSnapshot = resolved.usage
                selectedAccountSnapshot = resolved.snapshot
            }
        }

        // If every fetch was cancelled (e.g. the user closed/reopened the menu mid-flight)
        // and we have no usable snapshots, leave the prior per-account state alone.
        // Wiping it would produce a menu of useless "cancelled" placeholders.
        let shouldPreservePriorState =
            !sawAnyNonCancellationOutcome && snapshots.allSatisfy { $0.snapshot == nil }
        if !shouldPreservePriorState {
            await MainActor.run {
                self.accountSnapshots[provider.instanceID] = snapshots
            }
        }

        if let selectedOutcome, let resolvedSelectedAccount {
            await self.applySelectedOutcome(
                selectedOutcome,
                provider: provider,
                account: resolvedSelectedAccount,
                fallbackSnapshot: selectedSnapshot,
                fallbackAccountSnapshot: selectedAccountSnapshot,
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

    private nonisolated static func codexUsageOutcomeMatchesVisibleAccount(
        _ outcome: ProviderFetchOutcome,
        account: CodexVisibleAccount) -> Bool
    {
        // Provider-specific by design: Codex account refresh rejects successful payloads for a different email owner.
        guard case let .success(result) = outcome.result else { return true }
        guard
            let resultEmail = CodexIdentityResolver.normalizeEmail(
                result.usage.scoped(to: .codex).accountEmail(for: .codex))
        else {
            return true
        }
        return resultEmail == CodexIdentityResolver.normalizeEmail(account.email)
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
        return message == "cancelled" || message.contains("cancellationerror")
            || message.contains("cancelled")
    }

    func limitedTokenAccounts(
        _ accounts: [ProviderTokenAccount],
        selected: ProviderTokenAccount?) -> [ProviderTokenAccount]
    {
        let limit = Self.tokenAccountMenuSnapshotLimit
        if accounts.count <= limit {
            return accounts
        }
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
        if accounts.count <= limit {
            return accounts
        }
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
        let descriptor =
            self.providerSpecs[provider]?.descriptor
                ?? ProviderDescriptorRegistry
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
            fetcher: self.codexResetCreditsFetcher(workspaceAccountID: context.codexWorkspaceID))
    }

    private func fetchTokenAccountOutcomes(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount]) async -> [TokenAccountFetchResult]
    {
        let requests:
            [(
                index: Int,
                account: ProviderTokenAccount,
                descriptor: ProviderDescriptor,
                context: ProviderFetchContext)] =
            accounts.enumerated().map { index, account in
                let override = TokenAccountOverride(provider: provider, account: account)
                let descriptor =
                    self.providerSpecs[provider]?.descriptor
                        ?? ProviderDescriptorRegistry
                        .descriptor(for: provider)
                let context = self.makeFetchContext(provider: provider, override: override)
                return (index, account, descriptor, context)
            }

        if let delay = TokenAccountSupportCatalog.support(for: provider)?
            .minimumDelayBetweenAccountRefreshes
        {
            var results: [TokenAccountFetchResult] = []
            results.reserveCapacity(requests.count)
            for request in requests {
                if !results.isEmpty {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        for pending in requests.dropFirst(results.count) {
                            results.append(
                                TokenAccountFetchResult(
                                    index: pending.index,
                                    account: pending.account,
                                    outcome: ProviderFetchOutcome(
                                        result: .failure(CancellationError()),
                                        attempts: [])))
                        }
                        return results
                    }
                }
                let outcome = await request.descriptor.fetchOutcome(context: request.context)
                results.append(
                    TokenAccountFetchResult(
                        index: request.index,
                        account: request.account,
                        outcome: outcome))
            }
            return results
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

    private func fetchCodexVisibleAccountOutcomes(
        _ accounts: [CodexVisibleAccount],
        allVisibleAccounts: [CodexVisibleAccount],
        priorSnapshots: [CodexAccountUsageSnapshot],
        activeVisibleAccountID: String?) async
        -> [CodexAccountFetchResult]
    {
        let requests: [CodexAccountFetchRequest] = accounts.enumerated().map { index, account in
            let descriptor =
                self.providerSpecs[.codex]?.descriptor
                    ?? ProviderDescriptorRegistry
                    .descriptor(for: .codex)
            // Spend-controls monthly credit (Business/Enterprise individual cap) is gated on this flag.
            let context = self.makeFetchContext(
                provider: .codex,
                override: nil,
                codexActiveSourceOverride: account.selectionSource,
                includeCredits: true)
            let limitResetOwnerKey = self.codexLimitResetOwnerKey(
                forVisibleAccount: account,
                visibleAccounts: allVisibleAccounts)
            let priorSnapshot = Self.codexPriorAccountSnapshot(
                matching: account,
                in: priorSnapshots)
            let trustedBackfillSnapshots =
                limitResetOwnerKey == nil
                    ? []
                    : self.codexResetBackfillSnapshots(
                        for: account,
                        priorSnapshot: priorSnapshot,
                        activeVisibleAccountID: activeVisibleAccountID)
            let missingWindowBackfillSnapshot = Self.codexMergedResetBackfillSnapshot(
                trustedBackfillSnapshots)
            return CodexAccountFetchRequest(
                index: index,
                account: account,
                previousSnapshot: limitResetOwnerKey == nil ? nil : priorSnapshot?.snapshot,
                previousSourceLabel: limitResetOwnerKey == nil ? nil : priorSnapshot?.sourceLabel,
                missingWindowBackfillSnapshot: missingWindowBackfillSnapshot,
                limitResetOwnerKey: limitResetOwnerKey,
                pendingWeeklyResetCandidate: priorSnapshot?.weeklyResetCandidate,
                descriptor: descriptor,
                context: context,
                resetCreditsFetcher: self.codexResetCreditsFetcher(workspaceAccountID: context.codexWorkspaceID))
        }

        return await withTaskGroup(
            of: CodexAccountFetchResult.self,
            returning: [CodexAccountFetchResult].self)
        { group in
            for request in requests {
                group.addTask {
                    let fetchOutcome: CodexWeeklyConfirmationFetch = {
                        let baseOutcome = await request.descriptor.fetchOutcome(context: request.context)
                        return await Self.attachingCodexResetCreditsIfNeeded(
                            to: baseOutcome,
                            env: request.context.env,
                            fetcher: request.resetCreditsFetcher)
                    }
                    let initialOutcome = await fetchOutcome()
                    let admission: CodexWeeklyResetPublicationAdmission?
                    if Self.codexUsageOutcomeMatchesVisibleAccount(
                        initialOutcome,
                        account: request.account)
                    {
                        let admitted = await Self.codexOutcomeAdmittedForPublication(
                            initialOutcome: initialOutcome,
                            previousSnapshot: request.previousSnapshot,
                            previousSourceLabel: request.previousSourceLabel,
                            missingWindowBackfillSnapshot: request.missingWindowBackfillSnapshot,
                            pendingCandidate: request.pendingWeeklyResetCandidate,
                            fetchConfirmation: fetchOutcome)
                        if let outcome = admitted.outcome,
                           Self.codexUsageOutcomeMatchesVisibleAccount(outcome, account: request.account)
                        {
                            admission = CodexWeeklyResetPublicationAdmission(
                                outcome: outcome,
                                pendingCandidate: admitted.pendingCandidate)
                        } else {
                            admission = CodexWeeklyResetPublicationAdmission(
                                outcome: nil,
                                pendingCandidate: admitted.pendingCandidate,
                                withheldSuccess: admitted.withheldSuccess)
                        }
                    } else {
                        admission = nil
                    }
                    return CodexAccountFetchResult(
                        index: request.index,
                        account: request.account,
                        outcome: admission?.outcome,
                        limitResetOwnerKey: request.limitResetOwnerKey,
                        pendingWeeklyResetCandidate: admission?.pendingCandidate,
                        withheldSuccess: admission?.withheldSuccess)
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
        includeCredits: Bool = false,
        claudeOwnerCLIRecoveryOnly: Bool = false) -> ProviderFetchContext
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: provider,
            settings: self.settings,
            override: override)
        let sourceMode = Self.requestedSourceModeOverride ?? ProviderRegistry.resolvedSourceMode(
            provider: provider,
            settings: self.settings,
            account: account)
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
        let contextProvider = provider
        let publicationGeneration = self.providerRefreshPublicationContexts[provider.instanceID]?
            .generation
        let contextConfigRevision = self.settings.providerConfigRevision(for: provider)
        let originalAccountToken = account?.token
        let originalManualToken = provider == .stepfun ? self.settings.stepfunToken : nil
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: includeCredits,
            includeOptionalUsage: ProviderTokenAccountSelection.shouldIncludeOptionalUsage(
                provider: provider,
                settings: self.settings,
                override: override),
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: self.settings.isVerboseLoggingEnabled,
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
                    guard
                        self.providerConfigMutationIsCurrent(
                            provider: provider,
                            generation: publicationGeneration,
                            originalConfigRevision: contextConfigRevision)
                    else { return }
                    self.settings.updateTokenAccount(
                        provider: provider,
                        accountID: accountID,
                        token: token)
                    self.advanceProviderRefreshConfigRevision(
                        provider: provider,
                        generation: publicationGeneration)
                }
            },
            providerManualTokenUpdater: { [weak self] provider, token in
                await MainActor.run {
                    guard let self, provider == .stepfun,
                          self.settings.stepfunToken == originalManualToken
                    else { return }
                    guard
                        self.providerConfigMutationIsCurrent(
                            provider: provider,
                            generation: publicationGeneration,
                            originalConfigRevision: contextConfigRevision)
                    else { return }
                    self.settings.stepfunToken = token
                    self.advanceProviderRefreshConfigRevision(
                        provider: provider,
                        generation: publicationGeneration)
                }
            },
            costUsageHistoryDays: self.settings.costUsageHistoryDays,
            claudeOwnerCLIRecoveryOnly: claudeOwnerCLIRecoveryOnly,
            persistsCLISessions: true,
            persistentCLISessionIdleWindow: ProviderRegistry.persistentCLISessionIdleWindow(
                refreshInterval: self.normalRefreshIntervalForHeuristics()),
            resolvedCLIVersion: self.version(for: provider))
    }

    private func providerConfigMutationIsCurrent(
        provider: UsageProvider,
        generation: UInt64?,
        originalConfigRevision: UInt64) -> Bool
    {
        guard let generation else { return true }
        let currentConfigRevision = self.settings.providerConfigRevision(for: provider)
        guard let publication = self.providerRefreshPublicationContexts[provider.instanceID] else {
            return false
        }
        if publication.generation == generation {
            return publication.configRevision == currentConfigRevision
        }
        // A replacement waits for its predecessor before capturing fetch inputs. Let the predecessor persist an
        // authorized refresh token while its original config is unchanged; the replacement will then start from it.
        return originalConfigRevision == currentConfigRevision
    }

    private func advanceProviderRefreshConfigRevision(provider: UsageProvider, generation: UInt64?) {
        guard let generation,
              var publication = self.providerRefreshPublicationContexts[provider.instanceID],
              publication.generation == generation
        else { return }
        publication.configRevision = self.settings.providerConfigRevision(for: provider)
        self.providerRefreshPublicationContexts[provider.instanceID] = publication
    }

    func sourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        ProviderCatalog.implementation(for: provider)?
            .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: self.settings))
            ?? .auto
    }

    private struct ResolvedAccountOutcome {
        let snapshot: TokenAccountUsageSnapshot?
        let usage: UsageSnapshot?
        let freshUsage: UsageSnapshot?
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
        // Plan history remains display-only: its legacy provider and email keys cannot prove
        // the composite publication owner required for quota state.
        return snapshots
    }

    private func codexLastKnownResetSnapshot(for account: CodexVisibleAccount) -> UsageSnapshot? {
        guard let snapshot = self.lastKnownResetSnapshots[.codex],
              Self.codexVisibleAccountEmailMatches(snapshot: snapshot, account: account),
              Self.codexScopedGuard(self.lastCodexUsagePublicationGuard, matches: account)
        else {
            return nil
        }
        return snapshot
    }

    func codexLastKnownResetSnapshot(matching guardValue: CodexAccountScopedRefreshGuard?)
        -> UsageSnapshot?
    {
        guard let guardValue,
              let lastGuard = self.lastCodexUsagePublicationGuard,
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

    nonisolated static func codexPriorSnapshotAccountMatches(
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

    private nonisolated static func codexPriorAccountSnapshot(
        matching account: CodexVisibleAccount,
        in snapshots: [CodexAccountUsageSnapshot]) -> CodexAccountUsageSnapshot?
    {
        if let exact = snapshots.first(where: { $0.id == account.id }),
           self.codexPriorSnapshotAccountMatches(exact.account, account: account)
        {
            return exact
        }
        let matches = snapshots.filter {
            self.codexPriorSnapshotAccountMatches($0.account, account: account)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
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

    nonisolated static func codexScopedRefreshGuard(for account: CodexVisibleAccount)
        -> CodexAccountScopedRefreshGuard
    {
        let accountEmail = CodexIdentityResolver.normalizeEmail(account.email)
        return CodexAccountScopedRefreshGuard(
            source: account.selectionSource,
            identity: self.codexVisibleAccountIdentity(for: account),
            accountKey: accountEmail,
            authFingerprint: account.authFingerprint)
    }

    private nonisolated static func codexVisibleAccountIdentity(for account: CodexVisibleAccount)
        -> CodexIdentity
    {
        if let workspaceAccountID = self.normalizedCodexVisibleAccountText(account.workspaceAccountID) {
            return .providerAccount(
                id: CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID(workspaceAccountID))
        }
        return CodexIdentityResolver.resolve(accountId: nil, email: account.email)
    }

    private nonisolated static func normalizedCodexVisibleAccountText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
                sourceLabel: result.sourceLabel,
                cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account))
            return ResolvedAccountOutcome(snapshot: snapshot, usage: labeled, freshUsage: labeled)
        case let .failure(error):
            // Preserve the last-good snapshot when the refresh was cancelled (e.g. the
            // user switched menu tabs mid-flight). Without this the per-account list
            // would briefly render error chips for accounts that already had data.
            if Self.errorIsCancellation(error) {
                if let priorSnapshot, priorSnapshot.snapshot != nil {
                    return ResolvedAccountOutcome(
                        snapshot: priorSnapshot,
                        usage: priorSnapshot.snapshot,
                        freshUsage: nil)
                }
                // No usable prior data: skip this row entirely. The caller will
                // either preserve the existing per-account state or fall back to
                // the single live card. Rendering a "cancelled" placeholder here
                // produces visually duplicate cards with no useful data.
                return ResolvedAccountOutcome(snapshot: nil, usage: nil, freshUsage: nil)
            }
            // Provider-specific by design: Claude OAuth rate limits preserve a matching prior OAuth account snapshot.
            if provider == .claude,
               ClaudeUsageError.isClaudeOAuthUsageRateLimit(error),
               let priorSnapshot,
               priorSnapshot.sourceLabel == "oauth",
               priorSnapshot.cacheKey
               == self.tokenAccountSnapshotCacheKey(provider: provider, account: account),
               let priorUsage = priorSnapshot.snapshot
            {
                let snapshot = TokenAccountUsageSnapshot(
                    account: account,
                    snapshot: priorUsage,
                    error: nil,
                    sourceLabel: "oauth",
                    cacheKey: priorSnapshot.cacheKey)
                return ResolvedAccountOutcome(snapshot: snapshot, usage: priorUsage, freshUsage: nil)
            }
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: nil,
                error: self.tokenAccountSnapshotErrorMessage(error),
                sourceLabel: nil,
                cacheKey: self.tokenAccountSnapshotCacheKey(provider: provider, account: account))
            return ResolvedAccountOutcome(snapshot: snapshot, usage: nil, freshUsage: nil)
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
            if let resultEmail = CodexIdentityResolver.normalizeEmail(scoped.accountEmail(for: .codex)),
               resultEmail != CodexIdentityResolver.normalizeEmail(account.email)
            {
                return ResolvedCodexAccountOutcome(
                    snapshot: priorSnapshot,
                    usage: nil,
                    sourceLabel: priorSnapshot?.sourceLabel)
            }
            let labeled = self.applyCodexVisibleAccountLabel(scoped, account: account)
            let backfilled =
                Self.codexMergedResetBackfillSnapshot(resetBackfillSnapshots)
                .map { Self.codexBackfillingResetWindows(labeled, from: $0) } ?? labeled
            let credits = CodexMonthlyCreditPreservation.merging(
                incoming: result.credits,
                prior: priorSnapshot?.credits,
                enrichmentFailed: result.codexMonthlyLimitEnrichmentFailed)
            let enriched = CodexExtraUsageCost.attaching(to: backfilled, credits: credits)
            let snapshot = CodexAccountUsageSnapshot(
                account: account,
                snapshot: enriched,
                error: nil,
                sourceLabel: result.sourceLabel,
                credits: credits)
            return ResolvedCodexAccountOutcome(
                snapshot: snapshot,
                usage: enriched,
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
                    sourceLabel: priorSnapshot.sourceLabel,
                    credits: priorSnapshot.credits)
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

    static func shouldPreserveCodexAccountSnapshotOnFailure(_ message: String) -> Bool {
        guard CodexAccountHealth.status(forError: message) == .unavailable else { return false }
        let normalized = message.lowercased()
        return normalized.contains("network") || normalized.contains("internet connection")
            || normalized.contains("offline") || normalized.contains("timed out")
            || normalized.contains("timeout") || normalized.contains("connection was lost")
            || normalized.contains("could not connect") || normalized.contains("not connected")
            || normalized.contains("hostname") || normalized.contains("dns")
            || normalized.contains("temporarily unavailable")
    }

    func applySelectedCodexVisibleAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        account: CodexVisibleAccount,
        snapshot: UsageSnapshot?,
        sourceLabel: String?,
        limitResetOwnerKey: CodexLimitResetOwnerKey?,
        generation: UInt64? = nil) async
    {
        guard self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
        switch outcome.result {
        case let .success(result):
            guard let snapshot else { return }
            let publicationGuard = Self.codexScopedRefreshGuard(for: account)
            let codexOwnerKey = Self.codexSessionQuotaOwnerKey(for: publicationGuard)
            self.lastFetchAttempts[.codex] = outcome.attempts
            let publishedCredits = self.codexAccountSnapshots.first(where: { $0.id == account.id })?.credits
                ?? result.credits
            if self.shouldPublishSelectedCodexCredits(
                result,
                publishedCredits: publishedCredits,
                publicationGuard: publicationGuard)
            {
                self.credits = publishedCredits
                self.lastCreditsError = nil
                self.lastCreditsSnapshot = publishedCredits
                self.lastCreditsSnapshotAccountKey = publicationGuard.accountKey
                self.lastCreditsSnapshotOwnerGuard = publicationGuard
                self.lastCreditsSource = publishedCredits == nil ? .none : .api
            }
            self.handleCodexResetCreditNotifications(snapshot: snapshot)
            self.handleQuotaWarningTransitions(
                provider: .codex,
                snapshot: snapshot,
                accountDiscriminator: codexOwnerKey?.rawValue)
            self.handleSessionQuotaTransition(
                provider: .codex,
                snapshot: snapshot,
                codexOwnerKey: codexOwnerKey)
            self.handlePredictivePaceWarningTransitions(provider: .codex, snapshot: snapshot)
            self.lastKnownResetSnapshots[.codex] = snapshot
            self.lastCodexUsagePublicationGuard = publicationGuard
            self.lastCodexAccountScopedRefreshGuard = publicationGuard
            self.snapshots[.codex] = snapshot
            if let sourceLabel {
                self.lastSourceLabels[.codex] = sourceLabel
            }
            self.errors[.codex] = nil
            self.failureGates[.codex]?.recordSuccess()
            self.rememberLiveSystemCodexEmailIfNeeded(snapshot.accountEmail(for: .codex))
            self.seedCodexAccountScopedRefreshGuard(accountEmail: account.email)
            await self.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: limitResetOwnerKey)
            guard self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }
            self.recordCodexHistoricalSampleIfNeeded(snapshot: snapshot)
        case let .failure(error):
            guard let message = self.tokenAccountErrorMessage(error) else {
                self.errors[.codex] = nil
                return
            }
            let publicationGuard = Self.codexScopedRefreshGuard(for: account)
            self.lastCodexUsagePublicationGuard = publicationGuard
            self.lastCodexAccountScopedRefreshGuard = publicationGuard
            self.lastFetchAttempts[.codex] = outcome.attempts
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
        fallbackAccountSnapshot: TokenAccountUsageSnapshot? = nil,
        generation: UInt64? = nil) async
    {
        await MainActor.run {
            guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
            self.lastFetchAttempts[provider.instanceID] = outcome.attempts
        }
        guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else { return }
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let labeled: UsageSnapshot =
                if let account {
                    self.applyAccountLabel(scoped, provider: provider, account: account)
                } else {
                    scoped
                }
            let backfilled = await MainActor.run {
                guard self.isCurrentProviderRefreshGeneration(provider, generation: generation) else {
                    return nil as UsageSnapshot?
                }
                let profileStable =
                    provider == .deepseek
                        ? labeled.preservingDeepSeekPlatformProfiles(
                            from: self.presentationSnapshot(for: .deepseek))
                        : labeled
                let backfilled = profileStable.backfillingResetTimes(
                    from: self.lastKnownResetSnapshots[provider.instanceID])
                let warningAccountDiscriminator = Self.warningTokenAccountDiscriminator(account)
                self.handleQuotaWarningTransitions(
                    provider: provider,
                    snapshot: backfilled,
                    accountDiscriminator: warningAccountDiscriminator)
                self.handleSessionQuotaTransition(provider: provider, snapshot: backfilled)
                self.handlePredictivePaceWarningTransitions(
                    provider: provider,
                    snapshot: backfilled,
                    accountDiscriminatorOverride: provider == .claude ? warningAccountDiscriminator : nil)
                self.lastKnownResetSnapshots[provider.instanceID] = backfilled
                self.snapshots[provider.instanceID] = backfilled
                self.widgetUsagePreservationBlockedProviders.remove(provider.instanceID)
                if provider == .deepseek {
                    self.clearDeepSeekProfileTransition()
                }
                self.publishProviderDerivedTokenSnapshot(from: backfilled, for: provider)
                self.lastSourceLabels[provider.instanceID] = result.sourceLabel
                self.errors[provider.instanceID] = nil
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
                self.failureGates[provider.instanceID]?.recordSuccess()
                return backfilled
            }
            guard let backfilled else { return }
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: backfilled,
                account: account)
        case let .failure(error):
            await MainActor.run {
                if provider == .claude,
                   ClaudeUsageError.isClaudeOAuthUsageRateLimit(error),
                   let account,
                   let currentAccount = self.uniqueTokenAccount(provider: provider, accountID: account.id),
                   let fallbackAccountSnapshot,
                   fallbackAccountSnapshot.account.id == currentAccount.id,
                   fallbackAccountSnapshot.sourceLabel == "oauth",
                   fallbackAccountSnapshot.cacheKey
                   == self.tokenAccountSnapshotCacheKey(
                       provider: provider,
                       account: currentAccount),
                   let fallback = fallbackAccountSnapshot.snapshot
                {
                    self.snapshots[provider.instanceID] = fallback
                    self.lastKnownResetSnapshots[provider.instanceID] = fallback
                    self.lastSourceLabels[provider.instanceID] = "oauth"
                    self.cacheTokenAccountSnapshot(
                        provider: provider,
                        account: currentAccount,
                        snapshot: fallback,
                        sourceLabel: "oauth")
                    self.errors[provider.instanceID] = nil
                    self.failureGates[provider.instanceID]?.reset()
                    return
                }
                self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider.instanceID)
                if provider == .deepseek {
                    self.markDeepSeekProfileTransitionUnavailable()
                }
                guard let message = self.tokenAccountErrorMessage(error) else {
                    self.errors[provider.instanceID] = nil
                    return
                }
                let hadPriorData = self.snapshots[provider.instanceID] != nil || fallbackSnapshot != nil
                let shouldSurface =
                    self.failureGates[provider.instanceID]?
                        .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
                if shouldSurface {
                    self.errors[provider.instanceID] = message
                    self.snapshots.removeValue(forKey: provider.instanceID)
                    self.clearProviderDerivedTokenSnapshot(for: provider)
                } else {
                    self.errors[provider.instanceID] = nil
                }
            }
        }
    }
}

extension UsageStore {
    func tokenAccountRefreshPreparation(for provider: UsageProvider)
        -> (accounts: [ProviderTokenAccount], removesAccountAuthority: Bool)
    {
        let accounts = self.tokenAccounts(for: provider)
        let removesAccountAuthority =
            self.tokenAccountLiveStateProviders.contains(provider.instanceID)
            && self.settings.effectiveSelectedTokenAccount(for: provider) == nil
        return (accounts, removesAccountAuthority)
    }
}
