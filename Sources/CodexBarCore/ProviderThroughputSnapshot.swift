import Foundation

/// Compact, cached throughput shared by provider cards, status items, and widgets.
public struct ProviderThroughputSnapshot: Codable, Sendable, Equatable {
    public struct Minute: Codable, Sendable, Equatable {
        public let start: Date
        public let totalTokens: Int
        public let requests: Int
        public let isPending: Bool
    }

    public struct Model: Codable, Sendable, Equatable {
        public let name: String
        public let latestTPM: Int
        public let peakTPM: Int
        public let totalTokens: Int
        public let peakLimitCountedTokens: Int
        /// Aligned with snapshot minutes; pending values are retained but excluded from limit utilization.
        public let limitCountedTokensByMinute: [Int]?

        init(
            name: String,
            latestTPM: Int,
            peakTPM: Int,
            totalTokens: Int,
            peakLimitCountedTokens: Int,
            limitCountedTokensByMinute: [Int]? = nil)
        {
            self.name = name
            self.latestTPM = latestTPM
            self.peakTPM = peakTPM
            self.totalTokens = totalTokens
            self.peakLimitCountedTokens = peakLimitCountedTokens
            self.limitCountedTokensByMinute = limitCountedTokensByMinute
        }
    }

    public let minutes: [Minute]
    public let frontier: Date?
    public let latestTokensPerMinute: Int?
    public let peakTokensPerMinute: Int
    public let peakAt: Date?
    public let fiveMinuteAverageTokensPerMinute: Double
    public let models: [Model]
    public let windowMinutes: Int
    public let fetchedAt: Date
    /// Project the traffic is filtered to; nil when it covers the whole account or organization.
    public let projectID: String?
}
