import Foundation

/// Effective usage snapshot for Cursor plans with tier-aware budget calculations.
/// This provides accurate usage percentages for higher-tier plans (Pro+, Ultra)
/// that have effective budgets much larger than their nominal prices.
public struct CursorEffectiveUsage: Codable, Sendable {
    /// Total usage (plan + on-demand) in USD
    public let totalUsedUSD: Double
    /// Effective budget (tier budget + on-demand limit) in USD
    public let effectiveBudgetUSD: Double
    /// Plan tier for display purposes
    public let planTier: CursorPlanTier
    /// Whether on-demand usage has started (plan allowance exhausted)
    public let isPlanExhausted: Bool
    /// On-demand usage in USD (for separate display when plan is exhausted)
    public let onDemandUsedUSD: Double
    /// On-demand limit in USD (nil if unlimited)
    public let onDemandLimitUSD: Double?

    public init(
        totalUsedUSD: Double,
        effectiveBudgetUSD: Double,
        planTier: CursorPlanTier,
        isPlanExhausted: Bool,
        onDemandUsedUSD: Double,
        onDemandLimitUSD: Double?)
    {
        self.totalUsedUSD = totalUsedUSD
        self.effectiveBudgetUSD = effectiveBudgetUSD
        self.planTier = planTier
        self.isPlanExhausted = isPlanExhausted
        self.onDemandUsedUSD = onDemandUsedUSD
        self.onDemandLimitUSD = onDemandLimitUSD
    }

    /// Effective percentage used based on total usage / effective budget
    public var effectivePercentUsed: Double {
        guard self.effectiveBudgetUSD > 0 else { return 0 }
        return min((self.totalUsedUSD / self.effectiveBudgetUSD) * 100, 100)
    }
}
