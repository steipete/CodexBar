import CodexBarCore
import Foundation

extension UsageStore {
    func prepareRefreshState(for provider: UsageProvider? = nil) {
        guard provider == nil || provider == .codex else { return }
        _ = self.settings.persistResolvedCodexActiveSourceCorrectionIfNeeded()
    }

    /// Force refresh Augment session (called from UI button)
    func forceRefreshAugmentSession() async {
        await self.performRuntimeAction(.forceSessionRefresh, for: .augment)
    }

    private func providerRefreshSpec(_ provider: UsageProvider) async -> ProviderSpec? {
        if let override = self._test_providerRefreshOverride {
            await override(provider)
            return nil
        }
        return self.providerSpecs[provider]
    }

    func refreshProvider(_ provider: UsageProvider, allowDisabled: Bool = false) async {
        self.prepareRefreshState(for: provider)
        guard let spec = await self.providerRefreshSpec(provider) else { return }
        let codexExpectedGuard = provider == .codex ? self.currentCodexAccountScopedRefreshGuard() : nil

        if !spec.isEnabled(), !allowDisabled {
            await self.clearDisabledProviderRefreshState(provider)
            return
        }

        self.refreshingProviders.insert(provider)
        defer { self.refreshingProviders.remove(provider) }

        if provider == .codex, self.shouldFetchAllCodexVisibleAccounts() {
            await self.refreshCodexVisibleAccountsForMenu()
            return
        } else if provider == .codex {
            self.codexAccountSnapshots = []
        }

        if provider == .kilo, self.shouldFanOutKiloScopes() {
            await self.refreshKiloScopes()
            // Continue to also fetch the personal snapshot through the regular path
            // so the existing single-card render keeps working when only personal is shown.
            // The presence of multi-element kiloScopeSnapshots triggers stacked rendering.
        } else if provider == .kilo {
            await MainActor.run { self.kiloScopeSnapshots = [] }
        }

        let tokenAccounts = self.tokenAccounts(for: provider)
        if self.shouldFetchAllTokenAccounts(provider: provider, accounts: tokenAccounts) {
            await self.refreshTokenAccounts(provider: provider, accounts: tokenAccounts)
            return
        } else {
            _ = await MainActor.run {
                self.accountSnapshots.removeValue(forKey: provider)
            }
        }

        let claudeAuthStateBeforeFetch = provider == .claude
            ? await Self.captureClaudeRefreshAuthState(invalidateCredentialsFile: true)
            : nil
        let fetchContext = spec.makeFetchContext()
        let descriptor = spec.descriptor
        // Keep provider fetch work off MainActor so slow keychain/process reads don't stall menu/UI responsiveness.
        let outcome = await withTaskGroup(
            of: ProviderFetchOutcome.self,
            returning: ProviderFetchOutcome.self)
        { group in
            group.addTask {
                await descriptor.fetchOutcome(context: fetchContext)
            }
            return await group.next()!
        }
        let claudeAuthFingerprintAfterFetch = provider == .claude
            ? await Self.captureClaudeAuthFingerprintToken()
            : nil
        let claudeAuthChangedDuringFetch = Self.claudeAuthChangedDuringFetch(
            provider: provider,
            beforeFetch: claudeAuthStateBeforeFetch,
            afterFetchFingerprintToken: claudeAuthFingerprintAfterFetch)
        await Self.invalidateClaudeCredentialsFileCacheIfNeeded(changedDuringFetch: claudeAuthChangedDuringFetch)
        let claudeCredentialsChanged = Self.claudeCredentialsChanged(
            beforeFetch: claudeAuthStateBeforeFetch,
            changedDuringFetch: claudeAuthChangedDuringFetch)
        let shouldConsumeClaudeKeychainFingerprint = Self.shouldConsumeClaudeKeychainFingerprintChange(
            beforeFetch: claudeAuthStateBeforeFetch,
            changedDuringFetch: claudeAuthChangedDuringFetch)
        await MainActor.run {
            self.lastFetchAttempts[provider] = outcome.attempts
        }

        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            if provider == .codex,
               let codexExpectedGuard,
               !self.shouldApplyCodexUsageResult(expectedGuard: codexExpectedGuard, usage: scoped)
            {
                return
            }
            let backfilled = await MainActor.run {
                if claudeCredentialsChanged {
                    self.clearClaudeCredentialDerivedStateForCredentialSwapNow()
                }
                let backfilled = scoped.backfillingResetTimes(from: self.lastKnownResetSnapshots[provider])
                self.handleQuotaWarningTransitions(provider: provider, snapshot: backfilled)
                self.handleSessionQuotaTransition(provider: provider, snapshot: backfilled)
                self.lastKnownResetSnapshots[provider] = backfilled
                self.snapshots[provider] = backfilled
                if let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: backfilled, provider: provider) {
                    self.tokenSnapshots[provider] = tokenSnapshot
                    self.tokenErrors[provider] = nil
                    self.tokenFailureGates[provider]?.recordSuccess()
                } else if Self.tokenCostRequiresProviderSnapshot(provider) {
                    self.tokenSnapshots.removeValue(forKey: provider)
                    self.tokenErrors[provider] = nil
                }
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
                if provider == .codex {
                    self.rememberLiveSystemCodexEmailIfNeeded(scoped.accountEmail(for: .codex))
                    self.seedCodexAccountScopedRefreshGuard(accountEmail: scoped.accountEmail(for: .codex))
                }
                return backfilled
            }
            if shouldConsumeClaudeKeychainFingerprint {
                _ = await Self.consumeClaudeKeychainFingerprintChangeWithoutPrompt()
            }
            await self.recordPlanUtilizationHistorySample(
                provider: provider,
                snapshot: backfilled)
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(
                    provider: provider, settings: self.settings, store: self)
                runtime.providerDidRefresh(context: context, provider: provider)
            }
            if provider == .codex {
                self.recordCodexHistoricalSampleIfNeeded(snapshot: backfilled)
            }
        case let .failure(error):
            if provider == .codex,
               let codexExpectedGuard,
               !self.shouldApplyCodexScopedFailure(expectedGuard: codexExpectedGuard)
            {
                return
            }
            self.recordStartupConnectivityRetryableFailure(error)
            if claudeCredentialsChanged {
                await self.clearClaudeCredentialDerivedStateForCredentialSwap()
            }
            if shouldConsumeClaudeKeychainFingerprint {
                _ = await Self.consumeClaudeKeychainFingerprintChangeWithoutPrompt()
            }
            await self.handleProviderFetchFailure(provider: provider, error: error)
        }
    }

    private func clearDisabledProviderRefreshState(_ provider: UsageProvider) async {
        self.refreshingProviders.remove(provider)
        await MainActor.run {
            self.snapshots.removeValue(forKey: provider)
            self.lastKnownResetSnapshots.removeValue(forKey: provider)
            self.errors[provider] = nil
            self.lastSourceLabels.removeValue(forKey: provider)
            self.lastFetchAttempts.removeValue(forKey: provider)
            self.accountSnapshots.removeValue(forKey: provider)
            if provider == .codex {
                self.codexAccountSnapshots = []
            }
            if provider == .kilo {
                self.kiloScopeSnapshots = []
            }
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.failureGates[provider]?.reset()
            self.tokenFailureGates[provider]?.reset()
            self.statuses.removeValue(forKey: provider)
            self.lastKnownSessionRemaining.removeValue(forKey: provider)
            self.lastKnownSessionWindowSource.removeValue(forKey: provider)
            self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider }
            self.lastTokenFetchAt.removeValue(forKey: provider)
        }
    }

    private struct ClaudeRefreshAuthState {
        let fingerprintToken: String
        let credentialsFileChanged: Bool
        let keychainFingerprintChanged: Bool
    }

    private nonisolated static func claudeCredentialsChanged(
        beforeFetch: ClaudeRefreshAuthState?,
        changedDuringFetch: Bool) -> Bool
    {
        beforeFetch?.credentialsFileChanged == true ||
            beforeFetch?.keychainFingerprintChanged == true ||
            changedDuringFetch
    }

    private nonisolated static func shouldConsumeClaudeKeychainFingerprintChange(
        beforeFetch: ClaudeRefreshAuthState?,
        changedDuringFetch: Bool) -> Bool
    {
        beforeFetch?.keychainFingerprintChanged == true || changedDuringFetch
    }

    private nonisolated static func claudeAuthChangedDuringFetch(
        provider: UsageProvider,
        beforeFetch: ClaudeRefreshAuthState?,
        afterFetchFingerprintToken: String?) -> Bool
    {
        provider == .claude && afterFetchFingerprintToken != beforeFetch?.fingerprintToken
    }

    private nonisolated static func captureClaudeRefreshAuthState(
        invalidateCredentialsFile: Bool) async -> ClaudeRefreshAuthState
    {
        await withTaskGroup(of: ClaudeRefreshAuthState.self, returning: ClaudeRefreshAuthState.self) { group in
            group.addTask {
                let fingerprintToken = ClaudeOAuthCredentialsStore.authFingerprintToken()
                let credentialsFileChanged = invalidateCredentialsFile
                    ? ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
                    : false
                let keychainFingerprintChanged = ClaudeOAuthCredentialsStore
                    .claudeKeychainFingerprintChangedWithoutConsuming()
                return ClaudeRefreshAuthState(
                    fingerprintToken: fingerprintToken,
                    credentialsFileChanged: credentialsFileChanged,
                    keychainFingerprintChanged: keychainFingerprintChanged)
            }
            return await group.next()!
        }
    }

    private nonisolated static func captureClaudeAuthFingerprintToken() async -> String {
        await withTaskGroup(of: String.self, returning: String.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.authFingerprintToken()
            }
            return await group.next()!
        }
    }

    private nonisolated static func invalidateClaudeCredentialsFileCacheIfChanged() async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
            }
            return await group.next()!
        }
    }

    private nonisolated static func invalidateClaudeCredentialsFileCacheIfNeeded(changedDuringFetch: Bool) async {
        guard changedDuringFetch else { return }
        _ = await self.invalidateClaudeCredentialsFileCacheIfChanged()
    }

    private nonisolated static func consumeClaudeKeychainFingerprintChangeWithoutPrompt() async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.consumeClaudeKeychainFingerprintChangeWithoutPrompt()
            }
            return await group.next()!
        }
    }

    private func clearClaudeCredentialDerivedStateForCredentialSwap() async {
        await MainActor.run {
            self.clearClaudeCredentialDerivedStateForCredentialSwapNow()
        }
    }

    private func clearClaudeCredentialDerivedStateForCredentialSwapNow() {
        self.snapshots.removeValue(forKey: .claude)
        self.lastKnownResetSnapshots.removeValue(forKey: .claude)
        self.errors[.claude] = nil
        self.lastSourceLabels.removeValue(forKey: .claude)
        self.accountSnapshots.removeValue(forKey: .claude)
        self.tokenSnapshots.removeValue(forKey: .claude)
        self.tokenErrors[.claude] = nil
        self.failureGates[.claude]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        self.lastKnownSessionRemaining.removeValue(forKey: .claude)
        self.lastKnownSessionWindowSource.removeValue(forKey: .claude)
        self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != .claude }
        self.lastTokenFetchAt.removeValue(forKey: .claude)
    }

    private func handleProviderFetchFailure(provider: UsageProvider, error: Error) async {
        let shouldNotifyPermissionPrompt = Self.isPermissionPromptWaiting(error)
        await MainActor.run {
            let hadPriorData = self.snapshots[provider] != nil
            let preservesPriorData = Self.shouldPreservePriorSnapshot(
                after: error,
                hadPriorData: hadPriorData)
            let shouldSurface =
                self.failureGates[provider]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
            let preservesClaudeWebSessionFailure =
                provider == .claude &&
                hadPriorData &&
                Self.isClaudeWebSessionRefreshFailure(error)
            if preservesClaudeWebSessionFailure,
               !shouldSurface
            {
                self.errors[provider] = nil
                return
            }
            if provider == .claude,
               preservesPriorData,
               Self.isClaudeUsageProbeTimeout(error)
            {
                self.errors[provider] = nil
                return
            }
            if preservesPriorData, !shouldSurface {
                self.errors[provider] = nil
                return
            }
            if shouldSurface {
                self.errors[provider] = error.localizedDescription
                if !preservesPriorData, !preservesClaudeWebSessionFailure {
                    self.snapshots.removeValue(forKey: provider)
                }
            } else {
                self.errors[provider] = nil
            }
            if shouldNotifyPermissionPrompt {
                self.postPermissionPromptNotificationIfNeeded(provider: provider, error: error)
            }
        }
        if let runtime = self.providerRuntimes[provider] {
            let context = ProviderRuntimeContext(
                provider: provider, settings: self.settings, store: self)
            runtime.providerDidFail(context: context, provider: provider, error: error)
        }
    }

    private static func shouldPreservePriorSnapshot(after error: Error, hadPriorData: Bool) -> Bool {
        guard hadPriorData else { return false }
        if error is CancellationError { return true }
        if self.isPreservableNetworkTransportError(error) { return true }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") ||
            message.contains("timeout") ||
            message.contains("cancelled") ||
            message.contains("network connection was lost") ||
            message.contains("not connected to the internet")
    }

    static func isPreservableNetworkTransportError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCancelled,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    static func startupConnectivityRetryDelay(forAttempt attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [15, 45, 120, 300]
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }

    static func isStartupConnectivityRetryableError(_ error: Error) -> Bool {
        if error is CancellationError { return false }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return true
            default:
                return false
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") ||
            message.contains("timeout") ||
            message.contains("network connection was lost") ||
            message.contains("not connected to the internet") ||
            message.contains("cannot find host") ||
            message.contains("cannot connect to host") ||
            message.contains("dns lookup")
    }

    private static func isClaudeUsageProbeTimeout(_ error: Error) -> Bool {
        if case ClaudeStatusProbeError.timedOut = error { return true }
        return error.localizedDescription == ClaudeStatusProbeError.timedOut.localizedDescription
    }

    private static func isClaudeWebSessionRefreshFailure(_ error: Error) -> Bool {
        if case ClaudeWebAPIFetcher.FetchError.unauthorized = error { return true }
        return error.localizedDescription == ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription
    }

    nonisolated static func isPermissionPromptWaiting(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return (message.contains("prompt") && message.contains("waiting")) ||
            message.contains("permission prompt") ||
            message.contains("folder trust prompt")
    }

    private func postPermissionPromptNotificationIfNeeded(provider: UsageProvider, error: Error) {
        let now = Date()
        if let last = self.lastPermissionPromptNotificationAt[provider],
           now.timeIntervalSince(last) < 10 * 60
        {
            return
        }
        self.lastPermissionPromptNotificationAt[provider] = now
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        AppNotifications.shared.post(
            idPrefix: "permission-prompt-\(provider.rawValue)",
            title: L("%@ is waiting for permission", providerName),
            body: error.localizedDescription,
            soundEnabled: false)
    }
}
