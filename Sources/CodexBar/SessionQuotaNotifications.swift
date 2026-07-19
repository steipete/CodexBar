import AppKit
import CodexBarCore
import Foundation
@preconcurrency import UserNotifications

enum SessionQuotaTransition: Equatable {
    case none
    case depleted
    case restored
}

struct SessionQuotaTransitionState: Equatable {
    let remaining: Double
    let source: UsageStore.SessionQuotaWindowSource
    let observedAt: Date
    let codexOwnerKey: CodexSessionQuotaOwnerKey?
    let trustedResetBoundary: Date?
    let pendingCodexRestoreObservationAt: Date?

    func advancingObservationWatermark(to observedAt: Date) -> Self {
        guard observedAt > self.observedAt else { return self }
        return Self(
            remaining: self.remaining,
            source: self.source,
            observedAt: observedAt,
            codexOwnerKey: self.codexOwnerKey,
            trustedResetBoundary: self.trustedResetBoundary,
            pendingCodexRestoreObservationAt: self.pendingCodexRestoreObservationAt)
    }
}

struct CodexSessionQuotaBaselineRequirement: Equatable {
    let observedAtWatermark: Date?

    func merging(observedAt: Date?) -> Self {
        guard let observedAt else { return self }
        guard let watermark = self.observedAtWatermark else {
            return Self(observedAtWatermark: observedAt)
        }
        return Self(observedAtWatermark: max(watermark, observedAt))
    }

    func admits(observedAt: Date) -> Bool {
        self.observedAtWatermark.map { observedAt > $0 } ?? true
    }
}

enum SessionQuotaTransitionOutcome: Equatable {
    case none
    case depleted
    case restored
    case baselineChanged
    case staleCodexObservation
    case suppressedCodexRestore
    case awaitingCodexRestoreConfirmation

    var transition: SessionQuotaTransition {
        switch self {
        case .depleted: .depleted
        case .restored: .restored
        default: .none
        }
    }
}

struct SessionQuotaTransitionEvaluation: Equatable {
    let outcome: SessionQuotaTransitionOutcome
    let state: SessionQuotaTransitionState
}

struct SessionQuotaTransitionObservation: Equatable {
    let provider: UsageProvider
    let remaining: Double
    let source: UsageStore.SessionQuotaWindowSource
    let resetBoundary: Date?
    let observedAt: Date
    let evaluationTime: Date
    let codexOwnerKey: CodexSessionQuotaOwnerKey?
}

struct QuotaWarningEvent: Equatable {
    let window: QuotaWarningWindow
    let threshold: Int
    let currentRemaining: Double
    let accountDisplayName: String?
    /// Stable id of the extra rate window this warning is for (e.g. `claude-weekly-scoped-fable`),
    /// used to keep OS notification ids unique across sibling windows. `nil` for the primary
    /// session/weekly lanes.
    let windowID: String?
    /// Human-facing window label to render instead of the generic session/weekly name
    /// (e.g. "Fable only", "Daily Routines"). `nil` falls back to the localized lane name.
    let windowDisplayLabel: String?

    init(
        window: QuotaWarningWindow,
        threshold: Int,
        currentRemaining: Double,
        accountDisplayName: String? = nil,
        windowID: String? = nil,
        windowDisplayLabel: String? = nil)
    {
        self.window = window
        self.threshold = threshold
        self.currentRemaining = currentRemaining
        self.accountDisplayName = accountDisplayName
        self.windowID = windowID
        self.windowDisplayLabel = windowDisplayLabel
    }
}

enum SessionQuotaNotificationLogic {
    static let depletedThreshold: Double = 0.0001

    static func isDepleted(_ remaining: Double?) -> Bool {
        guard let remaining else { return false }
        return remaining <= Self.depletedThreshold
    }

    static func transition(previousRemaining: Double?, currentRemaining: Double?) -> SessionQuotaTransition {
        guard let currentRemaining else { return .none }
        guard let previousRemaining else { return .none }

        let wasDepleted = previousRemaining <= Self.depletedThreshold
        let isDepleted = currentRemaining <= Self.depletedThreshold

        if !wasDepleted, isDepleted {
            return .depleted
        }
        if wasDepleted, !isDepleted {
            return .restored
        }
        return .none
    }

