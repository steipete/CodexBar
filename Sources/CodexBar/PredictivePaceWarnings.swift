import CodexBarCore
import Foundation

struct PredictivePaceWarningStateKey: Hashable {
    let provider: UsageProvider
    let accountDiscriminator: String
    let window: QuotaWarningWindow
    let resetWindow: PredictivePaceWarningResetWindow
}

struct PredictivePaceWarningResetWindow: Hashable {
    let windowMinutes: Int?
    let resetsAt: Date

    func belongsToSameCycle(as other: Self) -> Bool {
        guard self.windowMinutes == other.windowMinutes else { return false }
        let tolerance = self.windowMinutes.map { max(TimeInterval($0 * 60) / 2, 300) } ?? 300
        return abs(self.resetsAt.timeIntervalSince(other.resetsAt)) < tolerance
    }
}

struct PredictivePaceWarningEvent: Equatable {
    let window: QuotaWarningWindow
    let etaSeconds: TimeInterval
    let accountDisplayName: String?
}

enum PredictivePaceWarningNotificationLogic {
    static func notificationIDPrefix(provider: UsageProvider, event: PredictivePaceWarningEvent) -> String {
        "predictive-pace-warning-\(provider.rawValue)-\(event.window.rawValue)"
    }

    static func notificationCopy(
        providerName: String,
        event: PredictivePaceWarningEvent,
        now: Date = .init()) -> (title: String, body: String)
    {
        let windowLabel = event.window.localizedNotificationDisplayName
        let title = L("predictive_pace_warning_notification_title", providerName, windowLabel)
        let durationText = Self.durationText(seconds: event.etaSeconds, now: now)
        let body = if let accountDisplayName = event.accountDisplayName {
            L("predictive_pace_warning_notification_body_with_account", accountDisplayName, durationText)
        } else {
            L("predictive_pace_warning_notification_body", durationText)
        }
        return (title, body)
    }

    static func shouldNotify(pace: UsagePace) -> Bool {
        guard !pace.willLastToReset else { return false }
        guard let etaSeconds = pace.etaSeconds, etaSeconds > 0 else { return false }
        guard (pace.runOutProbability ?? 1) >= 0.5 else { return false }
        return true
    }

    static func recordObservation(
        key: PredictivePaceWarningStateKey,
        pace: UsagePace,
        notifiedKeys: inout Set<PredictivePaceWarningStateKey>) -> Bool
    {
        if pace.willLastToReset {
            notifiedKeys.remove(key)
            return false
        }

        guard self.shouldNotify(pace: pace) else { return false }
        guard !notifiedKeys.contains(key) else { return false }
        notifiedKeys.insert(key)
        return true
    }

    static func reconcileSiblingWindowKeys(
        activeKey: PredictivePaceWarningStateKey,
        notifiedKeys: inout Set<PredictivePaceWarningStateKey>)
    {
        let siblingKeys = notifiedKeys.filter { key in
            key.provider == activeKey.provider &&
                key.accountDiscriminator == activeKey.accountDiscriminator &&
                key.window == activeKey.window
        }
        guard !siblingKeys.isEmpty else { return }

        let alreadyWarnedThisCycle = siblingKeys.contains { key in
            key.resetWindow.belongsToSameCycle(as: activeKey.resetWindow)
        }
        notifiedKeys.subtract(siblingKeys)
        if alreadyWarnedThisCycle {
            // Follow small provider reset-time corrections without re-alerting. Replacing the key
            // lets successive relative-TTL observations move together instead of accumulating drift.
            notifiedKeys.insert(activeKey)
        }
    }

    private static func durationText(seconds: TimeInterval, now: Date) -> String {
        let countdown = UsageFormatter.resetCountdownDescription(from: now.addingTimeInterval(seconds), now: now)
        if countdown.hasPrefix("in ") {
            return String(countdown.dropFirst(3))
        }
        return countdown
    }
}

@MainActor
extension UsageStore {
    func handlePredictivePaceWarningTransitions(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        accountDiscriminatorOverride: String? = nil)
    {
        guard self.settings.predictivePaceWarningNotificationsEnabled else {
            self.predictivePaceWarningNotifiedKeys = Set(
                self.predictivePaceWarningNotifiedKeys.filter { $0.provider != provider })
            return
        }
        guard provider == .codex || provider == .claude else { return }
        guard let accountDiscriminator = self.predictivePaceWarningAccountDiscriminator(
            provider: provider,
            snapshot: snapshot,
            accountDiscriminatorOverride: accountDiscriminatorOverride)
        else { return }

        let candidates = self.predictivePaceWarningCandidates(provider: provider, snapshot: snapshot)
        for candidate in candidates {
            guard let resetWindow = Self.predictivePaceWarningResetWindow(for: candidate.rateWindow) else {
                continue
            }
            let key = PredictivePaceWarningStateKey(
                provider: provider,
                accountDiscriminator: accountDiscriminator,
                window: candidate.window,
                resetWindow: resetWindow)
            PredictivePaceWarningNotificationLogic.reconcileSiblingWindowKeys(
                activeKey: key,
                notifiedKeys: &self.predictivePaceWarningNotifiedKeys)

            guard PredictivePaceWarningNotificationLogic.recordObservation(
                key: key,
                pace: candidate.pace,
                notifiedKeys: &self.predictivePaceWarningNotifiedKeys)
            else { continue }

            self.postPredictivePaceWarning(
                PredictivePaceWarningEvent(
                    window: candidate.window,
                    etaSeconds: candidate.pace.etaSeconds ?? 0,
                    accountDisplayName: self.predictivePaceWarningAccountDisplayName(
                        provider: provider,
                        snapshot: snapshot)),
                provider: provider,
                now: snapshot.updatedAt)
        }
    }

