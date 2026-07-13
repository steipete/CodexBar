import Foundation

/// Historical menu-only adaptive policy retained as a replay baseline after coding activity moved
/// into the production policy. It calls the same canonical core with that one signal omitted.
public struct MenuOnlyAdaptivePolicy: ReplayPolicy, Sendable {
    public let name = "adaptive-menu-only"
    public let advancesOnInteraction = true

    private let base = AdaptiveReplayPolicy()

    public init() {}

    public func decide(_ input: ReplayPolicyInput) -> ReplayPolicyDecision {
        self.base.decide(input, lastCodingActivityAt: nil)
    }
}
