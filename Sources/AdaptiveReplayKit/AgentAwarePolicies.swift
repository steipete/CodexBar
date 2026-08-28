import AdaptiveRefreshCore
import Foundation

/// Agent-aware Adaptive replay policy. Activity remains a distinct opt-in input projection even
/// though both adaptive modes share the canonical decision table.
public struct AgentAwareAdaptiveReplayPolicy: ReplayPolicy, Sendable {
    public let name = "adaptive-activity"
    public let advancesOnInteraction = true

    public init() {}

    public func decide(_ input: ReplayPolicyInput) -> ReplayPolicyDecision {
        let decision = AdaptiveRefreshPolicyCore().nextDelay(for: AdaptiveRefreshPolicyCore.Input(
            now: input.now,
            lastMenuOpenAt: input.lastMenuOpenAt,
            lastCodingActivityAt: input.lastCodingActivityAt,
            lowPowerModeEnabled: input.lowPowerModeEnabled,
            thermalPressure: input.thermalState.isConstrained ? .constrained : .nominal))
        return ReplayPolicyDecision(
            delaySeconds: TimeInterval(decision.delay.components.seconds),
            reason: decision.reason.rawValue)
    }
}