    static func notificationCopy(
        transition: SessionQuotaTransition,
        providerName: String) -> (title: String, body: String)
    {
        switch transition {
        case .none:
            ("", "")
        case .depleted:
            (
                L("session_depleted_notification_title", providerName),
                L("session_depleted_notification_body"))
        case .restored:
            (
                L("session_restored_notification_title", providerName),
                L("session_restored_notification_body"))
        }
    }
}

enum SessionQuotaTransitionReducer {
    static func evaluate(
        previous: SessionQuotaTransitionState?,
        observation: SessionQuotaTransitionObservation,
        notificationsEnabled: Bool,
        forceBaseline: Bool = false) -> SessionQuotaTransitionEvaluation
    {
        if forceBaseline {
            return SessionQuotaTransitionEvaluation(
                outcome: .baselineChanged,
                state: self.baselineState(observation: observation))
        }
        guard let previous else {
            return SessionQuotaTransitionEvaluation(
                outcome: notificationsEnabled && SessionQuotaNotificationLogic.isDepleted(observation.remaining)
                    ? .depleted
                    : .none,
                state: self.baselineState(observation: observation))
        }

        let ownerChanged = observation.provider == .codex && previous.codexOwnerKey != observation.codexOwnerKey
        guard previous.source == observation.source, !ownerChanged else {
            return SessionQuotaTransitionEvaluation(
                outcome: .baselineChanged,
                state: Self.baselineState(observation: observation))
        }

        if observation.provider == .codex, observation.observedAt <= previous.observedAt {
            return SessionQuotaTransitionEvaluation(outcome: .staleCodexObservation, state: previous)
        }

        guard notificationsEnabled else {
            return SessionQuotaTransitionEvaluation(
                outcome: .none,
                state: Self.updatedState(
                    previous: previous,
                    observation: observation))
        }

        let transition = SessionQuotaNotificationLogic.transition(
            previousRemaining: previous.remaining,
            currentRemaining: observation.remaining)
        if transition != .restored || observation.provider != .codex {
            let outcome: SessionQuotaTransitionOutcome = switch transition {
            case .none: .none
            case .depleted: .depleted
            case .restored: .restored
            }
            let preserveDepletedBoundary = observation.provider == .codex &&
                previous.trustedResetBoundary != nil &&
                SessionQuotaNotificationLogic.isDepleted(previous.remaining) &&
                SessionQuotaNotificationLogic.isDepleted(observation.remaining)
            let preserveCodexBoundary = preserveDepletedBoundary ||
                (observation.provider == .codex && previous.trustedResetBoundary.map {
                    observation.evaluationTime < $0 || observation.observedAt < $0
                } == true)
            return SessionQuotaTransitionEvaluation(
                outcome: outcome,
                state: Self.updatedState(
                    previous: previous,
                    observation: observation,
                    preserveCodexResetBoundary: preserveCodexBoundary))
        }

        if let trustedResetBoundary = previous.trustedResetBoundary {
            // The prior depleted boundary is authoritative while it remains in the future. A transient
            // positive sample must not replace it, even when that sample advertises an advanced boundary.
            guard observation.evaluationTime >= trustedResetBoundary,
                  observation.observedAt >= trustedResetBoundary
            else {
                return SessionQuotaTransitionEvaluation(
                    outcome: .suppressedCodexRestore,
                    state: Self.preservedDepletedState(
                        previous: previous,
                        observation: observation))
            }

            if let resetBoundary = self.validResetBoundary(
                observation.resetBoundary,
                observedAt: observation.observedAt,
                evaluationTime: observation.evaluationTime),
                !UsageStore.areEquivalentPlanUtilizationResetBoundaries(trustedResetBoundary, resetBoundary)
            {
                if resetBoundary > trustedResetBoundary {
                    return SessionQuotaTransitionEvaluation(
                        outcome: .restored,
                        state: Self.updatedState(
                            previous: previous,
                            observation: observation))
                }
            }
        }

        // Missing, equivalent, regressed, or already elapsed metadata can be a stale post-reset snapshot.
        // Two fresh positive observations confirm the restore without trusting one ambiguous sample.
        if let pending = previous.pendingCodexRestoreObservationAt, observation.observedAt > pending {
            return SessionQuotaTransitionEvaluation(
                outcome: .restored,
                state: Self.updatedState(
                    previous: previous,
                    observation: observation))
        }
        return SessionQuotaTransitionEvaluation(
            outcome: .awaitingCodexRestoreConfirmation,
            state: Self.preservedDepletedState(
                previous: previous,
                observation: observation,
                pendingRestoreObservationAt: observation.observedAt))
    }

