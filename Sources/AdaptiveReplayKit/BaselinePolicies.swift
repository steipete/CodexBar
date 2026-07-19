import AdaptiveRefreshCore
import Foundation

/// Replay adapter for the same canonical policy core used by the CodexBar app.
public struct AdaptiveReplayPolicy: ReplayPolicy, Sendable {
    public let name = "adaptive"

    /// Matches `UsageStore.noteMenuOpened(at:)`'s adaptive-only advance guard: this is the one
    /// baseline that actually models the interaction-advance path, so it is the only one that
    /// overrides the protocol's `false` default.
    public let advancesOnInteraction = true

    public init() {}

    public func decide(_ input: ReplayPolicyInput) -> ReplayPolicyDecision {
        let decision = AdaptiveRefreshPolicyCore().nextDelay(for: AdaptiveRefreshPolicyCore.Input(
            now: input.now,
            lastMenuOpenAt: input.lastMenuOpenAt,
            lastCodingActivityAt: nil,
            lowPowerModeEnabled: input.lowPowerModeEnabled,
            thermalPressure: input.thermalState.isConstrained ? .constrained : .nominal))
        return ReplayPolicyDecision(
            delaySeconds: TimeInterval(decision.delay.components.seconds),
            reason: decision.reason.rawValue)
    }
}

/// A fixed-cadence baseline: always waits the same interval, regardless of signals. Used to
/// compare the adaptive policy against the flat refresh frequencies CodexBar also offers
/// (2/5/15/30 minutes). Never advances on interaction (`advancesOnInteraction` stays the protocol
/// default of `false`), matching the real app: fixed-cadence refresh frequencies never wire up
/// `noteMenuOpened`'s advance check.
public struct FixedIntervalPolicy: ReplayPolicy, Sendable {
    public let name: String
    private let intervalSeconds: TimeInterval

    public init(minutes: Int) {
        self.name = "fixed-\(minutes)m"
        self.intervalSeconds = TimeInterval(minutes) * 60
    }

    public func decide(_: ReplayPolicyInput) -> ReplayPolicyDecision {
        ReplayPolicyDecision(delaySeconds: self.intervalSeconds, reason: "fixed")
    }
}

/// The degenerate floor: never schedules a refresh. A trace replayed against this policy always
/// reports zero refreshes, which is the point — it establishes the worst-case staleness bound the
/// other policies are compared against.
public struct ManualPolicy: ReplayPolicy, Sendable {
    public let name = "manual"

    public init() {}

    public func decide(_: ReplayPolicyInput) -> ReplayPolicyDecision {
        ReplayPolicyDecision(delaySeconds: nil, reason: "manual")
    }
}