    private func predictivePaceWarningCandidates(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> [(window: QuotaWarningWindow, rateWindow: RateWindow, pace: UsagePace)]
    {
        var candidates: [(window: QuotaWarningWindow, rateWindow: RateWindow, pace: UsagePace)] = []
        let now = snapshot.updatedAt

        if let sessionWindow = self.predictivePaceWarningSessionWindow(provider: provider, snapshot: snapshot),
           !sessionWindow.isSyntheticPlaceholder,
           let sessionPace = UsagePaceText.sessionPace(provider: provider, window: sessionWindow, now: now)
        {
            candidates.append((window: .session, rateWindow: sessionWindow, pace: sessionPace))
        }

        if let weeklyWindow = self.predictivePaceWarningWeeklyWindow(provider: provider, snapshot: snapshot),
           let weeklyPace = self.weeklyPace(provider: provider, window: weeklyWindow, now: now)
        {
            candidates.append((window: .weekly, rateWindow: weeklyWindow, pace: weeklyPace))
        }

        return candidates
    }

    private func predictivePaceWarningSessionWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        if provider == .codex {
            return self.codexConsumerProjection(
                surface: .liveCard,
                snapshotOverride: snapshot,
                now: snapshot.updatedAt)
                .sourceRateWindow(for: .session)
        }
        return self.sessionQuotaWindow(provider: provider, snapshot: snapshot)?.window
    }

    private func predictivePaceWarningWeeklyWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        if provider == .codex {
            return self.codexConsumerProjection(
                surface: .liveCard,
                snapshotOverride: snapshot,
                now: snapshot.updatedAt)
                .sourceRateWindow(for: .weekly)
        }
        return snapshot.secondary
    }

    private func predictivePaceWarningAccountDiscriminator(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        accountDiscriminatorOverride: String? = nil) -> String?
    {
        if provider == .codex {
            return self.codexOwnershipContext(
                preferredEmail: snapshot.accountEmail(for: .codex),
                snapshot: snapshot)
                .canonicalKey
        }

        if let accountDiscriminatorOverride = accountDiscriminatorOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !accountDiscriminatorOverride.isEmpty
        {
            return accountDiscriminatorOverride
        }

        guard let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !account.isEmpty
        else { return nil }
        return "email:\(account)"
    }

    static func warningClaudeAccountDiscriminator(
        strategyKind: ProviderFetchKind,
        observation: ClaudeOAuthActiveAccountObservation,
        oauthHistoryOwnerIdentifier: String? = nil) -> String?
    {
        switch strategyKind {
        case .cli:
            return self.warningClaudeActiveAccountDiscriminator(observation: observation)
        case .oauth:
            if let activeAccount = self.warningClaudeActiveAccountDiscriminator(
                observation: observation)
            {
                return activeAccount
            }
            guard let owner = oauthHistoryOwnerIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !owner.isEmpty
            else { return nil }
            // OAuth usage has no email. Keep a credential-scoped fallback so warning episodes remain
            // account-scoped when Claude's active-account metadata is unavailable.
            return "claude-oauth-owner:\(owner)"
        case .apiToken, .localProbe, .web, .webDashboard:
            return nil
        }
    }

    private static func warningClaudeActiveAccountDiscriminator(
        observation: ClaudeOAuthActiveAccountObservation) -> String?
    {
        guard case let .stable(identity) = observation,
              let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty
        else { return nil }
        return "claude-account:\(identity)"
    }

    static func warningTokenAccountDiscriminator(_ account: ProviderTokenAccount?) -> String? {
        guard let account else { return nil }
        return "token-account:\(account.id.uuidString.lowercased())"
    }

    private func predictivePaceWarningAccountDisplayName(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard !self.settings.hidePersonalInfo else { return nil }
        let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !account.isEmpty else { return nil }
        return account
    }

    private static func predictivePaceWarningResetWindow(for window: RateWindow)
        -> PredictivePaceWarningResetWindow?
    {
        guard let resetsAt = window.resetsAt else { return nil }
        return PredictivePaceWarningResetWindow(
            windowMinutes: window.windowMinutes,
            resetsAt: resetsAt)
    }
}
