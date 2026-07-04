import Foundation

/// Mean/median/p95 of staleness (seconds since the last simulated refresh) observed at each
/// historical menu-open event. `p95` uses nearest-rank: samples are sorted ascending and index
/// `ceil(0.95 * n) - 1` (clamped to the last index) is reported — the same convention most
/// dashboards use for small-to-medium sample counts, and simple enough to hand-verify in tests.
public struct StalenessStats: Sendable, Equatable {
    public let mean: Double
    public let median: Double
    public let p95: Double
    public let sampleCount: Int

    public init(mean: Double, median: Double, p95: Double, sampleCount: Int) {
        self.mean = mean
        self.median = median
        self.p95 = p95
        self.sampleCount = sampleCount
    }
}

/// Whether a policy honored the "never refresh faster than 30 minutes while constrained (low
/// power or serious/critical thermal)" rule at every simulated decision point where the input was
/// constrained.
public struct ConstrainedCompliance: Sendable, Equatable {
    public let constrainedDecisionCount: Int
    public let violationCount: Int

    public init(constrainedDecisionCount: Int, violationCount: Int) {
        self.constrainedDecisionCount = constrainedDecisionCount
        self.violationCount = violationCount
    }

    public var isCompliant: Bool {
        self.violationCount == 0
    }
}

public struct ReplayMetrics: Sendable, Equatable {
    public let policyName: String
    public let simulatedSpanSeconds: TimeInterval
    public let totalRefreshCount: Int
    public let refreshCountPer24h: Double
    public let stalenessAtMenuOpen: StalenessStats?
    public let constrainedCompliance: ConstrainedCompliance
    /// How many of `totalRefreshCount` were pulled forward by a menu-open interaction rather than
    /// firing on the policy's own previously scheduled cadence — i.e. how many times
    /// `ReplayEngine.run` took the `advancesOnInteraction` branch for this policy. Always `0` for
    /// policies that report `advancesOnInteraction == false` (see `ReplayPolicy`).
    public let interactionAdvanceCount: Int

    public init(
        policyName: String,
        simulatedSpanSeconds: TimeInterval,
        totalRefreshCount: Int,
        refreshCountPer24h: Double,
        stalenessAtMenuOpen: StalenessStats?,
        constrainedCompliance: ConstrainedCompliance,
        interactionAdvanceCount: Int = 0)
    {
        self.policyName = policyName
        self.simulatedSpanSeconds = simulatedSpanSeconds
        self.totalRefreshCount = totalRefreshCount
        self.refreshCountPer24h = refreshCountPer24h
        self.stalenessAtMenuOpen = stalenessAtMenuOpen
        self.constrainedCompliance = constrainedCompliance
        self.interactionAdvanceCount = interactionAdvanceCount
    }
}
