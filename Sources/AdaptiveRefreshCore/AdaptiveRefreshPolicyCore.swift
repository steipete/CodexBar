import Foundation

/// Canonical adaptive-refresh decision table shared by the app and offline replay tooling.
/// Platform adapters normalize their thermal signals before calling this type; thresholds and
/// delays live here only.
package struct AdaptiveRefreshPolicyCore: Sendable {
    package struct Input: Sendable, Equatable {
        package let now: Date
        package let lastMenuOpenAt: Date?
        package let lastCodingActivityAt: Date?
        package let lowPowerModeEnabled: Bool
        package let thermalPressure: ThermalPressure

        package init(
            now: Date,
            lastMenuOpenAt: Date?,
            lastCodingActivityAt: Date? = nil,
            lowPowerModeEnabled: Bool,
            thermalPressure: ThermalPressure)
        {
            self.now = now
            self.lastMenuOpenAt = lastMenuOpenAt
            self.lastCodingActivityAt = lastCodingActivityAt
            self.lowPowerModeEnabled = lowPowerModeEnabled
            self.thermalPressure = thermalPressure
        }
    }

    package enum ThermalPressure: Sendable, Equatable {
        case nominal
        case constrained
    }

    package enum Reason: String, Sendable, Equatable {
        case recentInteraction
        case codingActivity
        case warm
        case idle
        case longIdle
        case constrained
    }

    package struct Decision: Sendable, Equatable {
        package let delay: Duration
        package let reason: Reason

        fileprivate init(delay: Duration, reason: Reason) {
            self.delay = delay
            self.reason = reason
        }
    }

    private static let recentInteractionThreshold: TimeInterval = 5 * 60
    private static let warmThreshold: TimeInterval = 60 * 60
    private static let idleThreshold: TimeInterval = 4 * 60 * 60
    private static let codingActivityThreshold: TimeInterval = 5 * 60

    private static let recentInteractionDelay: Duration = .seconds(2 * 60)
    private static let warmDelay: Duration = .seconds(5 * 60)
    private static let idleDelay: Duration = .seconds(15 * 60)
    private static let longIdleDelay: Duration = .seconds(30 * 60)
    private static let constrainedDelay: Duration = .seconds(30 * 60)
    private static let codingActivityDelayCap: Duration = .seconds(5 * 60)

    /// Representative cadence for consumers that need one interval but cannot access live state.
    package static let nominalIntervalForHeuristics: TimeInterval = 5 * 60

    package init() {}

    package func nextDelay(for input: Input) -> Decision {
        if input.lowPowerModeEnabled || input.thermalPressure == .constrained {
            return Decision(delay: Self.constrainedDelay, reason: .constrained)
        }

        let baseDecision = self.menuActivityDecision(for: input)
        guard let lastCodingActivityAt = input.lastCodingActivityAt,
              input.now.timeIntervalSince(lastCodingActivityAt) < Self.codingActivityThreshold,
              baseDecision.delay > Self.codingActivityDelayCap
        else { return baseDecision }

        return Decision(delay: Self.codingActivityDelayCap, reason: .codingActivity)
    }

    private func menuActivityDecision(for input: Input) -> Decision {
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
}
