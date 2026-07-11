import CodexBarCore
import Foundation

enum CodexAccountScopedRefreshPhase {
    case invalidated
    case usage
    case credits
    case dashboard
    case completed
}

struct CodexAccountScopedRefreshGuard: Equatable {
    let source: CodexActiveSource
    let identity: CodexIdentity
    let accountKey: String?
    let authFingerprint: String?

    init(
        source: CodexActiveSource,
        identity: CodexIdentity,
        accountKey: String?,
        authFingerprint: String? = nil)
    {
        self.source = source
        self.identity = identity
        self.accountKey = CodexIdentityResolver.normalizeEmail(accountKey)
        self.authFingerprint = CodexAuthFingerprint.normalize(authFingerprint)
    }
}

@MainActor
extension UsageStore {
    func refreshCodexAccountScopedState(
        allowDisabled: Bool = false,
        phaseDidChange: (@MainActor (CodexAccountScopedRefreshPhase) -> Void)? = nil)
        async
    {
        let refreshStartedAt = Date()
        self.prepareRefreshState(for: .codex)
        if self.prepareCodexAccountScopedRefreshIfNeeded() {
            phaseDidChange?(.invalidated)
        }

        await self.refreshProvider(.codex, allowDisabled: allowDisabled)
        phaseDidChange?(.usage)
        await self.refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: refreshStartedAt)
        phaseDidChange?(.credits)

        if self.settings.codexCookieSource.isEnabled {
            let expectedGuard = self.freshCodexOpenAIWebRefreshGuard()
            await self.refreshOpenAIDashboardIfNeeded(
                force: true,
                expectedGuard: expectedGuard,
                bypassCoalescing: true,
                allowCodexUsageBackfill: true)
            phaseDidChange?(.dashboard)
        }

