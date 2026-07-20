import AdaptiveRefreshCore
import Foundation

/// Decides how long to wait before the next automatic usage refresh.
/// Pure by construction: every signal arrives via `Input`, so the same
/// input always yields the same `Decision` with no clock or system reads.
struct AdaptiveRefreshPolicy: Sendable {
    struct Input: Sendable, Equatable {
        let now: Date
        let lastMenuOpenAt: Date?
        let lastCodingActivityAt: Date?
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
    }

    typealias Reason = AdaptiveRefreshPolicyCore.Reason
    typealias Decision = AdaptiveRefreshPolicyCore.Decision

    /// Representative cadence for consumers that need a single interval but cannot reach live
    /// signals (`ProviderRegistry` builds provider specs before a `UsageStore` exists). Matches
    /// `warmDelay`: the steady-state cadence while the user is active, which is when
    /// interval-derived heuristics such as the persistent-CLI-session idle window matter most.
    static let nominalIntervalForHeuristics = AdaptiveRefreshPolicyCore.nominalIntervalForHeuristics

    func nextDelay(for input: Input) -> Decision {
        AdaptiveRefreshPolicyCore().nextDelay(for: AdaptiveRefreshPolicyCore.Input(
            now: input.now,
            lastMenuOpenAt: input.lastMenuOpenAt,
            lastCodingActivityAt: input.lastCodingActivityAt,
            lowPowerModeEnabled: input.lowPowerModeEnabled,
            thermalPressure: Self.isConstrained(input.thermalState) ? .constrained : .nominal))
    }

    private static func isConstrained(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }
}
