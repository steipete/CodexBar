import CodexBarCore
import Foundation

extension UsageStore {
    struct QuotaWarningStateKey: Hashable, Codable {
        let provider: ProviderInstanceID
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

    struct QuotaWarningState: Codable {
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
    static let quotaWarningStateDefaultsKey = "quotaWarningStateV1"

    func persistQuotaWarningState() {
        let scoped = self.quotaWarningState.filter { Self.canPersistQuotaWarning(key: $0.key) }
        guard let data = try? JSONEncoder().encode(scoped) else { return }
        self.settings.userDefaults.set(data, forKey: Self.quotaWarningStateDefaultsKey)
    }

    private static func canPersistQuotaWarning(key: QuotaWarningStateKey) -> Bool {
        guard let account = key.accountDiscriminator, !account.isEmpty else { return false }
        return account != "claude-account:unknown"
    }

    static func loadQuotaWarningState(from defaults: UserDefaults) -> [QuotaWarningStateKey: QuotaWarningState] {
        guard let data = defaults.data(forKey: quotaWarningStateDefaultsKey),
              let states = try? JSONDecoder().decode([QuotaWarningStateKey: QuotaWarningState].self, from: data)
        else { return [:] }
        return states.filter { self.canPersistQuotaWarning(key: $0.key) }
    }

    private struct QuotaWarningAccountContext {
        let discriminator: String?
        let displayName: String?
        let observedAt: Date
        var changedAntigravitySource = false
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
        let hooksActive = self.hasQuotaHookRule(event: .quotaLow, provider: provider.instanceID)
        if !hooksActive {
            self.clearQuotaLowHookUsage(provider: provider.instanceID)
        }
        guard notificationsEnabled || hooksActive else { return }
        guard !requiresKnownAccount || accountDiscriminator != nil else { return }

        let familyAccount = provider == .antigravity
            ? snapshot.accountEmail(for: provider)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : nil
        var accountContext = QuotaWarningAccountContext(
            discriminator: accountDiscriminator ?? familyAccount,
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
        let priorSource = self.quotaWarningState
            .filter {
                $0.key.provider == provider.instanceID && $0.key.accountDiscriminator == accountContext.discriminator
            }
            .values.max { $0.observedAt < $1.observedAt }
        accountContext.changedAntigravitySource = provider == .antigravity
            && priorSource.map { $0.source != source } == true
        let primaryWindow: RateWindow?
        let secondaryWindow: RateWindow?
        if provider == .antigravity {
            primaryWindow = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 5 * 60)
            secondaryWindow = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 7 * 24 * 60)
        } else if provider == .cursor, let weekly = CursorProviderDescriptor.sharedWeeklyPool(snapshot: snapshot) {
            primaryWindow = nil
            secondaryWindow = weekly
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
        let familyWindows = provider == .antigravity
            ? (snapshot.extraRateWindows ?? []).filter {
                $0.id.hasPrefix("antigravity-quota-summary-") && $0.usageKnown
            }
            : []
        let usesFamilyWindows = provider == .antigravity && Self.hasAntigravityQuotaSummaryWindows(snapshot: snapshot)
        // Every model family owns its own threshold history; do not also warn on the aggregate minimum.
        let windows: [(QuotaWarningWindow, RateWindow?, String?, String?)] = usesFamilyWindows
            ? familyWindows.compactMap { named in
                let lane: QuotaWarningWindow
                switch named.window.windowMinutes {
                case 300: lane = .session
                case 10080: lane = .weekly
                default: return nil
                }
                return (lane, named.window, named.id, named.title)
            }
            : [
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
                    key.provider != provider.instanceID || key.window != .weekly ||
                        key.accountDiscriminator != accountContext.discriminator ||
                        (key.windowID.map { activeIDs.contains($0) } ?? true)
                }
            }
        }

        if hooksActive {
            let hookDiscriminator = hookAccountDiscriminator ?? accountContext.discriminator
            for (window, rateWindow, windowID, label) in windows {
                self.dispatchQuotaLowHooks(
                    provider: provider.instanceID,
                    lane: QuotaLowHookLane(window: window, windowID: windowID, label: label ?? window.displayName),
                    rateWindow: rateWindow,
                    accountDiscriminator: hookDiscriminator,
                    accountDisplayName: accountContext.displayName)
            }
            self.pruneQuotaLowHookUsage(
                provider: provider.instanceID,
                accountDiscriminator: hookDiscriminator,
                keepingExtraWindowIDs: Set(windows.compactMap(\.2)))
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
            provider: provider.instanceID,
            window: window,
            accountDiscriminator: accountContext.discriminator,
            windowID: windowID)
        guard self.settings.quotaWarningEnabled(provider: provider, window: window) else {
            self.clearQuotaWarningState(provider: provider, window: window)
            return
        }
        // Missing readings are not a quota recovery and must not erase persisted warning history.
        // Older Claude caches can put a weekly window in the primary slot.
        let isClaudeSessionLane = provider == .claude && window == .session
        guard let rateWindow else { return }
        guard !isClaudeSessionLane || Self.isSessionWindow(rateWindow) else { return }
        guard !rateWindow.isSyntheticPlaceholder else { return }

        let thresholds = self.settings.resolvedQuotaWarningThresholds(provider: provider.instanceID, window: window)
        let currentRemaining = rateWindow.remainingPercent
        if provider == .claude, key.accountDiscriminator == "claude-account:unknown",
           self.quotaWarningState[key] == nil, let account = self.lastClaudeQuotaWarningAccount
        {
            let accountKey = QuotaWarningStateKey(
                provider: provider.instanceID, window: window, accountDiscriminator: account, windowID: windowID)
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
        guard previousState.map({ accountContext.observedAt >= $0.observedAt }) ?? true else { return }
        if (previousState.map { $0.source != source } ?? false) || accountContext.changedAntigravitySource {
            self.quotaWarningState[key] = QuotaWarningState(
                lastRemaining: currentRemaining,
                observedAt: accountContext.observedAt,
                source: source,
                resetsAt: rateWindow.resetsAt.flatMap { $0 > accountContext.observedAt ? $0 : nil })
            return
        }
        var state = previousState ?? QuotaWarningState(source: source)
        // A genuinely new allowance period can warn again even if the app missed its full-quota sample.
        // Do not interpret small reset-time corrections before the old boundary as a new period.
        if let oldReset = state.resetsAt, let newReset = rateWindow.resetsAt,
           accountContext.observedAt >= oldReset, newReset > accountContext.observedAt,
           newReset.timeIntervalSince(oldReset) > 60
        {
            state.lastRemaining = nil
            state.firedThresholds = []
        }
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
        if let reset = rateWindow.resetsAt, reset > accountContext.observedAt,
           state.resetsAt.map({ reset > $0 }) ?? true
        {
            state.resetsAt = reset
        }
        state.lastRemaining = currentRemaining
        self.quotaWarningState[key] = state
    }

    private func clearQuotaWarningState(provider: UsageProvider, window: QuotaWarningWindow) {
        self.quotaWarningState = self.quotaWarningState.filter {
            $0.key.provider != provider.instanceID || $0.key.window != window
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
