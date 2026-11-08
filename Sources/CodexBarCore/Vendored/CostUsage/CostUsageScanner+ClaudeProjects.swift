import Foundation

struct ClaudeReportBreakdowns: Sendable {
    let projects: [CostUsageProjectBreakdown]
    let sessions: [CostUsageSessionBreakdown]
}

/// First cwd per session key in one transcript; a reference so the line scanner can fill it in place.
final class ClaudeSessionProjectPaths {
    var bySession: [String: String]

    init(_ bySession: [String: String]) {
        self.bySession = bySession
    }
}

struct ClaudeReportProjections: Sendable {
    let daily: CostUsageDailyReport
    let projects: [CostUsageProjectBreakdown]
    let sessions: [CostUsageSessionBreakdown]

    init(daily: CostUsageDailyReport, breakdowns: ClaudeReportBreakdowns?) {
        self.daily = daily
        self.projects = breakdowns?.projects ?? []
        self.sessions = breakdowns?.sessions ?? []
    }
}

/// Persisted with the report memo, so an unchanged relaunch does not decode the transcript cache.
extension ClaudeReportBreakdowns: Codable {
    private struct Session: Codable {
        let id: String
        let lastActivity: Date
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
        let requestCount: Int?
        let costUSD: Double?
        let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]
        let projectPath: String?
        let projectName: String?
    }

    private struct Project: Codable {
        let name: String
        let path: String?
        let totalTokens: Int?
        let totalCostUSD: Double?
        let daily: [CostUsageDailyReport.Entry]
        let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]?
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case sessions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projects = try container.decode([Project].self, forKey: .projects).map { project in
            CostUsageScanner.withClaudeProjectSource(CostUsageProjectBreakdown(
                name: project.name,
                path: project.path,
                totalTokens: project.totalTokens,
                totalCostUSD: project.totalCostUSD,
                daily: project.daily,
                modelBreakdowns: project.modelBreakdowns))
        }
        self.sessions = try container.decode([Session].self, forKey: .sessions).map { session in
            CostUsageSessionBreakdown(
                sessionID: session.id,
                lastActivity: session.lastActivity,
                inputTokens: session.inputTokens,
                cachedInputTokens: session.cachedInputTokens,
                outputTokens: session.outputTokens,
                totalTokens: session.totalTokens,
                requestCount: session.requestCount,
                costUSD: session.costUSD,
                modelBreakdowns: session.modelBreakdowns,
                projectPath: session.projectPath,
                projectName: session.projectName)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.projects.map { project in
            Project(
                name: project.name,
                path: project.path,
                totalTokens: project.totalTokens,
                totalCostUSD: project.totalCostUSD,
                daily: project.daily,
                modelBreakdowns: project.modelBreakdowns)
        }, forKey: .projects)
        try container.encode(self.sessions.map { session in
            Session(
                id: session.sessionID,
                lastActivity: session.lastActivity,
                inputTokens: session.inputTokens,
                cachedInputTokens: session.cachedInputTokens,
                outputTokens: session.outputTokens,
                totalTokens: session.totalTokens,
                requestCount: session.requestCount,
                costUSD: session.costUSD,
                modelBreakdowns: session.modelBreakdowns,
                projectPath: session.projectPath,
                projectName: session.projectName)
        }, forKey: .sessions)
    }
}