    private static func baselineState(
        observation: SessionQuotaTransitionObservation) -> SessionQuotaTransitionState
    {
        SessionQuotaTransitionState(
            remaining: observation.remaining,
            source: observation.source,
            observedAt: observation.observedAt,
            codexOwnerKey: observation.provider == .codex ? observation.codexOwnerKey : nil,
            trustedResetBoundary: observation.provider == .codex
                ? self.validResetBoundary(
                    observation.resetBoundary,
                    observedAt: observation.observedAt,
                    evaluationTime: observation.evaluationTime)
                : nil,
            pendingCodexRestoreObservationAt: nil)
    }

    private static func updatedState(
        previous: SessionQuotaTransitionState,
        observation: SessionQuotaTransitionObservation,
        preserveCodexResetBoundary: Bool = false) -> SessionQuotaTransitionState
    {
        let trustedResetBoundary: Date? = if observation.provider != .codex {
            nil
        } else if preserveCodexResetBoundary {
            previous.trustedResetBoundary
        } else {
            self.monotonicResetBoundary(
                previous: previous.trustedResetBoundary,
                current: self.validResetBoundary(
                    observation.resetBoundary,
                    observedAt: observation.observedAt,
                    evaluationTime: observation.evaluationTime))
        }
        return SessionQuotaTransitionState(
            remaining: observation.remaining,
            source: observation.source,
            observedAt: observation.observedAt,
            codexOwnerKey: observation.provider == .codex ? observation.codexOwnerKey : nil,
            trustedResetBoundary: trustedResetBoundary,
            pendingCodexRestoreObservationAt: nil)
    }

    private static func preservedDepletedState(
        previous: SessionQuotaTransitionState,
        observation: SessionQuotaTransitionObservation,
        pendingRestoreObservationAt: Date? = nil) -> SessionQuotaTransitionState
    {
        SessionQuotaTransitionState(
            remaining: previous.remaining,
            source: observation.source,
            observedAt: observation.observedAt,
            codexOwnerKey: observation.codexOwnerKey,
            trustedResetBoundary: previous.trustedResetBoundary,
            pendingCodexRestoreObservationAt: pendingRestoreObservationAt)
    }

    private static func monotonicResetBoundary(previous: Date?, current: Date?) -> Date? {
        guard let previous else { return current }
        guard UsageStore.limitResetBoundaryAdvanced(previous: previous, current: current) else { return previous }
        return current
    }

    private static func validResetBoundary(
        _ candidate: Date?,
        observedAt: Date,
        evaluationTime: Date) -> Date?
    {
        guard let candidate, candidate > observedAt, candidate > evaluationTime else { return nil }
        return candidate
    }
}

enum QuotaWarningNotificationLogic {
    static func notificationIDPrefix(provider: UsageProvider, event: QuotaWarningEvent) -> String {
        let windowSegment = event.windowID.map { "-\($0)" } ?? ""
        return "quota-warning-\(provider.rawValue)-\(event.window.rawValue)\(windowSegment)-\(event.threshold)"
    }

    static func notificationCopy(
        providerName: String,
        window: QuotaWarningWindow,
        threshold: Int,
        currentRemaining: Double,
        accountDisplayName: String? = nil,
        windowDisplayLabel: String? = nil) -> (title: String, body: String)
    {
        let windowLabel = windowDisplayLabel ?? window.localizedNotificationDisplayName
        let remainingText = Self.percentText(currentRemaining)
        let title = L("quota_warning_notification_title", providerName, windowLabel)
        let body = if let accountDisplayName {
            L(
                "quota_warning_notification_body_with_account",
                accountDisplayName,
                remainingText,
                threshold,
                windowLabel)
        } else {
            L(
                "quota_warning_notification_body",
                remainingText,
                threshold,
                windowLabel)
        }
        return (title, body)
    }

