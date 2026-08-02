import Foundation

/// Transient presentation rules for a raw local-usage snapshot.
///
/// The index persists only source-derived counters and cost coverage. Settings
/// such as cache inclusion and cost visibility are deliberately applied here,
/// so changing them never requires a corpus scan or sidecar rewrite.
public struct CodexLocalProjectUsageProjection: Sendable, Equatable {
    public let includesCachedInput: Bool
    public let showsEstimatedCost: Bool

    public init(includesCachedInput: Bool, showsEstimatedCost: Bool) {
        self.includesCachedInput = includesCachedInput
        self.showsEstimatedCost = showsEstimatedCost
    }

    public func displayedTokens(for totals: CodexLocalUsageTotals) -> Int? {
        guard let total = totals.totalTokens else { return nil }
        return self.displayedTokens(totalTokens: total, cachedInputTokens: totals.cachedInputTokens)
    }

    public func displayedTokens(totalTokens: Int, cachedInputTokens: Int?) -> Int {
        guard !self.includesCachedInput else { return max(0, totalTokens) }
        return max(0, totalTokens - (cachedInputTokens ?? 0))
    }

    public func rankedProjects(_ projects: [CodexLocalProjectUsage]) -> [CodexLocalProjectUsage] {
        let severities = self.severities(for: projects)
        return projects.sorted { lhs, rhs in
            let lhsTokens = self.displayedTokens(for: lhs.totals) ?? -1
            let rhsTokens = self.displayedTokens(for: rhs.totals) ?? -1
            if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }

            let lhsCost = lhs.costEstimate.knownUSD
            let rhsCost = rhs.costEstimate.knownUSD
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            if lhs.sessionCount != rhs.sessionCount { return lhs.sessionCount > rhs.sessionCount }
            if lhs.latestActivity != rhs.latestActivity {
                return (lhs.latestActivity ?? .distantPast) > (rhs.latestActivity ?? .distantPast)
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }.map { project in
            project.withDisplaySeverity(severities[project.id] ?? .normal)
        }
    }

    public func displayedCost(for estimate: CodexLocalCostEstimate) -> CodexLocalCostEstimate? {
        self.showsEstimatedCost ? estimate : nil
    }

    private func severities(for projects: [CodexLocalProjectUsage]) -> [String: CodexLocalUsageSeverity] {
        let nonZero = projects.compactMap { self.displayedTokens(for: $0.totals) }.filter { $0 > 0 }.sorted()
        let total = nonZero.reduce(0, +)
        let median = self.percentile(nonZero, percentile: 0.5)
        let p90 = self.percentile(nonZero, percentile: 0.9)
        let outlierThreshold = max(p90, median * 5)
        let maximum = nonZero.last ?? 0

        return Dictionary(uniqueKeysWithValues: projects.map { project in
            let tokens = self.displayedTokens(for: project.totals) ?? 0
            let severity: CodexLocalUsageSeverity = if tokens > 0, total > 0,
                                                       Double(tokens) >= Double(total) * 0.5 ||
                                                       (tokens == maximum && tokens > outlierThreshold)
            {
                .high
            } else if tokens > 0, median > 0, tokens >= median * 2 {
                .elevated
            } else {
                .normal
            }
            return (project.id, severity)
        })
    }

    private func percentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let index = Int((Double(values.count - 1) * percentile).rounded(.up))
        return values[min(max(index, 0), values.count - 1)]
    }
}

extension CodexLocalProjectUsage {
    fileprivate func withDisplaySeverity(_ severity: CodexLocalUsageSeverity) -> Self {
        CodexLocalProjectUsage(
            id: self.id,
            displayName: self.displayName,
            path: self.path,
            totals: self.totals,
            costEstimate: self.costEstimate,
            sessionCount: self.sessionCount,
            latestActivity: self.latestActivity,
            topModel: self.topModel,
            topSessions: self.topSessions,
            modelBreakdowns: self.modelBreakdowns,
            daily: self.daily,
            usageSeverity: severity)
    }
}
