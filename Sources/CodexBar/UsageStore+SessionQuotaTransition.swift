import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func handleSessionQuotaTransition(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        codexOwnerKey: CodexSessionQuotaOwnerKey? = nil,
        now: Date = Date())
    {
        // Session quota notifications are tied to the primary session window. Copilot free plans can
        // expose only chat quota, so allow Copilot to fall back to secondary for transition tracking.
        // Command Code synthesizes a depleted primary while subscription enrichment is unavailable.
        // Preserve the prior notification state for that placeholder, but accept positive credit data.
        if provider == .commandcode,
           snapshot.commandCodeSubscriptionEnrichmentUnavailable,
           SessionQuotaNotificationLogic.isDepleted(snapshot.primary?.remainingPercent)
        {
            return
        }
        // Hooks have their own enable switch, so a configured quota_reached hook must fire on a
        // real depletion even when session quota notifications are off. Run transition detection
        // whenever notifications OR a matching hook rule is active; gate the OS notification post
        // on the notification setting, but emit the hook on any depletion.
        let notificationsEnabled = self.settings.sessionQuotaNotificationsEnabled
        let hooksActive = self.hasQuotaHookRule(event: .quotaReached, provider: provider)
        let detectionEnabled = notificationsEnabled || hooksActive
        if provider == .codex, !detectionEnabled {
            self.requireFreshCodexSessionQuotaBaseline(observedAt: snapshot.updatedAt)
            self.sessionQuotaLogger.debug("Codex session notifications disabled; cleared notification baseline")
            return
        }
        if provider == .codex, codexOwnerKey == nil {
            self.requireFreshCodexSessionQuotaBaseline(observedAt: snapshot.updatedAt)
            self.sessionQuotaLogger.debug("missing Codex session owner; cleared notification baseline")
            return
        }
        guard let sessionWindow = self.sessionQuotaWindow(provider: provider, snapshot: snapshot) else {
            if provider == .commandcode, snapshot.commandCodeSubscriptionEnrichmentUnavailable {
                return
            }
            if provider == .codex {
                if let previous = self.sessionQuotaTransitionStates[.codex] {
                    if previous.codexOwnerKey != codexOwnerKey {
                        self.requireFreshCodexSessionQuotaBaseline(observedAt: snapshot.updatedAt)
                    } else {
                        self.sessionQuotaTransitionStates[.codex] = previous.advancingObservationWatermark(
                            to: snapshot.updatedAt)
                    }
                } else if self.codexSessionQuotaBaselineRequirement != nil {
                    self.requireFreshCodexSessionQuotaBaseline(observedAt: snapshot.updatedAt)
                }
                self.sessionQuotaLogger.debug("missing Codex session window; retained notification baseline")
            } else {
                self.clearSessionQuotaTransitionState(provider: provider)
            }
            return
        }
        guard !sessionWindow.window.isSyntheticPlaceholder else { return }
        let currentRemaining = sessionWindow.window.remainingPercent
        let currentSource = sessionWindow.source
        let currentResetBoundary = sessionWindow.window.resetsAt
        if provider == .codex,
           let requirement = self.codexSessionQuotaBaselineRequirement,
           !requirement.admits(observedAt: snapshot.updatedAt)
        {
            self.sessionQuotaLogger.debug("ignored stale session observation while awaiting a fresh Codex baseline")
            return
        }
        let previousState = self.sessionQuotaTransitionStates[provider]
        let forceBaseline = provider == .codex && self.codexSessionQuotaBaselineRequirement != nil
        let evaluation = SessionQuotaTransitionReducer.evaluate(
            previous: previousState,
            observation: SessionQuotaTransitionObservation(
                provider: provider,
                remaining: currentRemaining,
                source: currentSource,
                resetBoundary: currentResetBoundary,
                observedAt: snapshot.updatedAt,
                evaluationTime: now,
                codexOwnerKey: codexOwnerKey),
            notificationsEnabled: detectionEnabled,
            forceBaseline: forceBaseline)
        self.sessionQuotaTransitionStates[provider] = evaluation.state
        if provider == .codex {
            self.codexSessionQuotaBaselineRequirement = nil
        }

        let providerText = provider.rawValue
        let previousRemaining = previousState?.remaining
        switch evaluation.outcome {
        case .none:
            if SessionQuotaNotificationLogic.isDepleted(currentRemaining) ||
                SessionQuotaNotificationLogic.isDepleted(previousRemaining)
            {
                let reason = self.settings.sessionQuotaNotificationsEnabled
                    ? "no transition"
                    : "notifications disabled"
                self.sessionQuotaLogger.debug(
                    "\(reason): provider=\(providerText) " +
                        "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)")
            }
        case .baselineChanged:
            self.sessionQuotaLogger.debug(
                "session notification baseline changed: provider=\(providerText) curr=\(currentRemaining)")
        case .staleCodexObservation:
            self.sessionQuotaLogger.debug(
                "ignored stale session observation: provider=\(providerText) curr=\(currentRemaining)")
        case .suppressedCodexRestore:
            self.sessionQuotaLogger.info(
                "suppressed transient restore: provider=\(providerText) " +
                    "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)")
        case .awaitingCodexRestoreConfirmation:
            self.sessionQuotaLogger.info(
                "awaiting restore confirmation: provider=\(providerText) " +
                    "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)")
        case .depleted, .restored:
            let transition = evaluation.outcome.transition
            self.sessionQuotaLogger.info(
                "transition \(String(describing: transition)): provider=\(providerText) " +
                    "prev=\(previousRemaining ?? -1) curr=\(currentRemaining)")
            self.publishSessionQuotaTransition(
                transition,
                provider: provider,
                sessionWindow: sessionWindow,
                snapshot: snapshot,
                notificationsEnabled: notificationsEnabled)
        }
    }

    /// Posts the OS notification (only when enabled) and emits the quota_reached hook on depletion.
    private func publishSessionQuotaTransition(
        _ transition: SessionQuotaTransition,
        provider: UsageProvider,
        sessionWindow: (window: RateWindow, source: SessionQuotaWindowSource),
        snapshot: UsageSnapshot,
        notificationsEnabled: Bool)
    {
        if notificationsEnabled {
            self.sessionQuotaNotifier.post(transition: transition, provider: provider, badge: nil)
        }
        if transition == .depleted {
            self.emitQuotaReachedHook(provider: provider, sessionWindow: sessionWindow, snapshot: snapshot)
        }
    }
}
