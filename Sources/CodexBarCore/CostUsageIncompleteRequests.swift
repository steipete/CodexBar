package enum CostUsageIncompleteRequests {
    /// Reject malformed persisted counts at decode boundaries. Saturate combined reports so
    /// overflow cannot erase the incomplete marker or crash a consumer.
    package static func sum(_ counts: some Sequence<Int>) -> Int {
        CheckedSum.integers(counts.map { max(0, $0) }) ?? Int.max
    }
}