        if self.openAIDashboardRequiresLogin {
            await self.refreshProvider(.codex, allowDisabled: allowDisabled)
            phaseDidChange?(.usage)
            await self.refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: refreshStartedAt)
            phaseDidChange?(.credits)
        }

        self.persistWidgetSnapshot(reason: "codex-account-refresh")
        phaseDidChange?(.completed)
    }

    @discardableResult
    func prepareCodexAccountScopedRefreshIfNeeded(
        forceInvalidation: Bool = false,
        currentGuardOverride: CodexAccountScopedRefreshGuard? = nil) -> Bool
    {
        let currentGuard = currentGuardOverride ?? self.freshCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: false,
            allowLastKnownLiveFallback: false)
        let previousGuard = self.lastCodexAccountScopedRefreshGuard
        self.lastCodexAccountScopedRefreshGuard = currentGuard

        let accountChanged = previousGuard.map {
            !Self.codexScopedRefreshGuardsMatchAccount($0, currentGuard)
        } ?? false
        guard forceInvalidation || accountChanged else { return false }

        self.clearCodexPublishedUsageState()

        self.credits = nil
        self.lastCreditsError = nil
        self.lastCreditsSnapshot = nil
        self.lastCreditsSnapshotAccountKey = nil
        self.lastCreditsSource = .none
        self.creditsFailureStreak = 0

        self.clearCodexOpenAIWebStateForAccountTransition(targetEmail: self.codexAccountEmailForOpenAIDashboard())

        self.persistWidgetSnapshot(reason: "codex-account-invalidate")
        return true
    }

    func clearCodexPublishedUsageState() {
        self.snapshots.removeValue(forKey: .codex)
        self.errors[.codex] = nil
        self.lastSourceLabels.removeValue(forKey: .codex)
        self.lastFetchAttempts.removeValue(forKey: .codex)
        self.accountSnapshots.removeValue(forKey: .codex)
        // Visible-account rows carry their own owner and are reconciled against the current projection.
        // Clearing selected-account state must not discard valid sibling rows.
        self.failureGates[.codex]?.reset()
        self.lastKnownSessionRemaining.removeValue(forKey: .codex)
        self.lastKnownSessionWindowSource.removeValue(forKey: .codex)
        self.lastKnownResetSnapshots.removeValue(forKey: .codex)
        self.lastCodexUsagePublicationGuard = nil
    }

    @discardableResult
    func reconcileCodexPublishedUsageOwner(
        with currentGuard: CodexAccountScopedRefreshGuard,
        persistWidgetSnapshot: Bool = true) -> Bool
    {
        let hasPublishedUsageState = self.snapshots[.codex] != nil ||
            self.lastKnownResetSnapshots[.codex] != nil ||
            self.errors[.codex] != nil ||
            self.lastSourceLabels[.codex] != nil ||
            self.lastFetchAttempts[.codex] != nil
        guard hasPublishedUsageState else { return false }
        guard self.lastCodexUsagePublicationGuard.map({
            Self.codexScopedRefreshGuardsMatchAccount($0, currentGuard)
        }) == true
        else {
            self.clearCodexPublishedUsageState()
            if persistWidgetSnapshot {
                self.persistWidgetSnapshot(reason: "codex-account-invalidate")
            }
            return true
        }
        return false
    }

    func reconcileCodexAccountStateForUsageOwner(_ currentGuard: CodexAccountScopedRefreshGuard) {
        let clearedUsage = self.reconcileCodexPublishedUsageOwner(
            with: currentGuard,
            persistWidgetSnapshot: false)
        let invalidatedAccountState = self.prepareCodexAccountScopedRefreshIfNeeded(
            currentGuardOverride: currentGuard)
        if clearedUsage, !invalidatedAccountState {
            self.persistWidgetSnapshot(reason: "codex-account-invalidate")
        }
    }

    func seedCodexAccountScopedRefreshGuard(
        source: CodexActiveSource? = nil,
        accountEmail: String?)
    {
        let resolvedSource = source ?? self.settings.codexResolvedActiveSource
        let resolvedEmail = Self.normalizeCodexAccountScopedEmail(accountEmail)
        let currentIdentity = self.currentCodexRuntimeIdentity(
            source: resolvedSource,
            preferCurrentSnapshot: false,
            allowLastKnownLiveFallback: false)
        let resolvedIdentity = CodexIdentityMatcher.normalized(
            currentIdentity == .unresolved ? CodexIdentityResolver.resolve(accountId: nil, email: resolvedEmail) :
                currentIdentity,
            fallbackEmail: resolvedEmail ?? "")
        let accountKey = Self.normalizeCodexAccountScopedKey(resolvedEmail ?? Self.email(for: resolvedIdentity))
        guard resolvedIdentity != .unresolved || accountKey != nil else { return }
        self.lastCodexAccountScopedRefreshGuard = CodexAccountScopedRefreshGuard(
            source: resolvedSource,
            identity: resolvedIdentity,
            accountKey: accountKey,
            authFingerprint: self.currentCodexAuthFingerprint(source: resolvedSource))
    }

    func currentCodexAccountScopedRefreshGuard(
        preferCurrentSnapshot: Bool = true,
        allowLastKnownLiveFallback: Bool = true) -> CodexAccountScopedRefreshGuard
    {
        CodexAccountScopedRefreshGuard(
            source: self.settings.codexResolvedActiveSource,
            identity: self.currentCodexRuntimeIdentity(
                source: self.settings.codexResolvedActiveSource,
                preferCurrentSnapshot: preferCurrentSnapshot,
                allowLastKnownLiveFallback: allowLastKnownLiveFallback),
            accountKey: self.codexAccountScopedRefreshKey(
                preferCurrentSnapshot: preferCurrentSnapshot,
                allowLastKnownLiveFallback: allowLastKnownLiveFallback),
            authFingerprint: self.currentCodexAuthFingerprint(source: self.settings.codexResolvedActiveSource))
    }

    func currentCodexOpenAIWebRefreshGuard() -> CodexAccountScopedRefreshGuard {
        let source = self.settings.codexResolvedActiveSource
        let accountKey: String? = switch self.settings.codexResolvedActiveSource {
        case .liveSystem:
            Self
                .normalizeCodexAccountScopedKey(self.settings.codexAccountReconciliationSnapshot.liveSystemAccount?
                    .email)
        case .managedAccount:
            Self.normalizeCodexAccountScopedKey(self.currentManagedCodexRuntimeEmail())
        case let .profileHome(path):
            Self.normalizeCodexAccountScopedKey(self.currentProfileCodexRuntimeEmail(path: path))
        }
        return CodexAccountScopedRefreshGuard(
            source: source,
            identity: self.currentCodexOpenAIWebIdentity(source: source),
            accountKey: accountKey,
            authFingerprint: self.currentCodexAuthFingerprint(source: source))
    }

    func freshCodexAccountScopedRefreshGuard(
        preferCurrentSnapshot: Bool = true,
        allowLastKnownLiveFallback: Bool = true) -> CodexAccountScopedRefreshGuard
    {
        self.settings.invalidateCodexAccountReconciliationSnapshotCache()
        return self.currentCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: preferCurrentSnapshot,
            allowLastKnownLiveFallback: allowLastKnownLiveFallback)
    }

    func freshCodexOpenAIWebRefreshGuard() -> CodexAccountScopedRefreshGuard {
        self.settings.invalidateCodexAccountReconciliationSnapshotCache()
        return self.currentCodexOpenAIWebRefreshGuard()
    }

    func shouldApplyCodexUsageResult(
        expectedGuard: CodexAccountScopedRefreshGuard,
        usage: UsageSnapshot) -> Bool
    {
        let currentGuard = self.freshCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        let fingerprintsAllowApply = Self.codexGuardAuthFingerprintAllowsUsageApply(
            currentGuard,
            expectedGuard)
        let expectedAuthFingerprint = CodexAuthFingerprint.normalize(expectedGuard.authFingerprint)
        let currentAuthFingerprint = CodexAuthFingerprint.normalize(currentGuard.authFingerprint)
        let canProveNilToCurrentAuth = expectedAuthFingerprint == nil && currentAuthFingerprint != nil
        let resultIdentity = CodexIdentityResolver.resolve(accountId: nil, email: usage.accountEmail(for: .codex))
        let resultAccountKey = Self.normalizeCodexAccountScopedKey(usage.accountEmail(for: .codex))
        let resultMatchesCurrentAccountKey = Self.codexUsageResultAccountKeyMatchesCurrentGuard(
            resultAccountKey,
            expectedGuard: expectedGuard,
            currentGuard: currentGuard)

        if expectedGuard.identity != .unresolved {
            guard Self.codexGuardIdentityAndEmailMatch(currentGuard, expectedGuard) else { return false }
            guard resultMatchesCurrentAccountKey else { return false }
            if fingerprintsAllowApply {
                return true
            }
            guard canProveNilToCurrentAuth else { return false }
            return resultIdentity == currentGuard.identity ||
                (resultAccountKey != nil && resultAccountKey == currentGuard.accountKey)
        }

        if currentGuard.identity != .unresolved {
            guard resultIdentity == currentGuard.identity else { return false }
            return fingerprintsAllowApply || canProveNilToCurrentAuth
        }

        switch currentGuard.source {
        case .liveSystem:
            guard resultIdentity != .unresolved else { return false }
            if fingerprintsAllowApply {
                return true
            }
            guard canProveNilToCurrentAuth else { return false }
            guard let currentAccountKey = currentGuard.accountKey else { return true }
            return resultAccountKey == currentAccountKey
        case .managedAccount:
            return false
        case .profileHome:
            return false
        }
    }

    func shouldApplyCodexScopedFailure(expectedGuard: CodexAccountScopedRefreshGuard) -> Bool {
        let currentGuard = self.freshCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        guard Self.codexGuardAuthFingerprintMatches(currentGuard, expectedGuard) else { return false }

        if expectedGuard.identity != .unresolved {
            return Self.codexGuardIdentityAndEmailMatch(currentGuard, expectedGuard)
        }

        return currentGuard.identity == .unresolved
    }

    func codexScopedNonUsageSuccessApplyGuard(
        expectedGuard: CodexAccountScopedRefreshGuard) -> CodexAccountScopedRefreshGuard?
    {
        let currentGuard = self.freshCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return nil }
        guard Self.codexGuardAuthFingerprintAllowsUsageApply(currentGuard, expectedGuard) else { return nil }
        guard expectedGuard.identity != .unresolved else { return nil }
        guard Self.codexGuardIdentityAndEmailMatch(currentGuard, expectedGuard) else { return nil }
        return currentGuard
    }

    func shouldApplyCodexScopedNonUsageResult(expectedGuard: CodexAccountScopedRefreshGuard) -> Bool {
        self.codexScopedNonUsageSuccessApplyGuard(expectedGuard: expectedGuard) != nil
    }

    func shouldApplyCodexScopedNonUsageFailure(expectedGuard: CodexAccountScopedRefreshGuard) -> Bool {
        let currentGuard = self.freshCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        guard Self.codexGuardAuthFingerprintMatches(currentGuard, expectedGuard) else { return false }
        guard expectedGuard.identity != .unresolved else { return false }
        return Self.codexGuardIdentityAndEmailMatch(currentGuard, expectedGuard)
    }

    func shouldApplyOpenAIDashboardRefreshGuard(
        expectedGuard: CodexAccountScopedRefreshGuard,
        routingTargetEmail: String?) -> Bool
    {
        let normalizedRoutingTargetEmail = CodexIdentityResolver.normalizeEmail(routingTargetEmail)
        let currentGuard = self.freshCodexOpenAIWebRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        guard Self.codexGuardAuthFingerprintAllowsUsageApply(currentGuard, expectedGuard) else { return false }

        if expectedGuard.identity != .unresolved {
            return Self.codexGuardIdentityAndEmailMatch(currentGuard, expectedGuard)
        }

        guard case .liveSystem = expectedGuard.source else { return false }
        guard currentGuard.identity == .unresolved else { return false }
        return CodexIdentityResolver.normalizeEmail(
            self.currentCodexOpenAIWebTargetEmail(
                allowCurrentSnapshotFallback: true,
                allowLastKnownLiveFallback: false)) == normalizedRoutingTargetEmail
    }

    func shouldApplyOpenAIWebNonSuccessResult(
        expectedGuard: CodexAccountScopedRefreshGuard,
        routingTargetEmail: String?) -> Bool
    {
        let normalizedRoutingTargetEmail = CodexIdentityResolver.normalizeEmail(routingTargetEmail)
        let currentGuard = self.freshCodexOpenAIWebRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        guard Self.codexGuardAuthFingerprintMatches(currentGuard, expectedGuard) else { return false }

        if expectedGuard.identity != .unresolved {
            return Self.codexGuardIdentityAndEmailMatch(currentGuard, expectedGuard)
        }

        guard case .liveSystem = expectedGuard.source else { return false }
        guard currentGuard.identity == .unresolved else { return false }
        return CodexIdentityResolver.normalizeEmail(
            self.currentCodexOpenAIWebTargetEmail(
                allowCurrentSnapshotFallback: true,
                allowLastKnownLiveFallback: false)) == normalizedRoutingTargetEmail
    }

    func shouldApplyOpenAIDashboardPolicyResult(
        expectedGuard: CodexAccountScopedRefreshGuard,
        routingTargetEmail: String?) -> Bool
    {
        let normalizedRoutingTargetEmail = CodexIdentityResolver.normalizeEmail(routingTargetEmail)
        let currentGuard = self.freshCodexOpenAIWebRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }

        if expectedGuard.identity != .unresolved {
            if Self.codexGuardIdentityAndEmailMatch(currentGuard, expectedGuard) {
                return Self.codexGuardAuthFingerprintMatches(currentGuard, expectedGuard) ||
                    Self.codexGuardAuthFingerprintAllowsUsageApply(currentGuard, expectedGuard)
            }
            return Self.codexGuardAuthFingerprintAllowsProviderTransitionCleanup(currentGuard, expectedGuard)
        }

        guard case .liveSystem = expectedGuard.source else { return false }
        guard currentGuard.identity == .unresolved else { return false }
        guard Self.codexGuardAuthFingerprintMatches(currentGuard, expectedGuard) else { return false }
        return CodexIdentityResolver.normalizeEmail(
            self.currentCodexOpenAIWebTargetEmail(
                allowCurrentSnapshotFallback: true,
                allowLastKnownLiveFallback: false)) == normalizedRoutingTargetEmail
    }

    func codexDashboardKnownOwnerCandidates() -> [CodexDashboardKnownOwnerCandidate] {
        CodexKnownOwnerCatalog.candidates(from: self.settings.codexAccountReconciliationSnapshot)
    }

    func trustedCurrentCodexUsageEmailForDashboardAuthority() -> String? {
        guard let sourceLabel = self.lastSourceLabels[.codex], sourceLabel != "openai-web" else {
            return nil
        }
        return CodexIdentityResolver.normalizeEmail(self.snapshots[.codex]?.accountEmail(for: .codex))
    }

    func currentCodexDashboardExpectedScopedEmail() -> String? {
        switch self.settings.codexResolvedActiveSource {
        case .liveSystem:
            CodexIdentityResolver.normalizeEmail(
                self.settings.codexAccountReconciliationSnapshot.liveSystemAccount?.email)
        case .managedAccount:
            CodexIdentityResolver.normalizeEmail(self.currentManagedCodexRuntimeEmail())
        case let .profileHome(path):
            CodexIdentityResolver.normalizeEmail(self.currentProfileCodexRuntimeEmail(path: path))
        }
    }

    func makeCodexDashboardAuthorityInput(
        dashboard: OpenAIDashboardSnapshot,
        sourceKind: CodexDashboardSourceKind,
        routingTargetEmail: String?) -> CodexDashboardAuthorityInput
    {
        let source = self.settings.codexResolvedActiveSource
        return CodexDashboardAuthorityInput(
            sourceKind: sourceKind,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: self.currentCodexOpenAIWebIdentity(source: source),
                expectedScopedEmail: self.currentCodexDashboardExpectedScopedEmail(),
                trustedCurrentUsageEmail: self.trustedCurrentCodexUsageEmailForDashboardAuthority(),
                dashboardSignedInEmail: dashboard.signedInEmail,
                knownOwners: self.codexDashboardKnownOwnerCandidates()),
            routing: CodexDashboardRoutingHints(
                targetEmail: CodexIdentityResolver.normalizeEmail(routingTargetEmail),
                lastKnownDashboardRoutingEmail: CodexIdentityResolver.normalizeEmail(
                    self.lastKnownLiveSystemCodexEmail)))
    }

    func evaluateCodexDashboardAuthority(
        dashboard: OpenAIDashboardSnapshot,
        sourceKind: CodexDashboardSourceKind,
        routingTargetEmail: String?) -> (input: CodexDashboardAuthorityInput, decision: CodexDashboardAuthorityDecision)
    {
        let input = self.makeCodexDashboardAuthorityInput(
            dashboard: dashboard,
            sourceKind: sourceKind,
            routingTargetEmail: routingTargetEmail)
        return (input, CodexDashboardAuthority.evaluate(input))
    }

    func codexDashboardAttachmentEmail(from input: CodexDashboardAuthorityInput) -> String? {
        CodexIdentityResolver.normalizeEmail(
            input.proof.expectedScopedEmail ??
                input.proof.trustedCurrentUsageEmail ??
                input.proof.dashboardSignedInEmail)
    }

    func rememberLiveSystemCodexEmailIfNeeded(_ email: String?) {
        guard case .liveSystem = self.settings.codexResolvedActiveSource else { return }
        guard let normalized = Self.normalizeCodexAccountScopedEmail(email) else { return }
        self.lastKnownLiveSystemCodexEmail = normalized
    }

    nonisolated static func codexGuardAuthFingerprintMatches(
        _ lhs: CodexAccountScopedRefreshGuard,
        _ rhs: CodexAccountScopedRefreshGuard) -> Bool
    {
        let lhsFingerprint = CodexAuthFingerprint.normalize(lhs.authFingerprint)
        let rhsFingerprint = CodexAuthFingerprint.normalize(rhs.authFingerprint)
        if lhsFingerprint != nil || rhsFingerprint != nil {
            return lhsFingerprint == rhsFingerprint
        }
        return true
    }

    nonisolated static func codexGuardAuthFingerprintAllowsUsageApply(
        _ lhs: CodexAccountScopedRefreshGuard,
        _ rhs: CodexAccountScopedRefreshGuard) -> Bool
    {
        if self.codexGuardAuthFingerprintMatches(lhs, rhs) {
            return true
        }
        let lhsFingerprint = CodexAuthFingerprint.normalize(lhs.authFingerprint)
        let rhsFingerprint = CodexAuthFingerprint.normalize(rhs.authFingerprint)
        guard lhsFingerprint != nil, rhsFingerprint != nil else { return false }
        guard case .providerAccount = rhs.identity,
              self.codexGuardIdentityAndEmailMatch(lhs, rhs)
        else { return false }
        guard case .liveSystem = lhs.source else { return true }
        return true
    }

    private nonisolated static func codexGuardAuthFingerprintAllowsProviderTransitionCleanup(
        _ lhs: CodexAccountScopedRefreshGuard,
        _ rhs: CodexAccountScopedRefreshGuard) -> Bool
    {
        let lhsFingerprint = CodexAuthFingerprint.normalize(lhs.authFingerprint)
        let rhsFingerprint = CodexAuthFingerprint.normalize(rhs.authFingerprint)
        guard let lhsFingerprint, let rhsFingerprint, lhsFingerprint != rhsFingerprint else { return false }
        guard case .providerAccount = rhs.identity else { return false }
        guard lhs.identity == rhs.identity else { return false }
        guard let lhsEmail = CodexIdentityResolver.normalizeEmail(lhs.accountKey),
              let rhsEmail = CodexIdentityResolver.normalizeEmail(rhs.accountKey)
        else { return false }
        return lhsEmail != rhsEmail
    }

    nonisolated static func codexScopedRefreshGuardsMatchAccount(
        _ lhs: CodexAccountScopedRefreshGuard,
        _ rhs: CodexAccountScopedRefreshGuard) -> Bool
    {
        guard lhs.source == rhs.source else { return false }
        if lhs == rhs {
            guard case .providerAccount = lhs.identity else { return true }
            return self.codexGuardIdentityAndEmailMatch(lhs, rhs)
        }
        guard lhs.identity != .unresolved,
              self.codexGuardIdentityAndEmailMatch(lhs, rhs),
              lhs.accountKey == rhs.accountKey
        else {
            return false
        }
        return self.codexGuardAuthFingerprintAllowsUsageApply(lhs, rhs)
    }

    private nonisolated static func codexGuardIdentityAndEmailMatch(
        _ lhs: CodexAccountScopedRefreshGuard,
        _ rhs: CodexAccountScopedRefreshGuard) -> Bool
    {
        guard lhs.identity == rhs.identity else { return false }
        guard case .providerAccount = lhs.identity else { return true }
        guard let lhsEmail = CodexIdentityResolver.normalizeEmail(lhs.accountKey),
              let rhsEmail = CodexIdentityResolver.normalizeEmail(rhs.accountKey)
        else { return false }
        return lhsEmail == rhsEmail
    }

    private nonisolated static func codexUsageResultAccountKeyMatchesCurrentGuard(
        _ resultAccountKey: String?,
        expectedGuard: CodexAccountScopedRefreshGuard,
        currentGuard: CodexAccountScopedRefreshGuard) -> Bool
    {
        guard let currentAccountKey = currentGuard.accountKey else { return true }
        guard let resultAccountKey else {
            guard let expectedAccountKey = expectedGuard.accountKey else { return true }
            return expectedAccountKey == currentAccountKey
        }
        return resultAccountKey == currentAccountKey
    }

    func currentCodexAuthFingerprint(source: CodexActiveSource) -> String? {
        let snapshot = self.settings.codexAccountReconciliationSnapshot
        switch source {
        case .liveSystem:
            return CodexAuthFingerprint.normalize(snapshot.liveSystemAccount?.authFingerprint)
        case let .managedAccount(id):
            guard let account = snapshot.storedAccounts.first(where: { $0.id == id }) else { return nil }
            return CodexAuthFingerprint.fingerprint(homePath: account.managedHomePath)
        case let .profileHome(path):
            guard let profileAccount = snapshot.profileHomeAccount(path: path) else {
                guard let normalizedPath = CodexHomeScope.normalizedHomePath(path) else { return nil }
                return CodexAuthFingerprint.fingerprint(homePath: normalizedPath)
            }
            return CodexAuthFingerprint.normalize(profileAccount.authFingerprint)
        }
    }

    func codexAccountScopedRefreshKey(
        preferCurrentSnapshot: Bool = true,
        allowLastKnownLiveFallback: Bool = true) -> String?
    {
        Self.normalizeCodexAccountScopedKey(
            self.codexAccountScopedRefreshEmail(
                preferCurrentSnapshot: preferCurrentSnapshot,
                allowLastKnownLiveFallback: allowLastKnownLiveFallback))
    }

    func codexAccountScopedRefreshEmail(
        preferCurrentSnapshot: Bool = true,
        allowLastKnownLiveFallback: Bool = true) -> String?
    {
        switch self.settings.codexResolvedActiveSource {
        case .liveSystem:
            let liveSystem = Self.normalizeCodexAccountScopedEmail(
                self.settings.codexAccountReconciliationSnapshot.liveSystemAccount?.email)
            if let liveSystem {
                self.lastKnownLiveSystemCodexEmail = liveSystem
                return liveSystem
            }

            if preferCurrentSnapshot,
               let snapshotEmail = Self
                   .normalizeCodexAccountScopedEmail(self.snapshots[.codex]?.accountEmail(for: .codex))
            {
                self.lastKnownLiveSystemCodexEmail = snapshotEmail
                return snapshotEmail
            }

            if allowLastKnownLiveFallback,
               let lastKnown = Self.normalizeCodexAccountScopedEmail(self.lastKnownLiveSystemCodexEmail)
            {
                return lastKnown
            }

            return nil
        case .managedAccount:
            if self.settings.codexSettingsSnapshot(tokenOverride: nil).managedAccountStoreUnreadable {
                return nil
            }
            return self.currentManagedCodexRuntimeEmail()
        case let .profileHome(path):
            return self.currentProfileCodexRuntimeEmail(path: path)
        }
    }

    func currentCodexRuntimeIdentity(
        source: CodexActiveSource,
        preferCurrentSnapshot: Bool,
        allowLastKnownLiveFallback: Bool) -> CodexIdentity
    {
        switch source {
        case .liveSystem:
            if let liveSystem = self.settings.codexAccountReconciliationSnapshot.liveSystemAccount {
                return self.settings.codexAccountReconciliationSnapshot.runtimeIdentity(for: liveSystem)
            }

            if preferCurrentSnapshot,
               let snapshotEmail = Self
                   .normalizeCodexAccountScopedEmail(self.snapshots[.codex]?.accountEmail(for: .codex))
            {
                self.lastKnownLiveSystemCodexEmail = snapshotEmail
                return CodexIdentityResolver.resolve(accountId: nil, email: snapshotEmail)
            }

            if allowLastKnownLiveFallback,
               let lastKnown = Self.normalizeCodexAccountScopedEmail(self.lastKnownLiveSystemCodexEmail)
            {
                return CodexIdentityResolver.resolve(accountId: nil, email: lastKnown)
            }

            return .unresolved
        case .managedAccount:
            guard !self.settings.codexSettingsSnapshot(tokenOverride: nil).managedAccountStoreUnreadable else {
                return .unresolved
            }
            guard let activeStoredAccount = self.settings.codexAccountReconciliationSnapshot.activeStoredAccount else {
                return .unresolved
            }
            return self.settings.codexAccountReconciliationSnapshot.runtimeIdentity(for: activeStoredAccount)
        case let .profileHome(path):
            guard let profileAccount = self.settings.codexAccountReconciliationSnapshot.profileHomeAccount(path: path)
            else {
                return .unresolved
            }
            return self.settings.codexAccountReconciliationSnapshot.runtimeIdentity(for: profileAccount)
        }
    }

    private func currentCodexOpenAIWebIdentity(source: CodexActiveSource) -> CodexIdentity {
        switch source {
        case .liveSystem:
            guard let liveSystem = self.settings.codexAccountReconciliationSnapshot.liveSystemAccount else {
                return .unresolved
            }
            return self.settings.codexAccountReconciliationSnapshot.runtimeIdentity(for: liveSystem)
        case .managedAccount:
            guard !self.settings.codexSettingsSnapshot(tokenOverride: nil).managedAccountStoreUnreadable else {
                return .unresolved
            }
            guard let activeStoredAccount = self.settings.codexAccountReconciliationSnapshot.activeStoredAccount else {
                return .unresolved
            }
            return self.settings.codexAccountReconciliationSnapshot.runtimeIdentity(for: activeStoredAccount)
        case let .profileHome(path):
            guard let profileAccount = self.settings.codexAccountReconciliationSnapshot.profileHomeAccount(path: path)
            else {
                return .unresolved
            }
            return self.settings.codexAccountReconciliationSnapshot.runtimeIdentity(for: profileAccount)
        }
    }

    func currentManagedCodexRuntimeEmail() -> String? {
        guard !self.settings.codexSettingsSnapshot(tokenOverride: nil).managedAccountStoreUnreadable else {
            return nil
        }
        guard let activeStoredAccount = self.settings.codexAccountReconciliationSnapshot.activeStoredAccount else {
            return nil
        }
        return Self.normalizeCodexAccountScopedEmail(
            self.settings.codexAccountReconciliationSnapshot.runtimeEmail(for: activeStoredAccount))
    }

    func currentProfileCodexRuntimeEmail(path: String) -> String? {
        guard let profileAccount = self.settings.codexAccountReconciliationSnapshot.profileHomeAccount(path: path)
        else {
            return nil
        }
        return Self.normalizeCodexAccountScopedEmail(profileAccount.email)
    }

    private func clearCodexOpenAIWebStateForAccountTransition(targetEmail: String?) {
        self.invalidateOpenAIDashboardRefreshTask()
        if self.settings.codexCookieSource.isEnabled,
           let normalizedTarget = Self.normalizeCodexAccountScopedEmail(targetEmail)
        {
            let scope = self.codexCookieCacheScopeForOpenAIWeb()
            let isolationKey = Self.openAIWebTargetIsolationKey(email: normalizedTarget, scope: scope)
            let previousIsolationKey = self.lastOpenAIDashboardTargetIsolationKey
            self.lastOpenAIDashboardTargetEmail = normalizedTarget
            self.lastOpenAIDashboardTargetIsolationKey = isolationKey
            if let previousIsolationKey, previousIsolationKey != isolationKey {
                self.openAIWebAccountDidChange = true
                self.openAIDashboardCookieImportStatus = L("Codex account changed; importing browser cookies…")
            } else {
                self.openAIDashboardCookieImportStatus = nil
            }
            self.openAIDashboardRequiresLogin = true
        } else {
            self.lastOpenAIDashboardTargetEmail = Self.normalizeCodexAccountScopedEmail(targetEmail)
            self.lastOpenAIDashboardTargetIsolationKey = nil
            self.openAIWebAccountDidChange = false
            self.openAIDashboardRequiresLogin = false
            self.openAIDashboardCookieImportStatus = nil
        }

        self.openAIDashboard = nil
        self.openAIDashboardAttachmentAuthorized = false
        self.lastOpenAIDashboardSnapshot = nil
        self.lastOpenAIDashboardAttachmentAuthorized = false
        self.lastOpenAIDashboardError = nil
        self.openAIDashboardCookieImportDebugLog = nil
        self.lastOpenAIDashboardCookieImportAttemptAt = nil
        self.lastOpenAIDashboardCookieImportEmail = nil
    }

    static func normalizeCodexAccountScopedEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func normalizeCodexAccountScopedKey(_ email: String?) -> String? {
        self.normalizeCodexAccountScopedEmail(email)?.lowercased()
    }

    static func codexIdentityGuardKey(_ identity: CodexIdentity) -> String? {
        switch identity {
        case let .providerAccount(id):
            "provider:\(id)"
        case let .emailOnly(normalizedEmail):
            "email:\(normalizedEmail)"
        case .unresolved:
            nil
        }
    }

    private static func email(for identity: CodexIdentity) -> String? {
        switch identity {
        case .providerAccount, .unresolved:
            nil
        case let .emailOnly(normalizedEmail):
            normalizedEmail
        }
    }
}
