import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func handleQuotaWarningTransitions(provider: UsageProvider, snapshot: UsageSnapshot) {
        guard self.settings.quotaWarningNotificationsEnabled else { return }
        if provider == .commandcode, snapshot.commandCodeSubscriptionEnrichmentUnavailable { return }

        let accountDisplayName = self.quotaWarningAccountDisplayName(provider: provider, snapshot: snapshot)
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
        self.handleQuotaWarningTransition(
            provider: provider,
            window: .session,
            rateWindow: primaryWindow,
            source: source,
            accountDisplayName: accountDisplayName)
        self.handleQuotaWarningTransition(
            provider: provider,
            window: .weekly,
            rateWindow: secondaryWindow,
            source: source,
            accountDisplayName: accountDisplayName)
        self.handleClaudeExtraWindowQuotaWarnings(
            provider: provider,
            snapshot: snapshot,
            accountDisplayName: accountDisplayName)
    }

    /// Emit weekly-lane quota warnings for Claude's extra rate windows — model-scoped weekly
    /// carve-outs (`claude-weekly-scoped-*`, e.g. Fable) and Daily Routines — which surface in the
    /// menu but were otherwise silent. Antigravity's summary windows are already covered by the
    /// primary and weekly lanes above, so they are excluded here.
    private func handleClaudeExtraWindowQuotaWarnings(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        accountDisplayName: String?)
    {
        guard provider == .claude else { return }
        guard self.settings.quotaWarningEnabled(provider: provider, window: .weekly) else {
            let extraWindowKeys = self.quotaWarningState.keys.filter {
                $0.provider == provider && $0.windowID != nil
            }
            for key in extraWindowKeys {
                self.quotaWarningState.removeValue(forKey: key)
            }
            return
        }

        let windows = (snapshot.extraRateWindows ?? []).filter(Self.isClaudeNotifiableExtraWindow)
        for named in windows {
            self.handleQuotaWarningTransition(
                provider: provider,
                window: .weekly,
                rateWindow: named.window,
                source: nil,
                accountDisplayName: accountDisplayName,
                windowID: named.id,
                windowDisplayLabel: named.title)
        }
        // A missing extras payload is not authoritative, but when another notifiable window remains,
        // reconcile tracked IDs so a later incarnation of a disappeared window can warn again.
        guard !windows.isEmpty else { return }
        let activeIDs = Set(windows.map(\.id))
        let staleKeys = self.quotaWarningState.keys.filter { key in
            guard key.provider == provider, let windowID = key.windowID else { return false }
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
        accountDisplayName: String?,
        windowID: String? = nil,
        windowDisplayLabel: String? = nil)
    {
        let key = QuotaWarningStateKey(provider: provider, window: window, windowID: windowID)
        guard self.settings.quotaWarningEnabled(provider: provider, window: window) else {
            self.quotaWarningState.removeValue(forKey: key)
            return
        }
        guard let rateWindow else {
            self.quotaWarningState.removeValue(forKey: key)
            return
        }

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
                    accountDisplayName: accountDisplayName,
                    windowID: windowID,
                    windowDisplayLabel: windowDisplayLabel),
                provider: provider)
        }

        state.lastRemaining = currentRemaining
        self.quotaWarningState[key] = state
    }

    private func quotaWarningAccountDisplayName(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard !self.settings.hidePersonalInfo else { return nil }
        let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !account.isEmpty else { return nil }
        return account
    }
}
