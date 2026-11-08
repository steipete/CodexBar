import Foundation

extension PiSessionCostScanner {
    /// Per-session and per-project rows for the Pi report. Each row is rebuilt from deduped session
    /// contributions with the same merge and range filter as the total, so rows partition it.
    static func breakdowns(
        cache: PiSessionCostCache,
        range: CostUsageScanner.CostUsageDayRange)
        -> (projects: [CostUsageProjectBreakdown], sessions: [CostUsageSessionBreakdown])?
    {
        var sessions: [CostUsageSessionBreakdown] = []
        var projectContributions: [String: [String: [String: [String: PiPackedUsage]]]] = [:]
        var projectIdentities: [String: (name: String?, path: String?)] = [:]
        for (sessionKey, session) in cache.sessions {
            guard let report = self.piReport(contributions: session.contributions, range: range) else { return nil }
            guard !report.data.isEmpty else { continue }
            let identity = self.projectIdentity(session)
            sessions.append(self.sessionBreakdown(
                sessionID: sessionKey,
                session: session,
                report: report,
                projectName: identity.name))
            let projectKey = session.projectPath ?? session.projectSlug.map { "slug:\($0)" } ?? ""
            projectIdentities[projectKey] = identity
            guard self.applyContributions(
                daysByProvider: &projectContributions[projectKey, default: [:]],
                contributions: session.contributions)
            else { return nil }
        }

        var projects: [CostUsageProjectBreakdown] = []
        for (projectKey, contributions) in projectContributions {
            guard let report = self.piReport(contributions: contributions, range: range),
                  let identity = projectIdentities[projectKey]
            else { return nil }
            let summaries = CostUsageDailyReport.modelCostSummaries(from: report.data)
            projects.append(CostUsageProjectBreakdown(
                name: identity.name ?? CostUsageProjectBreakdown.unknownProjectName,
                path: identity.path,
                totalTokens: report.summary?.totalTokens,
                totalCostUSD: report.summary?.totalCostUSD,
                daily: report.data,
                modelBreakdowns: summaries.isEmpty ? nil : CostUsageDailyReport.sortedModelBreakdowns(summaries)))
        }
        // Same ordering as Codex: projects by spend, sessions by recency.
        projects.sort { lhs, rhs in
            let lhsRank = (lhs.totalCostUSD ?? -1, lhs.totalTokens ?? -1)
            let rhsRank = (rhs.totalCostUSD ?? -1, rhs.totalTokens ?? -1)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        sessions.sort { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID > rhs.sessionID
        }
        return (projects, sessions)
    }

    /// Pi stores sessions under `--<encoded cwd>--` folders. The slug is a display name only:
    /// dashes inside folder names make decoding it back to a path lossy.
    static func piProjectSlug(fileURL: URL) -> String? {
        let folder = fileURL.deletingLastPathComponent().lastPathComponent
        guard folder.count > 4, folder.hasPrefix("--"), folder.hasSuffix("--") else { return nil }
        return folder
    }

    private static func piReport(
        contributions: [String: [String: [String: PiPackedUsage]]],
        range: CostUsageScanner.CostUsageDayRange) -> CostUsageDailyReport?
    {
        var scratch = PiSessionCostCache()
        scratch.daysByProvider = contributions
        return self.checkedReports(cache: scratch, range: range)?.pi
    }

    /// A nil name is the Unknown project.
    private static func projectIdentity(_ session: PiSessionUsage) -> (name: String?, path: String?) {
        if let path = session.projectPath {
            let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
            return (name.isEmpty ? path : name, path)
        }
        return (session.projectSlug.map { String($0.dropFirst(2).dropLast(2)) }, nil)
    }

    private static func sessionBreakdown(
        sessionID: String,
        session: PiSessionUsage,
        report: CostUsageDailyReport,
        projectName: String?) -> CostUsageSessionBreakdown
    {
        let summary = report.summary
        let inputParts = [summary?.totalInputTokens, summary?.cacheReadTokens, summary?.cacheCreationTokens]
            .compactMap(\.self)
        let requestCounts = report.data.compactMap(\.requestCount)
        let summaries = CostUsageDailyReport.modelCostSummaries(from: report.data)
        return CostUsageSessionBreakdown(
            sessionID: sessionID,
            lastActivity: Date(timeIntervalSince1970: TimeInterval(session.lastActivityUnixMs) / 1000),
            // Pi records input, cache reads and cache writes as disjoint counts; sessions report input inclusively.
            inputTokens: inputParts.isEmpty ? nil : CheckedSum.integers(inputParts),
            cachedInputTokens: summary?.cacheReadTokens,
            outputTokens: summary?.totalOutputTokens,
            totalTokens: summary?.totalTokens,
            requestCount: requestCounts.isEmpty ? nil : CheckedSum.integers(requestCounts),
            costUSD: summary?.totalCostUSD,
            modelBreakdowns: CostUsageDailyReport.sortedModelBreakdowns(summaries),
            projectPath: session.projectPath,
            projectName: projectName,
            title: session.title)
    }
}
