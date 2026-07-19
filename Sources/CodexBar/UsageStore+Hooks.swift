import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Builds a `HookEvent` and dispatches it to any matching external hooks.
    ///
    /// Fire-and-forget: the actual process runs on a detached task so nothing
    /// blocks the menu-bar refresh. No-op unless the user enabled hooks.
    /// `usagePercent` is a 0...1 fraction.
    func emitHook(
        _ type: HookEventType,
        provider: UsageProvider,
        window: String? = nil,
        usagePercent: Double? = nil,
        resetAt: Date? = nil,
        status: String? = nil,
        accountDisplayName: String? = nil)
    {
        guard let hooks = self.settings.config.hooks,
              hooks.enabled,
              hooks.events.count <= HooksConfig.maximumRuleCount
        else { return }

        let event = HookEvent(
            event: type,
            provider: provider.rawValue,
            account: self.settings.hidePersonalInfo ? nil : accountDisplayName,
            window: window,
            usagePercent: usagePercent,
            resetAt: resetAt,
            status: status,
            timestamp: Date())

        let limiter = self.hookRateLimiter
        let environment = self.environmentBase
        Task.detached(priority: .utility) {
            await HookRunner.dispatch(
                event: event,
                config: hooks,
                rateLimiter: limiter,
                baseEnvironment: environment)
        }
    }

    func emitQuotaReachedHook(
        provider: UsageProvider,
        sessionWindow: (window: RateWindow, source: SessionQuotaWindowSource),
        snapshot: UsageSnapshot)
    {
        self.emitHook(
            .quotaReached,
            provider: provider,
            window: QuotaWarningWindow.session.displayName,
            usagePercent: sessionWindow.window.usedPercent / 100,
            resetAt: sessionWindow.window.resetsAt,
            accountDisplayName: self.hookAccountDisplayName(provider: provider, snapshot: snapshot))
    }

    /// Emits `quota_reset` when a session/weekly limit reset is detected. The
    /// account label is redacted when the user hides personal info.
    func emitQuotaResetHook(
        provider: UsageProvider,
        window: QuotaWarningWindow,
        usedPercent: Double,
        accountLabel: String?)
    {
        self.emitHook(
            .quotaReset,
            provider: provider,
            window: window.displayName,
            usagePercent: usedPercent / 100,
            accountDisplayName: self.settings.hidePersonalInfo ? nil : accountLabel)
    }

    /// Emits `provider_unavailable` / `provider_recovered` on genuine outage
    /// transitions. `.unknown` (transient/first fetch) and `.maintenance` never
    /// flip the tracked state, so a hiccuped status probe cannot fire a hook.
    func emitProviderStatusHooks(provider: UsageProvider, indicator: ProviderStatusIndicator) {
        let isOutage: Bool
        switch indicator {
        case .minor, .major, .critical:
            isOutage = true
        case .none:
            isOutage = false
        case .maintenance, .unknown:
            return
        }

        let wasOutage = self.providerStatusHadIssue[provider] ?? false
        if isOutage, !wasOutage {
            self.providerStatusHadIssue[provider] = true
            self.emitHook(.providerUnavailable, provider: provider, status: indicator.rawValue)
        } else if !isOutage, wasOutage {
            self.providerStatusHadIssue[provider] = false
            self.emitHook(.providerRecovered, provider: provider, status: indicator.rawValue)
        }
    }

    /// Identifies a quota lane for quota_low hook crossing detection.
    struct QuotaLowHookLane {
        let window: QuotaWarningWindow
        let windowID: String?
        let label: String
    }

    /// Fires `quota_low` hooks driven by each rule's own usage threshold, crossed
    /// upward, independent of the notification thresholds and preferences. A rule
    /// with no threshold falls back to the provider's notification thresholds so a
    /// "notify me when quota is low" hook still fires at the app's warning points.
    ///
    /// Crossing history is keyed by the same account-scoped `QuotaWarningStateKey`
    /// as the notification path (including `accountDiscriminator`), so accounts that
    /// share a provider track their crossings independently.
    func dispatchQuotaLowHooks(
        provider: UsageProvider,
        lane: QuotaLowHookLane,
        rateWindow: RateWindow?,
        accountDiscriminator: String?,
        accountDisplayName: String?)
    {
        guard let hooks = self.settings.config.hooks,
              hooks.enabled,
              hooks.events.count <= HooksConfig.maximumRuleCount
        else { return }
        let rules = hooks.events.filter { rule in
            rule.enabled
                && rule.event == .quotaLow
                && (rule.provider == nil || rule.provider == provider.rawValue)
        }
        guard !rules.isEmpty else { return }

        let key = QuotaWarningStateKey(
            provider: provider,
            window: lane.window,
            accountDiscriminator: accountDiscriminator,
            windowID: lane.windowID)
        guard let rateWindow else {
            self.quotaLowHookUsage.removeValue(forKey: key)
            return
        }
        let current = rateWindow.usedPercent / 100
        let previous = self.quotaLowHookUsage[key]
        self.quotaLowHookUsage[key] = current
        // No crossing can be established from the first sample; avoid firing on a
        // fresh launch when usage is already high.
        guard let previous else { return }

        let fallbackThresholds = self.settings
            .resolvedQuotaWarningThresholds(provider: provider, window: lane.window)
            .map { (100.0 - Double($0)) / 100.0 }
        let crossed = QuotaLowHookThreshold.crossedRules(
            rules,
            previousUsage: previous,
            currentUsage: current,
            fallbackThresholds: fallbackThresholds)
        guard !crossed.isEmpty else { return }

        let event = HookEvent(
            event: .quotaLow,
            provider: provider.rawValue,
            account: self.settings.hidePersonalInfo ? nil : accountDisplayName,
            window: lane.label,
            usagePercent: current,
            resetAt: rateWindow.resetsAt,
            timestamp: Date())
        let config = HooksConfig(enabled: true, events: crossed)
        let limiter = self.hookRateLimiter
        let environment = self.environmentBase
        Task.detached(priority: .utility) {
            await HookRunner.dispatch(
                event: event,
                config: config,
                rateLimiter: limiter,
                baseEnvironment: environment)
        }
    }

    /// Drops baselines while no quota-low rule is active. A later re-enable must
    /// establish a fresh sample instead of firing for a crossing that happened
    /// while command execution was disabled.
    func clearQuotaLowHookUsage(provider: UsageProvider) {
        self.quotaLowHookUsage = self.quotaLowHookUsage.filter { $0.key.provider != provider }
    }

    /// Any persisted config edit can include a hook disable/re-enable or rule
    /// replacement. Reset crossing baselines on the next sample so transitions
    /// that occurred while the prior configuration was inactive never execute.
    func resetQuotaLowHookUsageIfConfigurationChanged() {
        let revision = self.settings.configRevision
        guard self.quotaLowHookConfigRevision != revision else { return }
        self.quotaLowHookUsage.removeAll()
        self.quotaLowHookConfigRevision = revision
    }

    /// Extra quota lanes can disappear between snapshots. Forget their baselines
    /// so a later reappearance starts fresh rather than reporting a stale crossing.
    func pruneQuotaLowHookUsage(
        provider: UsageProvider,
        accountDiscriminator: String?,
        keepingExtraWindowIDs: Set<String>)
    {
        self.quotaLowHookUsage = self.quotaLowHookUsage.filter { key, _ in
            guard key.provider == provider,
                  key.accountDiscriminator == accountDiscriminator,
                  let windowID = key.windowID
            else { return true }
            return keepingExtraWindowIDs.contains(windowID)
        }
    }

    /// True when the user has an enabled hook rule for this event and provider.
    ///
    /// Used to run quota transition detection even when the matching notification
    /// preference is off, so hooks fire independently of notifications. Returns
    /// false for everyone who has not configured such a rule, so notification
    /// behavior is unchanged for them.
    func hasQuotaHookRule(event: HookEventType, provider: UsageProvider) -> Bool {
        guard let hooks = self.settings.config.hooks, hooks.enabled else { return false }
        return hooks.events.contains { rule in
            rule.enabled
                && rule.event == event
                && (rule.provider == nil || rule.provider == provider.rawValue)
        }
    }

    /// Coarse, non-secret category for a refresh failure. Never forwards the raw
    /// error description, which can include provider response-body previews.
    nonisolated static func refreshFailureHookStatus(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if isPermissionPromptWaiting(error) { return "auth_required" }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return "cancelled"
            case NSURLErrorTimedOut:
                return "timeout"
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                return "offline"
            default:
                return "network_error"
            }
        }
        return "error"
    }

    /// Account label for a hook payload, redacted when the user hides personal info.
    func hookAccountDisplayName(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard !self.settings.hidePersonalInfo else { return nil }
        let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !account.isEmpty else { return nil }
        return account
    }
}
