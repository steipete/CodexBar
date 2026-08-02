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

    /// Returns an inspector-only view of Models analytics. The persisted snapshot stays raw so toggling
    /// cached input remains a pure display choice and never causes an index write or refresh.
    public func projectedModelsAnalyticsSnapshot(
        _ snapshot: CodexModelsAnalyticsSnapshot,
        dailyUsage: [CodexLocalUsageDailyPoint]) -> CodexModelsAnalyticsSnapshot
    {
        guard !self.includesCachedInput else { return snapshot }

        var cachedByDay: [String: Int64] = [:]
        for point in dailyUsage {
            cachedByDay[point.day, default: 0] += Int64(max(0, point.cachedInputTokens ?? 0))
        }

        let daily = snapshot.daily.map { bucket in
            let cached = min(max(0, cachedByDay[CostUsageLocalDay.key(from: bucket.day)] ?? 0), bucket.tokens)
            return CodexModelsDailyBucket(
                day: bucket.day,
                interval: bucket.interval,
                tokens: max(0, bucket.tokens - cached),
                sessionIDs: bucket.sessionIDs,
                sessionReferenceIDs: bucket.sessionReferenceIDs,
                cost: bucket.cost)
        }
        let totalTokens = daily.isEmpty
            ? snapshot.rows.reduce(Int64.zero) { $0 + max(0, $1.totalTokens - $1.cachedInputTokens) }
            : daily.reduce(Int64.zero) { $0 + $1.tokens }

        // The snapshot has exact cached totals by day and model, but not their intersection. Allocate each
        // day's exact exclusion across existing model buckets in stable model-ID order without taking more
        // than that model's known cached total.
        var excludedByModelBucket: [String: [Int: Int64]] = [:]
        var remainingCachedByModel = Dictionary(uniqueKeysWithValues: snapshot.rows.map { row in
            (row.id, max(0, row.cachedInputTokens))
        })
        for (day, cached) in cachedByDay where cached > 0 {
            var remaining = cached
            var candidates: [(modelID: String, index: Int, bucket: CodexModelsDailyBucket)] = []
            for (modelID, buckets) in snapshot.dailyByModel {
                for (index, bucket) in buckets.enumerated() where CostUsageLocalDay.key(from: bucket.day) == day {
                    candidates.append((modelID, index, bucket))
                }
            }
            candidates.sort { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            for (modelID, index, bucket) in candidates where remaining > 0 {
                let excluded = min(
                    remaining,
                    min(max(0, bucket.tokens), remainingCachedByModel[modelID, default: 0]))
                excludedByModelBucket[modelID, default: [:]][index] = excluded
                remaining -= excluded
                remainingCachedByModel[modelID, default: 0] -= excluded
            }
        }
        let dailyByModel = Dictionary(uniqueKeysWithValues: snapshot.dailyByModel.map { modelID, buckets in
            let projected = buckets.enumerated().map { index, bucket in
                let excluded = excludedByModelBucket[modelID]?[index] ?? 0
                return CodexModelsDailyBucket(
                    day: bucket.day,
                    interval: bucket.interval,
                    tokens: max(0, bucket.tokens - excluded),
                    sessionIDs: bucket.sessionIDs,
                    sessionReferenceIDs: bucket.sessionReferenceIDs,
                    cost: bucket.cost)
            }
            return (modelID, projected)
        })
        let rows = snapshot.rows.map { row in
            let cached = min(max(0, row.cachedInputTokens), max(0, row.totalTokens))
            let tokens = max(0, row.totalTokens - cached)
            return CodexModelsRow(
                id: row.id,
                displayName: row.displayName,
                rawAliases: row.rawAliases,
                inputTokens: max(0, row.inputTokens - cached),
                cachedInputTokens: 0,
                outputTokens: row.outputTokens,
                reasoningTokens: row.reasoningTokens,
                totalTokens: tokens,
                share: totalTokens == 0 ? 0 : Double(tokens) / Double(totalTokens),
                sessionReferences: row.sessionReferences,
                cost: row.cost,
                previousTotalTokens: nil,
                previousCost: row.previousCost,
                previousSessionReferences: row.previousSessionReferences,
                associatedSessionIDs: row.associatedSessionIDs,
                tokenComparison: .unavailable,
                costComparison: row.costComparison,
                sessionReferenceComparison: row.sessionReferenceComparison)
        }

        return CodexModelsAnalyticsSnapshot(
            scopeID: snapshot.scopeID,
            generatedAt: snapshot.generatedAt,
            indexRevision: snapshot.indexRevision,
            currentInterval: snapshot.currentInterval,
            previousInterval: snapshot.previousInterval,
            currentIsComplete: snapshot.currentIsComplete,
            previousIsComplete: snapshot.previousIsComplete,
            totalTokens: totalTokens,
            cost: snapshot.cost,
            activeModelCount: snapshot.activeModelCount,
            previousActiveModelCount: snapshot.previousActiveModelCount,
            newlyActiveModelCount: snapshot.newlyActiveModelCount,
            uniqueSessionCount: snapshot.uniqueSessionCount,
            sessionReferenceTotal: snapshot.sessionReferenceTotal,
            previousSessionReferenceTotal: snapshot.previousSessionReferenceTotal,
            tokenComparison: .unavailable,
            costComparison: snapshot.costComparison,
            sessionReferenceComparison: snapshot.sessionReferenceComparison,
            rows: rows,
            daily: daily,
            dailyByModel: dailyByModel,
            diagnostics: snapshot.diagnostics)
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