    static func crossedThreshold(
        previousRemaining: Double?,
        currentRemaining: Double,
        thresholds: [Int],
        alreadyFired: Set<Int>) -> Int?
    {
        let sanitized = QuotaWarningThresholds.active(thresholds)
        let eligible = sanitized.filter { threshold in
            currentRemaining <= Double(threshold) && !alreadyFired.contains(threshold)
        }
        guard !eligible.isEmpty else { return nil }

        if let previousRemaining {
            let crossed = eligible.filter { previousRemaining > Double($0) }
            return crossed.min()
        }

        return eligible.min()
    }

    static func firedThresholdsAfterWarning(threshold: Int, thresholds: [Int]) -> Set<Int> {
        Set(QuotaWarningThresholds.active(thresholds).filter { $0 >= threshold })
    }

    static func thresholdsToClear(currentRemaining: Double, alreadyFired: Set<Int>) -> Set<Int> {
        Set(alreadyFired.filter { currentRemaining > Double($0) })
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int(min(100, max(0, value)).rounded()))%"
    }
}

@MainActor
extension UsageStore {
    func sessionQuotaWindow(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> (window: RateWindow, source: SessionQuotaWindowSource)?
    {
        guard provider != .mimo, provider != .qoder else { return nil }
        if provider == .antigravity {
            guard let window = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 5 * 60) else {
                return nil
            }
            let source: SessionQuotaWindowSource = Self.hasAntigravityQuotaSummaryWindows(snapshot: snapshot)
                ? .antigravityQuotaSummary
                : .antigravityLegacy
            return (window, source)
        }
        // z.ai's typed sessionTokenLimit is rendered in the tertiary lane when the response also
        // contains its weekly token limit and MCP time limit. Prefer that semantic session lane.
        if provider == .zai, let tertiary = snapshot.tertiary {
            return (tertiary, .zaiTertiary)
        }
        if let primary = snapshot.primary, Self.isSessionWindow(primary) {
            return (primary, .primary)
        }
        if provider == .copilot, let secondary = snapshot.secondary {
            return (secondary, .copilotSecondaryFallback)
        }
        return nil
    }

    private static func isSessionWindow(_ window: RateWindow) -> Bool {
        guard let minutes = window.windowMinutes else { return true }
        return minutes <= 6 * 60
    }

    func clearSessionQuotaTransitionState(provider: UsageProvider) {
        let removedState = self.sessionQuotaTransitionStates.removeValue(forKey: provider)
        // Generic provider cleanup can run while Codex is disabled or temporarily unavailable. Preserve
        // an already-depleted baseline across recovery so depletion cannot refire, but let a newly depleted
        // account notify after a positive baseline was discarded.
        if provider == .codex,
           let removedState,
           SessionQuotaNotificationLogic.isDepleted(removedState.remaining)
        {
            self.updateCodexSessionQuotaBaselineRequirement(observedAt: removedState.observedAt)
        }
    }

    func requireFreshCodexSessionQuotaBaseline(observedAt: Date? = nil) {
        let removedState = self.sessionQuotaTransitionStates.removeValue(forKey: .codex)
        self.updateCodexSessionQuotaBaselineRequirement(observedAt: removedState?.observedAt)
        self.updateCodexSessionQuotaBaselineRequirement(observedAt: observedAt)
    }

    private func updateCodexSessionQuotaBaselineRequirement(observedAt: Date?) {
        let requirement = self.codexSessionQuotaBaselineRequirement ??
            CodexSessionQuotaBaselineRequirement(observedAtWatermark: nil)
        self.codexSessionQuotaBaselineRequirement = requirement.merging(observedAt: observedAt)
    }

    private static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"

    static func hasAntigravityQuotaSummaryWindows(snapshot: UsageSnapshot) -> Bool {
        snapshot.extraRateWindows?.contains {
            $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix)
        } == true
    }

    static func antigravityWindow(
        snapshot: UsageSnapshot,
        windowMinutes: Int) -> RateWindow?
    {
        let windows: [RateWindow] = if Self.hasAntigravityQuotaSummaryWindows(snapshot: snapshot) {
            snapshot.extraRateWindows?
                .filter {
                    $0.usageKnown
                        && $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix)
                        && $0.window.windowMinutes == windowMinutes
                }
                .map(\.window) ?? []
        } else {
            [snapshot.primary, snapshot.secondary, snapshot.tertiary]
                .compactMap(\.self)
                .filter {
                    // Legacy Antigravity family lanes historically drive session notifications.
                    $0.windowMinutes == windowMinutes
                        || (windowMinutes == 5 * 60 && $0.windowMinutes == nil)
                }
        }
        return windows.max { $0.usedPercent < $1.usedPercent }
    }
}

