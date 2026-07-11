import Foundation

/// Replay-only candidate used to test whether stat-only coding activity can close the accepted
/// "active work is never slower than five minutes" gap. It is not a production policy approval.
public struct CodingActivityAdaptivePolicy: ReplayPolicy, Sendable {
    public let name = "adaptive-activity"
    public let advancesOnInteraction = true

    private let base = AdaptiveReplayPolicy()
    private static let activeThreshold: TimeInterval = 5 * 60
    private static let activeDelayCap: TimeInterval = 5 * 60

    public init() {}

    public func decide(_ input: ReplayPolicyInput) -> ReplayPolicyDecision {
        let baseDecision = self.base.decide(input)
        guard !input.isConstrained,
              let activityAge = input.codingActivityAgeSeconds,
              activityAge < Self.activeThreshold,
              let baseDelay = baseDecision.delaySeconds,
              baseDelay > Self.activeDelayCap
        else {
            return baseDecision
        }
        return ReplayPolicyDecision(delaySeconds: Self.activeDelayCap, reason: "codingActivity")
    }
}
