import CodexBarCore
import Foundation

enum CodexAccountScopedRefreshPhase: Sendable {
    case invalidated
    case usage
    case credits
    case dashboard
    case completed
}

struct CodexAccountScopedRefreshGuard: Equatable, Sendable {
    let source: CodexActiveSource
    let identity: CodexIdentity
    let accountKey: String?
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
            let expectedGuard = self.currentCodexOpenAIWebRefreshGuard()
            await self.refreshOpenAIDashboardIfNeeded(
                force: true,
                expectedGuard: expectedGuard,
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
    func prepareCodexAccountScopedRefreshIfNeeded() -> Bool {
        let currentGuard = self.currentCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: false,
            allowLastKnownLiveFallback: false)
        let previousGuard = self.lastCodexAccountScopedRefreshGuard
        self.lastCodexAccountScopedRefreshGuard = currentGuard

        guard previousGuard != nil, previousGuard != currentGuard else { return false }

        self.snapshots.removeValue(forKey: .codex)
        self.errors[.codex] = nil
        self.lastSourceLabels.removeValue(forKey: .codex)
        self.lastFetchAttempts.removeValue(forKey: .codex)
        self.accountSnapshots.removeValue(forKey: .codex)
        self.failureGates[.codex]?.reset()
        self.lastKnownSessionRemaining.removeValue(forKey: .codex)
        self.lastKnownSessionWindowSource.removeValue(forKey: .codex)

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
            accountKey: accountKey)
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
                allowLastKnownLiveFallback: allowLastKnownLiveFallback))
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
        }
        return CodexAccountScopedRefreshGuard(
            source: source,
            identity: self.currentCodexOpenAIWebIdentity(source: source),
            accountKey: accountKey)
    }

    func shouldApplyCodexUsageResult(
        expectedGuard: CodexAccountScopedRefreshGuard,
        usage: UsageSnapshot) -> Bool
    {
        let currentGuard = self.currentCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }

        if expectedGuard.identity != .unresolved {
            return currentGuard.identity == expectedGuard.identity
        }

        let resultIdentity = CodexIdentityResolver.resolve(accountId: nil, email: usage.accountEmail(for: .codex))
        if currentGuard.identity != .unresolved {
            return resultIdentity == currentGuard.identity
        }

        switch currentGuard.source {
        case .liveSystem:
            return resultIdentity != .unresolved
        case .managedAccount:
            return false
        }
    }

    func shouldApplyCodexScopedFailure(expectedGuard: CodexAccountScopedRefreshGuard) -> Bool {
        let currentGuard = self.currentCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }

        if expectedGuard.identity != .unresolved {
            return currentGuard.identity == expectedGuard.identity
        }

        return currentGuard.identity == .unresolved
    }

    func shouldApplyCodexScopedNonUsageResult(expectedGuard: CodexAccountScopedRefreshGuard) -> Bool {
        let currentGuard = self.currentCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        guard expectedGuard.identity != .unresolved else { return false }
        return currentGuard.identity == expectedGuard.identity
    }

    func shouldApplyOpenAIDashboardRefreshGuard(
        expectedGuard: CodexAccountScopedRefreshGuard,
        routingTargetEmail: String?) -> Bool
    {
        let normalizedRoutingTargetEmail = CodexIdentityResolver.normalizeEmail(routingTargetEmail)
        let currentGuard = self.currentCodexOpenAIWebRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }

        if expectedGuard.identity != .unresolved {
            return currentGuard.identity == expectedGuard.identity
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
        self.shouldApplyOpenAIDashboardRefreshGuard(
            expectedGuard: expectedGuard,
            routingTargetEmail: routingTargetEmail)
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

    private func clearCodexOpenAIWebStateForAccountTransition(targetEmail: String?) {
        self.invalidateOpenAIDashboardRefreshTask()
        if self.settings.codexCookieSource.isEnabled,
           let normalizedTarget = Self.normalizeCodexAccountScopedEmail(targetEmail)
        {
            let previous = self.lastOpenAIDashboardTargetEmail
            self.lastOpenAIDashboardTargetEmail = normalizedTarget
            if let previous, !previous.isEmpty, previous != normalizedTarget {
                self.openAIWebAccountDidChange = true
                self.openAIDashboardCookieImportStatus = "Codex account changed; importing browser cookies…"
            } else {
                self.openAIDashboardCookieImportStatus = nil
            }
            self.openAIDashboardRequiresLogin = true
        } else {
            self.lastOpenAIDashboardTargetEmail = Self.normalizeCodexAccountScopedEmail(targetEmail)
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
