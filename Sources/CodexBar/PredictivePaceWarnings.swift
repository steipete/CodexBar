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
        accountDiscriminatorOverride: String? = nil,
        requiresKnownAccount: Bool = false)
    {
        guard self.settings.predictivePaceWarningNotificationsEnabled else {
            self.predictivePaceWarningNotifiedKeys = Set(
                self.predictivePaceWarningNotifiedKeys.filter { $0.provider != provider })
            return
        }
        guard provider == .codex || provider == .claude else { return }
        guard !requiresKnownAccount || accountDiscriminatorOverride != nil else { return }
        guard let accountDiscriminator = self.predictivePaceWarningAccountDiscriminator(
            provider: provider,
            snapshot: snapshot,
            accountDiscriminatorOverride: accountDiscriminatorOverride)
        else { return }

        let candidates = self.predictivePaceWarningCandidates(provider: provider, snapshot: snapshot)
        for candidate in candidates {
            guard let resetsAt = candidate.rateWindow.resetsAt else {
                continue
            }
            let key = PredictivePaceWarningStateKey(
                provider: provider,
                accountDiscriminator: accountDiscriminator,
                window: candidate.window,
                resetWindow: PredictivePaceWarningResetWindow(
                    windowMinutes: candidate.rateWindow.windowMinutes, resetsAt: resetsAt))
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
                    accountDisplayName: self.warningAccountDisplayName(
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
        let windows: [(QuotaWarningWindow, RateWindow?)]
        if provider == .codex {
            let projection = self.codexConsumerProjection(
                surface: .liveCard, snapshotOverride: snapshot, now: snapshot.updatedAt)
            windows = [
                (.session, projection.sourceRateWindow(for: .session)),
                (.weekly, projection.sourceRateWindow(for: .weekly)),
            ]
        } else {
            windows = [
                (.session, self.sessionQuotaWindow(provider: provider, snapshot: snapshot)?.window),
                (.weekly, snapshot.secondary),
            ]
        }
        return windows.compactMap { window, rateWindow in
            guard let rateWindow else { return nil }
            let pace: UsagePace? = switch window {
            case .session:
                rateWindow.isSyntheticPlaceholder ? nil : UsagePaceText.sessionPace(
                    provider: provider, window: rateWindow, now: snapshot.updatedAt)
            case .weekly:
                self.weeklyPace(
                    provider: provider,
                    window: rateWindow,
                    dataConfidence: snapshot.dataConfidence,
                    now: snapshot.updatedAt)
            }
            return pace.map { (window, rateWindow, $0) }
        }
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

    func warningClaudeAccountDiscriminators(
        strategyKind: ProviderFetchKind,
        observation: ClaudeOAuthActiveAccountObservation,
        oauthHistoryOwnerIdentifier: String? = nil) -> (quota: String?, source: String?)
    {
        guard strategyKind == .oauth || strategyKind == .cli else { return (nil, nil) }
        let identity: String? = if case let .stable(identity) = observation {
            identity?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            nil
        }
        let unknownAccount = "claude-account:unknown"
        var account = identity.flatMap { $0.isEmpty ? nil : "claude-account:\($0)" }
        var source = account ?? unknownAccount
        if strategyKind == .oauth,
           let owner = oauthHistoryOwnerIdentifier?
               .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !owner.isEmpty
        {
            let ownerKey = "claude-oauth-owner:\(owner)"
            source = account ?? ownerKey
            if let boundIdentity = Self.loadClaudeOAuthAccountUuidMap(from: self.settings.userDefaults)[owner] {
                let boundAccount = "claude-account:\(boundIdentity)"
                // A stable metadata observation alone cannot bind credentials to a different verified owner.
                guard account == nil || account == boundAccount else { return (nil, nil) }
                self.reconcileClaudeQuotaWarningOwner(ownerKey, account: boundAccount)
                account = boundAccount
            }
        }
        if let account, account != unknownAccount {
            self.reconcileClaudeQuotaWarningOwner(unknownAccount, account: account)
        }
        return (account ?? source, source)
    }

    private func reconcileClaudeQuotaWarningOwner(_ owner: String, account: String) {
        for (key, prior) in self.quotaWarningState where key.provider == .claude && key.accountDiscriminator == owner {
            let accountKey = QuotaWarningStateKey(
                provider: key.provider, window: key.window, accountDiscriminator: account, windowID: key.windowID)
            if prior.observedAt >= (self.quotaWarningState[accountKey]?.observedAt ?? .distantPast) {
                self.quotaWarningState[accountKey] = prior
            }
            self.quotaWarningState.removeValue(forKey: key)
        }
    }

    static func warningTokenAccountDiscriminator(_ account: ProviderTokenAccount?) -> String? {
        guard let account else { return nil }
        return "token-account:\(account.id.uuidString.lowercased())"
    }
}
