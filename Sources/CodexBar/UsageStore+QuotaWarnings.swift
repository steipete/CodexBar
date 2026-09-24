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
    }

    struct QuotaWarningState {
        var lastRemaining: Double?
        var observedAt: Date = .distantPast
        var firedThresholds: Set<Int> = []
        var source: SessionQuotaWindowSource?
        var resetsAt: Date?
        var sharedWithUnresolvedAccount = false
    }
}

@MainActor
extension UsageStore {
    private struct QuotaWarningAccountContext {
        let discriminator: String?
        let displayName: String?
        let observedAt: Date
    }

    func handleQuotaWarningTransitions(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        accountDiscriminator: String? = nil,
        hookAccountDiscriminator: String? = nil,
        requiresKnownAccount: Bool = false)
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
        guard !requiresKnownAccount || accountDiscriminator != nil else { return }

        let accountContext = QuotaWarningAccountContext(
            discriminator: accountDiscriminator,
            displayName: self.warningAccountDisplayName(provider: provider, snapshot: snapshot),
            observedAt: snapshot.updatedAt)
        // Provider-specific by design: warning lanes follow Antigravity families, balance-only suppression, and
        // provider-authored dynamic labels rather than the generic primary/secondary pair.
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
            let suppressWindows = provider == .mimo || provider == .qoder
            primaryWindow = suppressWindows ? nil : snapshot.primary
            secondaryWindow = suppressWindows ? nil : snapshot.secondary
        }
        let primaryWindowDisplayLabel = provider == .amp
            ? AmpProviderDescriptor.primaryLabel(snapshot: snapshot)
            : nil
        let secondaryWindowDisplayLabel = provider == .amp
            ? AmpProviderDescriptor.secondaryLabel(snapshot: snapshot)
            : nil
        let extraWindows = provider == .claude
            ? (snapshot.extraRateWindows ?? []).filter(Self.isClaudeNotifiableExtraWindow)
            : []
        let windows: [(QuotaWarningWindow, RateWindow?, String?, String?)] = [
            (.session, primaryWindow, nil, primaryWindowDisplayLabel),
            (.weekly, secondaryWindow, nil, secondaryWindowDisplayLabel),
        ] + extraWindows.map { (.weekly, $0.window, $0.id, $0.title) }
        if notificationsEnabled {
            for (window, rateWindow, windowID, label) in windows {
                self.handleQuotaWarningTransition(
                    provider: provider,
                    window: window,
                    rateWindow: rateWindow,
                    source: source,
                    accountContext: accountContext,
                    windowID: windowID,
                    windowDisplayLabel: label)
            }
            // A missing extras payload is not authoritative; prune only when another extra window remains.
            if !extraWindows.isEmpty, self.settings.quotaWarningEnabled(provider: provider, window: .weekly) {
                let activeIDs = Set(extraWindows.map(\.id))
                self.quotaWarningState = self.quotaWarningState.filter { key, _ in
                    key.provider != provider || key.window != .weekly ||
                        key.accountDiscriminator != accountContext.discriminator ||
                        (key.windowID.map { activeIDs.contains($0) } ?? true)
                }
            }
        }

        if hooksActive {
            let hookDiscriminator = hookAccountDiscriminator ?? accountDiscriminator
            for (window, rateWindow, windowID, label) in windows {
                self.dispatchQuotaLowHooks(
                    provider: provider,
                    lane: QuotaLowHookLane(window: window, windowID: windowID, label: label ?? window.displayName),
                    rateWindow: rateWindow,
                    accountDiscriminator: hookDiscriminator,
                    accountDisplayName: accountContext.displayName)
            }
            self.pruneQuotaLowHookUsage(
                provider: provider,
                accountDiscriminator: hookDiscriminator,
                keepingExtraWindowIDs: Set(extraWindows.map(\.id)))
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
        var key = QuotaWarningStateKey(
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
        // Claude promotes weekly usage to primary when its session payload is missing.
        guard provider != .claude || window != .session || Self.isSessionWindow(rateWindow) else { return }
        guard !rateWindow.isSyntheticPlaceholder else { return }

        let thresholds = self.settings.resolvedQuotaWarningThresholds(provider: provider, window: window)
        let currentRemaining = rateWindow.remainingPercent
        if provider == .claude, key.accountDiscriminator == "claude-account:unknown",
           self.quotaWarningState[key] == nil, let account = self.lastClaudeQuotaWarningAccount
        {
            let accountKey = QuotaWarningStateKey(
                provider: provider, window: window, accountDiscriminator: account, windowID: windowID)
            if let prior = self.quotaWarningState[accountKey], prior.observedAt <= accountContext.observedAt {
                if let resetsAt = rateWindow.resetsAt, resetsAt == prior.resetsAt,
                   let remaining = prior.lastRemaining, currentRemaining <= remaining
                {
                    key = accountKey
                } else if prior.sharedWithUnresolvedAccount {
                    // Discontinuity can change the key, but cannot discard already reconciled thresholds.
                    self.quotaWarningState[key] = prior
                }
            }
        }
        let previousState = self.quotaWarningState[key]
        if let previousState, previousState.source != source {
            self.quotaWarningState[key] = QuotaWarningState(
                lastRemaining: currentRemaining,
                observedAt: accountContext.observedAt,
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

        state.observedAt = accountContext.observedAt
        state.resetsAt = rateWindow.resetsAt
        state.lastRemaining = currentRemaining
        self.quotaWarningState[key] = state
    }

    private func clearQuotaWarningState(provider: UsageProvider, window: QuotaWarningWindow) {
        self.quotaWarningState = self.quotaWarningState.filter {
            $0.key.provider != provider || $0.key.window != window
        }
    }

    func warningAccountDisplayName(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard !self.settings.hidePersonalInfo else { return nil }
        let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !account.isEmpty else { return nil }
        return account
    }
}