@MainActor
protocol SessionQuotaNotifying: AnyObject {
    func post(transition: SessionQuotaTransition, provider: UsageProvider, badge: NSNumber?)
    func postQuotaWarning(
        event: QuotaWarningEvent,
        provider: UsageProvider,
        soundEnabled: Bool,
        onScreenAlertEnabled: Bool)
    func postPredictivePaceWarning(
        event: PredictivePaceWarningEvent,
        provider: UsageProvider,
        soundEnabled: Bool,
        onScreenAlertEnabled: Bool,
        now: Date)
}

@MainActor
extension SessionQuotaNotifying {
    func postPredictivePaceWarning(
        event _: PredictivePaceWarningEvent,
        provider _: UsageProvider,
        soundEnabled _: Bool,
        onScreenAlertEnabled _: Bool,
        now _: Date)
    {}
}

@MainActor
final class SessionQuotaNotifier: SessionQuotaNotifying {
    private let logger = CodexBarLog.logger(LogCategories.sessionQuotaNotifications)
    private lazy var alertOverlay = QuotaWarningAlertOverlayController()

    init() {}

    func post(transition: SessionQuotaTransition, provider: UsageProvider, badge: NSNumber? = nil) {
        guard transition != .none else { return }

        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName

        let (title, body) = SessionQuotaNotificationLogic.notificationCopy(
            transition: transition,
            providerName: providerName)

        let providerText = provider.rawValue
        let transitionText = String(describing: transition)
        let idPrefix = "session-\(providerText)-\(transitionText)"
        self.logger.info("enqueuing", metadata: ["prefix": idPrefix])
        AppNotifications.shared.post(idPrefix: idPrefix, title: title, body: body, badge: badge)
    }

    func postQuotaWarning(
        event: QuotaWarningEvent,
        provider: UsageProvider,
        soundEnabled: Bool = true,
        onScreenAlertEnabled: Bool = false)
    {
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let threshold = event.threshold
        let copy = QuotaWarningNotificationLogic.notificationCopy(
            providerName: providerName,
            window: event.window,
            threshold: threshold,
            currentRemaining: event.currentRemaining,
            accountDisplayName: event.accountDisplayName,
            windowDisplayLabel: event.windowDisplayLabel)
        let idPrefix = QuotaWarningNotificationLogic.notificationIDPrefix(provider: provider, event: event)
        self.logger.info("enqueuing", metadata: ["prefix": idPrefix])
        if soundEnabled {
            (NSSound(named: "Glass") ?? NSSound(named: "Ping"))?.play()
        }
        if onScreenAlertEnabled {
            self.alertOverlay.show(title: copy.title, message: copy.body)
        }
        NotificationCenter.default.post(
            name: .codexbarQuotaWarningDidPost,
            object: QuotaWarningPostedEvent(
                provider: provider,
                window: event.window,
                threshold: threshold,
                postedAt: Date()))
        AppNotifications.shared.post(idPrefix: idPrefix, title: copy.title, body: copy.body, soundEnabled: false)
    }

    func postPredictivePaceWarning(
        event: PredictivePaceWarningEvent,
        provider: UsageProvider,
        soundEnabled: Bool = true,
        onScreenAlertEnabled: Bool = false,
        now: Date = .init())
    {
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let copy = PredictivePaceWarningNotificationLogic.notificationCopy(
            providerName: providerName,
            event: event,
            now: now)
        let idPrefix = PredictivePaceWarningNotificationLogic.notificationIDPrefix(provider: provider, event: event)
        self.logger.info("enqueuing", metadata: ["prefix": idPrefix])
        if soundEnabled {
            (NSSound(named: "Glass") ?? NSSound(named: "Ping"))?.play()
        }
        if onScreenAlertEnabled {
            self.alertOverlay.show(title: copy.title, message: copy.body)
        }
        AppNotifications.shared.post(idPrefix: idPrefix, title: copy.title, body: copy.body, soundEnabled: false)
    }
}

extension QuotaWarningWindow {
    var localizedNotificationDisplayName: String {
        switch self {
        case .session: L("quota_warning_session")
        case .weekly: L("quota_warning_weekly")
        }
    }
}
