import CodexBarCore
import Foundation

/// Opt-in Codex window keep-alive: after the 5-hour window expires, send one tiny `codex exec` prompt so the next
/// window starts right away even when nobody is using Codex. Provider-specific by design.
extension UsageStore {
    /// Windows longer than this are weekly/monthly lanes, never the 5h session window.
    nonisolated static let codexWindowKeepAliveMaximumWindowMinutes = 12 * 60
    /// A refreshed reset later than the expired boundary by more than this means a new window already started.
    nonisolated static let codexWindowKeepAliveResetToleranceSeconds: TimeInterval = 60
    /// Give the backend a moment to register the new window before reading usage again.
    nonisolated static let codexWindowKeepAliveFollowUpRefreshDelaySeconds: TimeInterval = 5

    enum CodexWindowKeepAliveSkipReason: Equatable, Sendable {
        case disabled
        case notCodexSessionWindow
        case codexDisabled
        case manualRefreshCadence
        case lowPowerMode
        /// The selected managed workspace differs from what `auth.json` names. `codex exec` only receives
        /// `CODEX_HOME`, so the paid request would land in the auth-file workspace instead of the displayed one.
        case managedWorkspaceUnsupported
        /// No readable ChatGPT login in the selected `CODEX_HOME`, so there is no identity to bind the ping to.
        case loginUnavailable
        /// `auth.json` holds an `OPENAI_API_KEY`. API keys have no 5-hour window and would be billed per request;
        /// the ping only ever spends a ChatGPT subscription window.
        case apiKeyLoginUnsupported
        case alreadyAttempted
        case snapshotMissing
        /// The boundary pass did not publish a fresh Codex snapshot (fetch failed and the prior one was kept),
        /// so the expired reset it shows proves nothing about the current window.
        case snapshotStale
        case newWindowAlreadyStarted
    }

    /// The exact login the ping is allowed to spend. Captured when the boundary admits the ping and compared again
    /// right before launch, so a replacement login inside the same `CODEX_HOME` (identical environment, different
    /// `auth.json`) can never inherit an earlier admission.
    struct CodexWindowKeepAliveAuthority: Equatable, Sendable {
        /// The selected account's `CODEX_HOME` fetch environment handed to `codex exec`.
        var environment: [String: String]
        /// SHA-256 of the `auth.json` bytes the CLI will read.
        var authFingerprint: String
        /// `accountId` of the ChatGPT login when the auth file carries one.
        var accountID: String?
        /// `auth.json` holds `OPENAI_API_KEY` instead of ChatGPT tokens.
        var isAPIKeyLogin: Bool
    }

    /// Everything the pure decision needs, gathered by `scheduleCodexWindowKeepAliveIfNeeded` from live state.
    struct CodexWindowKeepAliveContext: Sendable {
        var enabled: Bool
        var window: ResetBoundaryWindow
        var codexEnabled: Bool
        var refreshCadenceIsManual: Bool
        var lowPowerModeEnabled: Bool
        /// `ProviderSettingsSnapshot.CodexProviderSettings.managedWorkspaceAccountID` for the selected account.
        var selectedManagedWorkspaceID: String?
        /// The login currently readable from the selected `CODEX_HOME`; nil when there is none.
        var authority: CodexWindowKeepAliveAuthority?
        var attemptedBoundaries: Set<Date>
        var refreshedSnapshot: UsageSnapshot?
        /// When the boundary refresh pass began; a fresh publication must be at or after this instant.
        var refreshStartedAt: Date
        /// When the store last published a successfully fetched Codex snapshot.
        var snapshotPublishedAt: Date?
    }

    /// Reads the login `codex exec` would use for `environment`: the `auth.json` in the selected `CODEX_HOME`
    /// (ambient `~/.codex` when unset). Fails closed (nil) when the file is missing, unreadable, or holds no
    /// credentials, so a ping can never run without a bound identity.
    nonisolated static func loadCodexWindowKeepAliveAuthority(
        environment: [String: String]) -> CodexWindowKeepAliveAuthority?
    {
        guard let fingerprint = CodexAuthFingerprint.fingerprint(env: environment),
              let credentials = try? CodexOAuthCredentialsStore.load(env: environment)
        else { return nil }
        return CodexWindowKeepAliveAuthority(
            environment: environment,
            authFingerprint: fingerprint,
            accountID: credentials.accountId,
            isAPIKeyLogin: credentials.isAPIKey)
    }

    /// Pure decision so the trigger is testable without launching anything. Returns `nil` when the ping should run.
    nonisolated static func codexWindowKeepAliveSkipReason(
        _ context: CodexWindowKeepAliveContext) -> CodexWindowKeepAliveSkipReason?
    {
        guard context.enabled else { return .disabled }
        let window = context.window
        guard window.instanceID == .codex,
              let windowMinutes = window.windowMinutes,
              windowMinutes <= self.codexWindowKeepAliveMaximumWindowMinutes
        else { return .notCodexSessionWindow }
        guard context.codexEnabled else { return .codexDisabled }
        guard !context.refreshCadenceIsManual else { return .manualRefreshCadence }
        guard !context.lowPowerModeEnabled else { return .lowPowerMode }
        if let workspaceID = context.selectedManagedWorkspaceID, !workspaceID.isEmpty {
            return .managedWorkspaceUnsupported
        }
        guard let authority = context.authority else { return .loginUnavailable }
        guard !authority.isAPIKeyLogin else { return .apiKeyLoginUnsupported }
        guard !context.attemptedBoundaries.contains(window.resetsAt) else { return .alreadyAttempted }
        guard let refreshedSnapshot = context.refreshedSnapshot else { return .snapshotMissing }
        guard let publishedAt = context.snapshotPublishedAt,
              publishedAt >= context.refreshStartedAt
        else { return .snapshotStale }
        if let refreshedResetsAt = refreshedSnapshot.primary?.resetsAt,
           refreshedResetsAt.timeIntervalSince(window.resetsAt) > self.codexWindowKeepAliveResetToleranceSeconds
        {
            return .newWindowAlreadyStarted
        }
        return nil
    }

