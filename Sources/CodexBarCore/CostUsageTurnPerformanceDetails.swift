import Foundation

/// Observations of completed turns, not a controlled comparison of model generation speed.
public struct CostUsageTurnPerformanceDetails: Sendable, Equatable {
    public let p95DurationMilliseconds: Double?
    public let p95FirstTokenMilliseconds: Double?
    public let outputRateLowerQuartile: Double?
    public let outputRateUpperQuartile: Double?
    public let cachedInputFraction: Double?
    public let cacheSampleCount: Int
    public let groups: [Group]

    public struct Group: Sendable, Equatable {
        public let model: String?
        public let reasoningEffort: String?
        public let sampleCount: Int
        public let firstTokenSampleCount: Int
        public let medianFirstTokenMilliseconds: Double?
        public let medianDurationMilliseconds: Double
        public let outputTokensPerSecond: Double
    }

    private struct Key: Hashable {
        let model: String?
        let effort: String?
    }

    public init(samples: [CostUsageTurnPerformanceSample]) {
        self.p95DurationMilliseconds = Self.percentile(
            samples.map { Double($0.durationMilliseconds) }, fraction: 0.95, minimumCount: 20)
        self.p95FirstTokenMilliseconds = Self.percentile(
            samples.compactMap { $0.firstTokenMilliseconds.map(Double.init) }, fraction: 0.95, minimumCount: 20)
        let rates = samples.map { Double($0.outputTokens) / Double($0.durationMilliseconds) * 1000 }
        self.outputRateLowerQuartile = Self.percentile(rates, fraction: 0.25, minimumCount: 4)
        self.outputRateUpperQuartile = Self.percentile(rates, fraction: 0.75, minimumCount: 4)
        let cacheSamples = samples.filter { $0.inputTokens != nil && $0.cachedInputTokens != nil }
        self.cacheSampleCount = cacheSamples.count
        if let input = CheckedSum.integers(cacheSamples.compactMap(\.inputTokens)), input > 0,
           let cached = CheckedSum.integers(cacheSamples.compactMap(\.cachedInputTokens))
        {
            self.cachedInputFraction = Double(cached) / Double(input)
        } else {
            self.cachedInputFraction = nil
        }
        self.groups = Dictionary(grouping: samples) { Key(model: $0.model, effort: $0.reasoningEffort) }
            .compactMap { key, observations in
                guard let output = CheckedSum.integers(observations.map(\.outputTokens)),
                      let duration = CheckedSum.integers(observations.map(\.durationMilliseconds)), duration > 0
                else { return nil }
                let firstTokens = observations.compactMap { $0.firstTokenMilliseconds.map(Double.init) }
                return Group(
                    model: key.model,
                    reasoningEffort: key.effort,
                    sampleCount: observations.count,
                    firstTokenSampleCount: firstTokens.count,
                    medianFirstTokenMilliseconds: Self.median(firstTokens),
                    medianDurationMilliseconds: Self.median(observations.map { Double($0.durationMilliseconds) }) ?? 0,
                    outputTokensPerSecond: Double(output) / Double(duration) * 1000)
            }.sorted {
                if $0.model != $1.model { return ($0.model ?? "") < ($1.model ?? "") }
                return ($0.reasoningEffort ?? "") < ($1.reasoningEffort ?? "")
            }
    }

    /// Nearest-rank percentiles. P95 requires 20 observations; quartiles require four.
    private static func percentile(_ values: [Double], fraction: Double, minimumCount: Int) -> Double? {
        guard values.count >= minimumCount else { return nil }
        let sorted = values.sorted()
        return sorted[Int(ceil(Double(sorted.count) * fraction)) - 1]
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
    }
}
