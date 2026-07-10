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

    init?(samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        self.init(
            mean: sorted.reduce(0, +) / Double(sorted.count),
            median: Self.percentile(sorted, fraction: 0.5),
            p95: Self.percentile(sorted, fraction: 0.95),
            sampleCount: sorted.count)
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
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
    /// Unconstrained replayed decisions with a known transcript-write observation under five minutes old.
    public let codingActiveDecisionCount: Int
    /// Unconstrained active decisions whose selected delay exceeded the five-minute acceptance cap.
    public let codingActiveDelayViolationCount: Int
    /// Number of independently simulated awake/run segments contributing to these metrics.
    public let segmentCount: Int
    /// Wall-clock time excluded after an expected timer deadline because the app was unobserved.
    public let excludedGapSeconds: TimeInterval
    /// Menu opens before a segment's first recorded refresh, excluded equally for every policy.
    public let boundaryCensoredMenuOpenCount: Int

    public init(
        policyName: String,
        simulatedSpanSeconds: TimeInterval,
        totalRefreshCount: Int,
        refreshCountPer24h: Double,
        stalenessAtMenuOpen: StalenessStats?,
        constrainedCompliance: ConstrainedCompliance,
        interactionAdvanceCount: Int = 0,
        codingActiveDecisionCount: Int = 0,
        codingActiveDelayViolationCount: Int = 0,
        segmentCount: Int = 1,
        excludedGapSeconds: TimeInterval = 0,
        boundaryCensoredMenuOpenCount: Int = 0)
    {
        self.policyName = policyName
        self.simulatedSpanSeconds = simulatedSpanSeconds
        self.totalRefreshCount = totalRefreshCount
        self.refreshCountPer24h = refreshCountPer24h
        self.stalenessAtMenuOpen = stalenessAtMenuOpen
        self.constrainedCompliance = constrainedCompliance
        self.interactionAdvanceCount = interactionAdvanceCount
        self.codingActiveDecisionCount = codingActiveDecisionCount
        self.codingActiveDelayViolationCount = codingActiveDelayViolationCount
        self.segmentCount = segmentCount
        self.excludedGapSeconds = excludedGapSeconds
        self.boundaryCensoredMenuOpenCount = boundaryCensoredMenuOpenCount
    }
}

struct ReplayRun: Sendable {
    let metrics: ReplayMetrics
    let stalenessSamples: [Double]
}