    /// Re-checked on the main actor right before the CLI launches. Turning the toggle off, switching the selected
    /// Codex account (different environment), or replacing the login inside the same `CODEX_HOME` (different
    /// `auth.json` fingerprint or account) after the boundary fired all prevent the request.
    nonisolated static func codexWindowKeepAliveRemainsAdmitted(
        enabled: Bool,
        capturedAuthority: CodexWindowKeepAliveAuthority,
        currentAuthority: CodexWindowKeepAliveAuthority?) -> Bool
    {
        guard enabled, let currentAuthority, !currentAuthority.isAPIKeyLogin else { return false }
        return currentAuthority == capturedAuthority
    }

    func scheduleCodexWindowKeepAliveIfNeeded(after window: ResetBoundaryWindow, refreshStartedAt: Date) {
        let logger = CodexBarLog.logger(LogCategories.provider(.codex, scope: "window-keepalive"))
        let enabled = self.settings.codexWindowKeepAliveEnabled
        // Only touch auth.json when the user opted in; the decision returns `.disabled` first anyway.
        let authority = enabled ? self.currentCodexWindowKeepAliveAuthority() : nil
        if let reason = Self.codexWindowKeepAliveSkipReason(CodexWindowKeepAliveContext(
            enabled: enabled,
            window: window,
            codexEnabled: self.isEnabled(.codex),
            refreshCadenceIsManual: self.settings.refreshFrequency == .manual,
            lowPowerModeEnabled: self.settings.backgroundWorkLowPowerModeEnabled,
            selectedManagedWorkspaceID: self.selectedCodexManagedWorkspaceID(),
            authority: authority,
            attemptedBoundaries: self.attemptedCodexWindowKeepAliveBoundaries,
            refreshedSnapshot: self.snapshots[.codex],
            refreshStartedAt: refreshStartedAt,
            snapshotPublishedAt: self.lastSnapshotPublicationAt[.codex]))
        {
            if reason != .disabled, reason != .notCodexSessionWindow {
                logger.info("Codex window keep-alive skipped", metadata: ["reason": "\(reason)"])
            }
            return
        }
        guard let authority else { return }

        self.recordAttemptedCodexWindowKeepAlive(window.resetsAt)
        let runner = self.codexWindowKeepAliveRunner
        self.codexWindowKeepAliveTask?.cancel()
        self.codexWindowKeepAliveTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if let denial = await self.codexWindowKeepAliveLaunchDenial(capturedAuthority: authority) {
                logger.info("Codex window keep-alive cancelled before launch", metadata: ["reason": denial])
                return
            }
            guard !Task.isCancelled else { return }
            logger.info("Codex window keep-alive ping starting", metadata: ["resetsAt": "\(window.resetsAt)"])
            do {
                try await runner(authority.environment)
                logger.info("Codex window keep-alive ping finished")
            } catch {
                logger.warning(
                    "Codex window keep-alive ping failed",
                    metadata: ["error": error.localizedDescription])
                return
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(Self.codexWindowKeepAliveFollowUpRefreshDelaySeconds))
            guard !Task.isCancelled else { return }
            await self.refreshProvider(.codex, coalesceIfRefreshing: true)
        }
    }

    /// Drops any pending ping. Called when the toggle is turned off so no queued request survives the consent change.
    func cancelCodexWindowKeepAlive() {
        self.codexWindowKeepAliveTask?.cancel()
        self.codexWindowKeepAliveTask = nil
    }

    /// The login `codex exec` would spend right now for the selected account, via the injectable loader.
    func currentCodexWindowKeepAliveAuthority() -> CodexWindowKeepAliveAuthority? {
        self.codexWindowKeepAliveAuthorityLoader(self.codexFetchEnvironment())
    }

    /// Nil when the queued ping may launch; otherwise a short log reason for dropping it.
    private func codexWindowKeepAliveLaunchDenial(capturedAuthority: CodexWindowKeepAliveAuthority) -> String? {
        guard self.settings.codexWindowKeepAliveEnabled else { return "consent" }
        let current = self.currentCodexWindowKeepAliveAuthority()
        guard Self.codexWindowKeepAliveRemainsAdmitted(
            enabled: true,
            capturedAuthority: capturedAuthority,
            currentAuthority: current)
        else {
            return current == nil ? "login-unavailable" : "login-changed"
        }
        return nil
    }

    /// Mirrors the admission `CodexOAuthNativeRefreshCLIStrategy` applies: the CLI cannot carry a selected managed
    /// workspace, so any non-nil ID here must keep the ping off.
    private func selectedCodexManagedWorkspaceID() -> String? {
        self.settings.codexSettingsSnapshot(tokenOverride: nil).managedWorkspaceAccountID
    }

    private func recordAttemptedCodexWindowKeepAlive(_ resetsAt: Date) {
        self.attemptedCodexWindowKeepAliveBoundaries.insert(resetsAt)
        if self.attemptedCodexWindowKeepAliveBoundaries.count > 64,
           let oldest = self.attemptedCodexWindowKeepAliveBoundaries.min()
        {
            self.attemptedCodexWindowKeepAliveBoundaries.remove(oldest)
        }
    }
}
