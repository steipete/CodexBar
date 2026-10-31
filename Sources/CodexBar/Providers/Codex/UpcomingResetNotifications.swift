import CodexBarCore
import Foundation

/// Lead-time stages ahead of a reset boundary, ordered from earliest to last call.
enum UpcomingResetStage: Int, Codable, CaseIterable, Equatable {
    case earlyWarning
    case lastCall

    var leadTime: TimeInterval {
        switch self {
        case .earlyWarning: 24 * 60 * 60
        case .lastCall: 60 * 60
        }
    }
}

struct UpcomingResetNotificationState: Codable, Equatable {
    let resetBoundary: Date
    var firedStages: Set<UpcomingResetStage>
}

struct UpcomingResetWarningEvent: Equatable {
    let resetsAt: Date
    let remainingPercent: Double
    let accountDisplayName: String?
}

enum UpcomingResetNotificationLogic {
    /// The deepest stage whose lead time has elapsed for `resetsAt` without having fired for that
    /// boundary yet, alongside the state that records it. A boundary change re-arms every stage;
    /// a boundary that has already passed never fires.
    static func crossedStage(
        previousState: UpcomingResetNotificationState?,
        resetsAt: Date,
        now: Date) -> (stage: UpcomingResetStage, state: UpcomingResetNotificationState)?
    {
        guard resetsAt > now else { return nil }
        var state = previousState.flatMap { $0.resetBoundary == resetsAt ? $0 : nil }
            ?? UpcomingResetNotificationState(resetBoundary: resetsAt, firedStages: [])
        guard let stage = UpcomingResetStage.allCases
            .last(where: { resetsAt.timeIntervalSince(now) <= $0.leadTime }),
            !state.firedStages.contains(stage)
        else { return nil }
        state.firedStages.formUnion(UpcomingResetStage.allCases.filter { $0.rawValue <= stage.rawValue })
        return (stage, state)
    }

    static func notificationCopy(
        providerName: String,
        event: UpcomingResetWarningEvent,
        now: Date = .init()) -> (title: String, body: String)
    {
        let title = L(
            "upcoming_reset_notification_title",
            providerName,
            QuotaWarningWindow.weekly.localizedNotificationDisplayName)
        let remainingText = UsageFormatter.percentString(event.remainingPercent)
        let durationText = UsageFormatter.resetCountdownDuration(from: event.resetsAt, now: now)
        let body = if let accountDisplayName = event.accountDisplayName {
            L("upcoming_reset_notification_body_with_account", accountDisplayName, remainingText, durationText)
        } else {
            L("upcoming_reset_notification_body", remainingText, durationText)
        }
        return (title, body)
    }
}

@MainActor
extension UsageStore {
    nonisolated static let upcomingResetNotificationStatesDefaultsKey = "upcomingResetNotificationStates"

    /// Warns while the Codex weekly window is about to reset with quota still unused, so banked
    /// quota is spent instead of lost. Receipts persist per reset boundary and survive restarts.
    func handleUpcomingResetWarning(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        accountDiscriminator: String?,
        now: Date = .init())
    {
        guard provider == .codex, self.settings.upcomingResetNotificationsEnabled else { return }
        guard let weekly = snapshot.secondary?.measured, weekly.windowMinutes == 7 * 24 * 60,
              let resetsAt = weekly.resetsAt,
              weekly.remainingPercent.isFinite, weekly.remainingPercent > 0,
              let owner = accountDiscriminator ?? CodexIdentityResolver
                  .normalizeEmail(snapshot.accountEmail(for: .codex))
                  .map(CodexHistoryOwnership.canonicalEmailHashKey(for:))
        else { return }
        let key = "\(provider.instanceID.rawValue):\(owner)"
        var states: [String: UpcomingResetNotificationState] = Self.loadPlanUtilizationStates(
            from: self.settings.userDefaults,
            defaultsKey: Self.upcomingResetNotificationStatesDefaultsKey,
            logName: "Upcoming reset notifications")
        guard let crossed = UpcomingResetNotificationLogic.crossedStage(
            previousState: states[key],
            resetsAt: resetsAt,
            now: now)
        else { return }
        states[key] = crossed.state
        self.persistPlanUtilizationStates(
            states,
            defaultsKey: Self.upcomingResetNotificationStatesDefaultsKey,
            logName: "Upcoming reset notifications")
        let accountDisplayName = self.warningAccountDisplayName(provider: provider, snapshot: snapshot)
        self.sessionQuotaNotifier.postUpcomingResetWarning(
            event: UpcomingResetWarningEvent(
                resetsAt: resetsAt,
                remainingPercent: weekly.remainingPercent,
                accountDisplayName: accountDisplayName),
            provider: provider,
            now: now,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.settings.upcomingResetNotificationsEnabled && self.isEnabled(.codex)
                    && (accountDisplayName == nil || !self.settings.hidePersonalInfo)
            })
    }
}
