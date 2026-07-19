import CodexBarCore
import Foundation

extension UsageStore {
    struct QuotaWarningStateKey: Hashable {
        let provider: UsageProvider
        let window: QuotaWarningWindow
        /// Keeps independent accounts from sharing threshold-crossing state. `nil` preserves the
        /// legacy single-account lane when no stable account owner is available.
        let accountDiscriminator: String?
        /// Distinguishes independent extra rate windows that share a provider/window lane
        /// (e.g. multiple `claude-weekly-scoped-*` windows) so their fired-threshold state
        /// does not clobber each other or the primary session/weekly lanes. `nil` for the
        /// primary session and weekly lanes.
        let windowID: String?

        init(
            provider: UsageProvider,
            window: QuotaWarningWindow,
            accountDiscriminator: String?,
            windowID: String? = nil)
        {
            self.provider = provider
            self.window = window
            self.accountDiscriminator = accountDiscriminator
            self.windowID = windowID
        }
    }

    struct QuotaWarningState {
        var lastRemaining: Double?
        var firedThresholds: Set<Int> = []
        var source: SessionQuotaWindowSource?
    }
}

@MainActor
extension UsageStore {
    private struct QuotaWarningAccountContext {
        let discriminator: String?
        let displayName: String?
    }

    func handleQuotaWarningTransitions(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        accountDiscriminator: String? = nil)
    {
        let notificationsEnabled = self.settings.quotaWarningNotificationsEnabled
        // Hooks have their own enable switch and per-rule thresholds, so quota_low
        // hooks run on a separate path that does not depend on the notification
        // preference or the notification thresholds.
        self.resetQuotaLowHookUsageIfConfigurationChanged()
        let hooksActive = self.hasQuotaHookRule(event: .quotaLow, provider: provider)
        if !hooksActive {
            self.clearQuotaLowHookUsage(provider: provider)
        }
        guard notificationsEnabled || hooksActive else { return }
        if provider == .commandcode, snapshot.commandCodeSubscriptionEnrichmentUnavailable { return }

        let accountContext = QuotaWarningAccountContext(
            discriminator: accountDiscriminator,
            displayName: self.quotaWarningAccountDisplayName(provider: provider, snapshot: snapshot))
        let source: SessionQuotaWindowSource? = if provider == .antigravity {
            Self.hasAntigravityQuotaSummaryWindows(snapshot: snapshot)
                ? .antigravityQuotaSummary
                : .antigravityLegacy
        } else {
            nil
        }
        let primaryWindow: RateWindow?
        let secondaryWindow: RateWindow?
        if provider == .antigravity {
            primaryWindow = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 5 * 60)
            secondaryWindow = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 7 * 24 * 60)
        } else {
            primaryWindow = provider == .mimo || provider == .qoder ? nil : snapshot.primary
            secondaryWindow = provider == .mimo || provider == .qoder ? nil : snapshot.secondary
        }
        if notificationsEnabled {
            self.handleQuotaWarningTransition(
                provider: provider,
                window: .session,
                rateWindow: primaryWindow,
                source: source,
                accountContext: accountContext)
            self.handleQuotaWarningTransition(
                provider: provider,
                window: .weekly,
                rateWindow: secondaryWindow,
                source: source,
                accountContext: accountContext)
            self.handleClaudeExtraWindowQuotaWarnings(
                provider: provider,
                snapshot: snapshot,
                accountContext: accountContext)
        }

        if hooksActive {
            self.dispatchQuotaLowHooks(
                provider: provider,
                lane: QuotaLowHookLane(
                    window: .session,
                    windowID: nil,
                    label: QuotaWarningWindow.session.displayName),
                rateWindow: primaryWindow,
                accountDiscriminator: accountContext.discriminator,
                accountDisplayName: accountContext.displayName)
            self.dispatchQuotaLowHooks(
                provider: provider,
                lane: QuotaLowHookLane(
                    window: .weekly,
                    windowID: nil,
                    label: QuotaWarningWindow.weekly.displayName),
                rateWindow: secondaryWindow,
                accountDiscriminator: accountContext.discriminator,
                accountDisplayName: accountContext.displayName)
            let extraWindows = provider == .claude
                ? (snapshot.extraRateWindows ?? []).filter(Self.isClaudeNotifiableExtraWindow)
                : []
            for named in extraWindows {
                self.dispatchQuotaLowHooks(
                    provider: provider,
                    lane: QuotaLowHookLane(window: .weekly, windowID: named.id, label: named.title),
                    rateWindow: named.window,
                    accountDiscriminator: accountContext.discriminator,
                    accountDisplayName: accountContext.displayName)
            }
            self.pruneQuotaLowHookUsage(
                provider: provider,
                accountDiscriminator: accountContext.discriminator,
                keepingExtraWindowIDs: Set(extraWindows.map(\.id)))
        }
    }

    /// Emit weekly-lane quota warnings for Claude's extra rate windows — model-scoped weekly
    /// carve-outs (`claude-weekly-scoped-*`, e.g. Fable) and Daily Routines — which surface in the
    /// menu but were otherwise silent. Antigravity's summary windows are already covered by the
    /// primary and weekly lanes above, so they are excluded here.
    private func handleClaudeExtraWindowQuotaWarnings(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        accountContext: QuotaWarningAccountContext)
    {
        guard provider == .claude else { return }
        guard self.settings.quotaWarningEnabled(provider: provider, window: .weekly) else {
            self.clearQuotaWarningState(provider: provider, window: .weekly)
            return
        }

        let windows = (snapshot.extraRateWindows ?? []).filter(Self.isClaudeNotifiableExtraWindow)
        for named in windows {
            self.handleQuotaWarningTransition(
                provider: provider,
                window: .weekly,
                rateWindow: named.window,
                source: nil,
                accountContext: accountContext,
                windowID: named.id,
                windowDisplayLabel: named.title)
        }
        // A missing extras payload is not authoritative, but when another notifiable window remains,
        // reconcile tracked IDs so a later incarnation of a disappeared window can warn again.
        guard !windows.isEmpty else { return }
        let activeIDs = Set(windows.map(\.id))
        let staleKeys = self.quotaWarningState.keys.filter { key in
            guard key.provider == provider,
                  key.window == .weekly,
                  key.accountDiscriminator == accountContext.discriminator,
                  let windowID = key.windowID
            else { return false }
            return !activeIDs.contains(windowID)
        }
        for key in staleKeys {
            self.quotaWarningState.removeValue(forKey: key)
        }
    }

    private static func isClaudeNotifiableExtraWindow(_ named: NamedRateWindow) -> Bool {
        guard named.usageKnown else { return false }
        return named.id.hasPrefix("claude-weekly-scoped-") || named.id == "claude-routines"
    }

    private func handleQuotaWarningTransition(
        provider: UsageProvider,
        window: QuotaWarningWindow,
        rateWindow: RateWindow?,
        source: SessionQuotaWindowSource?,
        accountContext: QuotaWarningAccountContext,
        windowID: String? = nil,
        windowDisplayLabel: String? = nil)
    {
        let key = QuotaWarningStateKey(
            provider: provider,
            window: window,
            accountDiscriminator: accountContext.discriminator,
            windowID: windowID)
        guard self.settings.quotaWarningEnabled(provider: provider, window: window) else {
            self.clearQuotaWarningState(provider: provider, window: window)
            return
        }
        guard let rateWindow else {
            self.quotaWarningState.removeValue(forKey: key)
            return
        }
        guard !rateWindow.isSyntheticPlaceholder else { return }

        let thresholds = self.settings.resolvedQuotaWarningThresholds(provider: provider, window: window)
        let currentRemaining = rateWindow.remainingPercent
        let previousState = self.quotaWarningState[key]
        if let previousState, previousState.source != source {
            self.quotaWarningState[key] = QuotaWarningState(
                lastRemaining: currentRemaining,
                source: source)
            return
        }
        var state = previousState ?? QuotaWarningState(source: source)
        let cleared = QuotaWarningNotificationLogic.thresholdsToClear(
            currentRemaining: currentRemaining,
            alreadyFired: state.firedThresholds)
        state.firedThresholds.subtract(cleared)

        if let threshold = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: state.lastRemaining,
            currentRemaining: currentRemaining,
            thresholds: thresholds,
            alreadyFired: state.firedThresholds)
        {
            state.firedThresholds.formUnion(QuotaWarningNotificationLogic.firedThresholdsAfterWarning(
                threshold: threshold,
                thresholds: thresholds))
            self.postQuotaWarning(
                QuotaWarningEvent(
                    window: window,
                    threshold: threshold,
                    currentRemaining: currentRemaining,
                    accountDisplayName: accountContext.displayName,
                    windowID: windowID,
                    windowDisplayLabel: windowDisplayLabel),
                provider: provider)
        }

        state.lastRemaining = currentRemaining
        self.quotaWarningState[key] = state
    }

    private func clearQuotaWarningState(provider: UsageProvider, window: QuotaWarningWindow) {
        let keys = self.quotaWarningState.keys.filter {
            $0.provider == provider && $0.window == window
        }
        for key in keys {
            self.quotaWarningState.removeValue(forKey: key)
        }
    }

    private func quotaWarningAccountDisplayName(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard !self.settings.hidePersonalInfo else { return nil }
        let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !account.isEmpty else { return nil }
        return account
    }
}
