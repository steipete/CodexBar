/// A provider-reported usage percentage before and after display normalization.
///
/// Keep `raw` when over-quota values carry meaning for provider-specific details or pace diagnostics.
/// Use `displayClamped` when projecting a percentage into a headline or `RateWindow` display value.
/// `RateWindow` itself intentionally remains raw-capable so callers must choose the appropriate contract.
public struct UsagePercent: Equatable, Sendable {
    public let raw: Double

    public init(raw: Double) {
        self.raw = raw
    }

    /// Computes an unbounded percentage from a numeric quota ratio.
    ///
    /// Callers must resolve the provider-specific fallback for a missing or non-positive limit first.
    public init(used: Double, limit: Double) {
        precondition(limit > 0, "Usage percent requires a positive limit")
        self.raw = (used / limit) * 100
    }

    public var displayClamped: Double {
        self.raw.clamped(to: 0...100)
    }
}
