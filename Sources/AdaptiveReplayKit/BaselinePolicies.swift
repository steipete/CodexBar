import Foundation

/// A byte-for-byte mirror of `AdaptiveRefreshPolicy`'s first-match-wins table, re-expressed
/// against `ReplayPolicyInput` because this library cannot import the app target that owns the
/// original. `AdaptiveReplayPolicyMirrorTests` asserts this mirror's output matches the real
/// policy case-for-case across the boundary table; if the two ever drift (someone edits one
/// table's thresholds without the other), that test fails red. Kept in sync by hand — phase 1
/// intentionally accepts this duplication rather than restructuring the upstream PR surface.
public struct MirroredAdaptivePolicy: ReplayPolicy, Sendable {
    public let name = "adaptive"

    /// Mirrors `UsageStore.noteMenuOpened(at:)`'s adaptive-only advance guard: this is the one
    /// baseline that actually models the interaction-advance path, so it is the only one that
    /// overrides the protocol's `false` default.
    public let advancesOnInteraction = true

    private static let recentInteractionThreshold: TimeInterval = 5 * 60
    private static let warmThreshold: TimeInterval = 60 * 60
    private static let idleThreshold: TimeInterval = 4 * 60 * 60

    private static let recentInteractionDelay: TimeInterval = 2 * 60
    private static let warmDelay: TimeInterval = 5 * 60
    private static let idleDelay: TimeInterval = 15 * 60
    private static let longIdleDelay: TimeInterval = 30 * 60
    private static let constrainedDelay: TimeInterval = 30 * 60

    public init() {}

    public func decide(_ input: ReplayPolicyInput) -> ReplayPolicyDecision {
        if input.isConstrained {
            return ReplayPolicyDecision(delaySeconds: Self.constrainedDelay, reason: "constrained")
        }

        guard let lastMenuOpenAt = input.lastMenuOpenAt else {
            return ReplayPolicyDecision(delaySeconds: Self.longIdleDelay, reason: "longIdle")
        }

        let age = input.now.timeIntervalSince(lastMenuOpenAt)

        if age <= Self.recentInteractionThreshold {
            return ReplayPolicyDecision(delaySeconds: Self.recentInteractionDelay, reason: "recentInteraction")
        }
        if age <= Self.warmThreshold {
            return ReplayPolicyDecision(delaySeconds: Self.warmDelay, reason: "warm")
        }
        if age < Self.idleThreshold {
            return ReplayPolicyDecision(delaySeconds: Self.idleDelay, reason: "idle")
        }
        return ReplayPolicyDecision(delaySeconds: Self.longIdleDelay, reason: "longIdle")
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
        self.intervalSeconds = TimeInterval(minutes * 60)
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
