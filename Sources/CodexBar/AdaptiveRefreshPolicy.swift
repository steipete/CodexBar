import Foundation

/// Decides how long to wait before the next automatic usage refresh.
/// Pure by construction: every signal arrives via `Input`, so the same
/// input always yields the same `Decision` with no clock or system reads.
struct AdaptiveRefreshPolicy: Sendable {
    struct Input: Sendable, Equatable {
        let now: Date
        let lastMenuOpenAt: Date?
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
    }

    enum Reason: String, Sendable {
        case recentInteraction
        case warm
        case idle
        case longIdle
        case constrained
    }

    struct Decision: Sendable, Equatable {
        let delay: Duration
        let reason: Reason
    }

    private static let recentInteractionThreshold: TimeInterval = 5 * 60
    private static let warmThreshold: TimeInterval = 60 * 60
    private static let idleThreshold: TimeInterval = 4 * 60 * 60

    /// Representative cadence for consumers that need a single interval but cannot reach live
    /// signals (`ProviderRegistry` builds provider specs before a `UsageStore` exists). Matches
    /// `warmDelay`: the steady-state cadence while the user is active, which is when
    /// interval-derived heuristics such as the persistent-CLI-session idle window matter most.
    static let nominalIntervalForHeuristics: TimeInterval = 5 * 60

    private static let recentInteractionDelay: Duration = .seconds(2 * 60)
    private static let warmDelay: Duration = .seconds(5 * 60)
    private static let idleDelay: Duration = .seconds(15 * 60)
    private static let longIdleDelay: Duration = .seconds(30 * 60)
    private static let constrainedDelay: Duration = .seconds(30 * 60)

    func nextDelay(for input: Input) -> Decision {
        if input.lowPowerModeEnabled || Self.isConstrained(input.thermalState) {
            return Decision(delay: Self.constrainedDelay, reason: .constrained)
        }

        guard let lastMenuOpenAt = input.lastMenuOpenAt else {
            return Decision(delay: Self.longIdleDelay, reason: .longIdle)
        }

        // A future or clock-adjusted timestamp yields a negative age, which reads as recent.
        let age = input.now.timeIntervalSince(lastMenuOpenAt)

        if age <= Self.recentInteractionThreshold {
            return Decision(delay: Self.recentInteractionDelay, reason: .recentInteraction)
        }
        if age <= Self.warmThreshold {
            return Decision(delay: Self.warmDelay, reason: .warm)
        }
        if age < Self.idleThreshold {
            return Decision(delay: Self.idleDelay, reason: .idle)
        }
        return Decision(delay: Self.longIdleDelay, reason: .longIdle)
    }

    private static func isConstrained(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }
}
