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
            let expectedGuard = self.currentCodexAccountScopedRefreshGuard()
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
        self.creditsFailureStreak = 0

        self.clearCodexOpenAIWebStateForAccountTransition(targetEmail: self.codexAccountEmailForOpenAIDashboard())

        self.persistWidgetSnapshot(reason: "codex-account-invalidate")
        return true
    }

    func seedCodexAccountScopedRefreshGuard(
        source: CodexActiveSource? = nil,
        accountEmail: String?)
    {
        guard let accountKey = Self.normalizeCodexAccountScopedKey(accountEmail) else { return }
        self.lastCodexAccountScopedRefreshGuard = CodexAccountScopedRefreshGuard(
            source: source ?? self.settings.codexResolvedActiveSource,
            accountKey: accountKey)
    }

    func currentCodexAccountScopedRefreshGuard(
        preferCurrentSnapshot: Bool = true,
        allowLastKnownLiveFallback: Bool = true) -> CodexAccountScopedRefreshGuard
    {
        CodexAccountScopedRefreshGuard(
            source: self.settings.codexResolvedActiveSource,
            accountKey: self.codexAccountScopedRefreshKey(
                preferCurrentSnapshot: preferCurrentSnapshot,
                allowLastKnownLiveFallback: allowLastKnownLiveFallback))
    }

    func currentCodexOpenAIWebRefreshGuard() -> CodexAccountScopedRefreshGuard {
        let accountKey: String? = switch self.settings.codexResolvedActiveSource {
        case .liveSystem:
            Self
                .normalizeCodexAccountScopedKey(self.settings.codexAccountReconciliationSnapshot.liveSystemAccount?
                    .email)
        case .managedAccount:
            Self.normalizeCodexAccountScopedKey(self.settings.activeManagedCodexAccount?.email)
        }
        return CodexAccountScopedRefreshGuard(
            source: self.settings.codexResolvedActiveSource,
            accountKey: accountKey)
    }

    func shouldApplyCodexUsageResult(
        expectedGuard: CodexAccountScopedRefreshGuard,
        usage: UsageSnapshot) -> Bool
    {
        let currentGuard = self.currentCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }

        if let expectedKey = expectedGuard.accountKey {
            return currentGuard.accountKey == expectedKey
        }

        let resultKey = Self.normalizeCodexAccountScopedKey(usage.accountEmail(for: .codex))
        if let currentKey = currentGuard.accountKey {
            return resultKey == currentKey
        }

        switch currentGuard.source {
        case .liveSystem:
            return resultKey != nil
        case .managedAccount:
            return false
        }
    }

    func shouldApplyCodexScopedFailure(expectedGuard: CodexAccountScopedRefreshGuard) -> Bool {
        let currentGuard = self.currentCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }

        if let expectedKey = expectedGuard.accountKey {
            return currentGuard.accountKey == expectedKey
        }

        return currentGuard.accountKey == nil
    }

    func shouldApplyCodexScopedNonUsageResult(expectedGuard: CodexAccountScopedRefreshGuard) -> Bool {
        let currentGuard = self.currentCodexAccountScopedRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        guard let expectedKey = expectedGuard.accountKey else { return false }
        return currentGuard.accountKey == expectedKey
    }

    func shouldApplyOpenAIDashboardResult(
        expectedGuard: CodexAccountScopedRefreshGuard,
        dashboardAccountEmail: String?) -> Bool
    {
        if let expectedKey = expectedGuard.accountKey {
            let currentGuard = self.currentCodexAccountScopedRefreshGuard()
            guard currentGuard.source == expectedGuard.source else { return false }
            return currentGuard.accountKey == expectedKey
        }

        let currentGuard = self.currentCodexOpenAIWebRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        guard case .liveSystem = expectedGuard.source else { return false }
        guard currentGuard.accountKey == nil else { return false }
        guard let dashboardKey = Self.normalizeCodexAccountScopedKey(dashboardAccountEmail) else { return false }
        let currentTargetKey = Self.normalizeCodexAccountScopedKey(self.currentCodexOpenAIWebTargetEmail(
            allowCurrentSnapshotFallback: true,
            allowLastKnownLiveFallback: false))
        if let currentTargetKey {
            return dashboardKey == currentTargetKey
        }
        return true
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
            return Self.normalizeCodexAccountScopedEmail(self.settings.activeManagedCodexAccount?.email)
        }
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
        self.lastOpenAIDashboardSnapshot = nil
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
}