extension CostUsageScanner {
    /// Partitions the reconciled rows, so sessions and projects each sum to the native daily report.
    static func buildClaudeReportBreakdowns(
        artifact: CostUsageClaudeCache,
        reconciled: (rows: [ClaudeUsageRow], fileIndexes: [Int32], filePaths: [String]),
        daily: CostUsageDailyReport,
        range: CostUsageDayRange,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> ClaudeReportBreakdowns
    {
        let cache = artifact.usage
        let (rows, fileIndexes, filePaths) = reconciled
        // Row-less legacy caches keep only day totals, which cannot be attributed.
        guard !cache.files.isEmpty,
              cache.files.values.allSatisfy({ $0.claudeRows != nil }),
              rows.count == fileIndexes.count
        else { return ClaudeReportBreakdowns(projects: [], sessions: []) }

        // Group row indexes, not row copies; each group's rows exist only while its report is built.
        var fallbackKeys: [String?] = Array(repeating: nil, count: filePaths.count)
        var rowIndexesBySession: [String: [Int32]] = [:]
        var latestFileMsBySession: [String: Int64] = [:]
        for (rowIndex, fileIndex) in fileIndexes.enumerated() {
            let file = Int(fileIndex)
            let row = rows[rowIndex]
            let sessionKey: String
            if let key = Self.claudeSessionKey(row.sessionId) {
                sessionKey = key
            } else if let key = fallbackKeys[file] {
                sessionKey = key
            } else {
                sessionKey = Self.claudeFallbackSessionKey(filePath: filePaths[file])
                fallbackKeys[file] = sessionKey
            }
            rowIndexesBySession[sessionKey, default: []].append(Int32(rowIndex))
            if row.timestampUnixMs == nil, let mtime = cache.files[filePaths[file]]?.mtimeUnixMs {
                latestFileMsBySession[sessionKey] = max(latestFileMsBySession[sessionKey] ?? mtime, mtime)
            }
        }

        // A (day, model) the native report cannot price stays unpriced in every group, keeping the partition.
        let unresolvedDayModels = Set(daily.data.flatMap { entry in
            (entry.modelBreakdowns ?? []).filter { $0.costUSD == nil }.map {
                ClaudeDayModelKey(day: entry.date, model: $0.modelName)
            }
        })
        func groupReport(_ indexes: [Int32]) -> CostUsageDailyReport {
            Self.buildClaudeReportFromCache(
                cache: cache,
                rows: indexes.map { rows[Int($0)] },
                range: range,
                pricingResolver: pricingResolver,
                hasCompleteRows: true,
                includesTemporal: false,
                unresolvedDayModels: unresolvedDayModels)
        }

        let projectPathBySession = Self.claudeProjectPathsBySession(sourceProjectPaths: artifact.sourceProjectPaths)
        var sessionKeysByProject: [String: [String]] = [:]
        var sessions: [CostUsageSessionBreakdown] = []
        sessions.reserveCapacity(rowIndexesBySession.count)
        for (sessionKey, indexes) in rowIndexesBySession {
            let projectKey = projectPathBySession[sessionKey].map(Self.claudeProjectKey(cwd:)) ?? ""
            sessionKeysByProject[projectKey, default: []].append(sessionKey)
            let report = groupReport(indexes)
            guard !report.data.isEmpty else { continue }
            let summary = report.summary
            let projectPath = projectKey.isEmpty ? nil : projectKey
            let latestMs = indexes.lazy.compactMap { rows[Int($0)].timestampUnixMs }.max()
                ?? latestFileMsBySession[sessionKey] ?? 0
            sessions.append(CostUsageSessionBreakdown(
                sessionID: sessionKey,
                lastActivity: Date(timeIntervalSince1970: TimeInterval(latestMs) / 1000),
                inputTokens: summary?.totalInputTokens.flatMap { input in
                    CheckedSum.integers([input, summary?.cacheReadTokens ?? 0, summary?.cacheCreationTokens ?? 0])
                },
                cachedInputTokens: summary?.cacheReadTokens,
                outputTokens: summary?.totalOutputTokens,
                totalTokens: summary?.totalTokens,
                requestCount: indexes.count(where: { index in
                    let row = rows[Int(index)]
                    return row.isIncomplete != true
                        && CostUsageDayRange.isInRange(dayKey: row.dayKey, since: range.sinceKey, until: range.untilKey)
                }),
                costUSD: summary?.totalCostUSD,
                modelBreakdowns: Self.claudeModelBreakdowns(from: report.data) ?? [],
                projectPath: projectPath,
                projectName: projectPath.map { Self.claudeProjectName(path: $0) }))
        }
        sessions.sort { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID > rhs.sessionID
        }

        var projects: [CostUsageProjectBreakdown] = []
        projects.reserveCapacity(sessionKeysByProject.count)
        for (projectKey, sessionKeys) in sessionKeysByProject {
            // Restore reconciled order so project sums follow the daily report's summation order.
            let indexes = sessionKeys.count == 1
                ? rowIndexesBySession[sessionKeys[0]] ?? []
                : sessionKeys.flatMap { rowIndexesBySession[$0] ?? [] }.sorted()
            let report = groupReport(indexes)
            guard !report.data.isEmpty else { continue }
            let path = projectKey.isEmpty ? nil : projectKey
            projects.append(Self.withClaudeProjectSource(CostUsageProjectBreakdown(
                name: Self.claudeProjectName(path: path),
                path: path,
                totalTokens: report.summary?.totalTokens,
                totalCostUSD: report.summary?.totalCostUSD,
                daily: report.data,
                modelBreakdowns: Self.claudeModelBreakdowns(from: report.data))))
        }
        projects.sort { lhs, rhs in
            let lhsRank = (lhs.totalCostUSD ?? -1, lhs.totalTokens ?? -1)
            let rhsRank = (rhs.totalCostUSD ?? -1, rhs.totalTokens ?? -1)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return ClaudeReportBreakdowns(projects: projects, sessions: sessions)
    }

    /// Each Claude project has one source: the transcript working directory itself.
    fileprivate static func withClaudeProjectSource(_ project: CostUsageProjectBreakdown) -> CostUsageProjectBreakdown {
        CostUsageProjectBreakdown(
            name: project.name,
            path: project.path,
            totalTokens: project.totalTokens,
            totalCostUSD: project.totalCostUSD,
            daily: project.daily,
            modelBreakdowns: project.modelBreakdowns,
            sources: [CostUsageProjectSourceBreakdown(
                name: project.name,
                path: project.path,
                totalTokens: project.totalTokens,
                totalCostUSD: project.totalCostUSD,
                daily: project.daily,
                modelBreakdowns: project.modelBreakdowns)])
    }

    /// A session's project is its first recorded cwd, parents before subagents, from any transcript that holds
    /// the session, so a cwd-less winning copy still lands in its session's project.
    private static func claudeProjectPathsBySession(
        sourceProjectPaths: [String: [String: String]]) -> [String: String]
    {
        let files = sourceProjectPaths.map { path, paths in
            (path: path, isSubagent: path.contains("/subagents/"), paths: paths)
        }
        .sorted { lhs, rhs in
            lhs.isSubagent != rhs.isSubagent ? !lhs.isSubagent : lhs.path < rhs.path
        }
        var projectBySession: [String: String] = [:]
        for file in files {
            projectBySession.merge(file.paths) { first, _ in first }
        }
        return projectBySession
    }

    static func claudeSessionKey(_ sessionId: String?) -> String? {
        self.claudeTrimmedNonEmpty(sessionId)
    }

    /// Trims only when an edge is whitespace; transcript ids and paths almost never need it.
    static func claudeTrimmedNonEmpty(_ value: String?) -> String? {
        guard let value, let first = value.first, let last = value.last else { return nil }
        guard first.isWhitespace || last.isWhitespace else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Subagent transcripts live under `<sessionId>/subagents/`; other transcripts are named `<sessionId>.jsonl`.
    static func claudeFallbackSessionKey(filePath: String) -> String {
        let url = URL(fileURLWithPath: filePath)
        let components = url.pathComponents
        if let index = components.lastIndex(of: "subagents"), index > 1 {
            return components[index - 1]
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func claudeProjectKey(cwd: String) -> String {
        cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).standardizedFileURL.path : cwd
    }

    private static func claudeProjectName(path: String?) -> String {
        guard let path, !path.isEmpty else { return CostUsageProjectBreakdown.unknownProjectName }
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func claudeModelBreakdowns(
        from entries: [CostUsageDailyReport.Entry]) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        let summaries = CostUsageDailyReport.modelCostSummaries(from: entries)
        return summaries.isEmpty ? nil : Self.sortedModelBreakdowns(summaries)
    }
}
