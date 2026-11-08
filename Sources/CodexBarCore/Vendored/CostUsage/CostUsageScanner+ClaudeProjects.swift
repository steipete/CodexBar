import Foundation

struct ClaudeReportBreakdowns: Sendable {
    let projects: [CostUsageProjectBreakdown]
    let sessions: [CostUsageSessionBreakdown]
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

extension CostUsageScanner {
    /// Partitions the reconciled rows, so sessions and projects each sum to the native daily report.
    static func buildClaudeReportBreakdowns(
        cache: CostUsageCache,
        reconciled: (rows: [ClaudeUsageRow], fileIndexes: [Int32], filePaths: [String]),
        range: CostUsageDayRange,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> ClaudeReportBreakdowns
    {
        let (rows, fileIndexes, filePaths) = reconciled
        // Row-less legacy caches keep only day totals, which cannot be attributed.
        guard !cache.files.isEmpty,
              cache.files.values.allSatisfy({ $0.claudeRows != nil }),
              rows.count == fileIndexes.count
        else { return ClaudeReportBreakdowns(projects: [], sessions: []) }

        let projectBySession = Self.claudeProjectPathsBySession(cache: cache)
        var fallbackKeys: [String?] = Array(repeating: nil, count: filePaths.count)
        var projectKeyBySession: [String: String] = [:]
        var rowsBySession: [String: [ClaudeUsageRow]] = [:]
        var rowsByProject: [String: [ClaudeUsageRow]] = [:]
        var latestFileMsBySession: [String: Int64] = [:]

        for (row, fileIndex) in zip(rows, fileIndexes) {
            let file = Int(fileIndex)
            let sessionKey: String
            if let key = Self.claudeSessionKey(row: row) {
                sessionKey = key
            } else if let key = fallbackKeys[file] {
                sessionKey = key
            } else {
                sessionKey = Self.claudeFallbackSessionKey(filePath: filePaths[file])
                fallbackKeys[file] = sessionKey
            }
            let projectKey: String
            if let key = projectKeyBySession[sessionKey] {
                projectKey = key
            } else {
                projectKey = projectBySession[sessionKey].map(Self.claudeProjectKey(cwd:)) ?? ""
                projectKeyBySession[sessionKey] = projectKey
            }
            rowsBySession[sessionKey, default: []].append(row)
            rowsByProject[projectKey, default: []].append(row)
            if row.timestampUnixMs == nil, let mtime = cache.files[filePaths[file]]?.mtimeUnixMs {
                latestFileMsBySession[sessionKey] = max(latestFileMsBySession[sessionKey] ?? mtime, mtime)
            }
        }

        func groupReport(_ rows: [ClaudeUsageRow]) -> CostUsageDailyReport {
            Self.buildClaudeReportFromCache(
                cache: cache,
                rows: rows,
                range: range,
                pricingResolver: pricingResolver,
                hasCompleteRows: true)
        }

        let sessions = rowsBySession.compactMap { sessionKey, sessionRows -> CostUsageSessionBreakdown? in
            let report = groupReport(sessionRows)
            guard !report.data.isEmpty else { return nil }
            let summary = report.summary
            let projectKey = projectKeyBySession[sessionKey] ?? ""
            let projectPath = projectKey.isEmpty ? nil : projectKey
            let latestMs = sessionRows.compactMap(\.timestampUnixMs).max() ?? latestFileMsBySession[sessionKey] ?? 0
            return CostUsageSessionBreakdown(
                sessionID: sessionKey,
                lastActivity: Date(timeIntervalSince1970: TimeInterval(latestMs) / 1000),
                inputTokens: summary?.totalInputTokens.flatMap { input in
                    CheckedSum.integers([input, summary?.cacheReadTokens ?? 0, summary?.cacheCreationTokens ?? 0])
                },
                cachedInputTokens: summary?.cacheReadTokens,
                outputTokens: summary?.totalOutputTokens,
                totalTokens: summary?.totalTokens,
                requestCount: sessionRows.count(where: { row in
                    row.isIncomplete != true
                        && CostUsageDayRange.isInRange(dayKey: row.dayKey, since: range.sinceKey, until: range.untilKey)
                }),
                costUSD: summary?.totalCostUSD,
                modelBreakdowns: Self.claudeModelBreakdowns(from: report.data) ?? [],
                projectPath: projectPath,
                projectName: projectPath.map { Self.claudeProjectName(path: $0) })
        }
        .sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID > rhs.sessionID
        }

        let projects = rowsByProject.compactMap { projectKey, projectRows -> CostUsageProjectBreakdown? in
            let report = groupReport(projectRows)
            guard !report.data.isEmpty else { return nil }
            let path = projectKey.isEmpty ? nil : projectKey
            let name = Self.claudeProjectName(path: path)
            let modelBreakdowns = Self.claudeModelBreakdowns(from: report.data)
            return CostUsageProjectBreakdown(
                name: name,
                path: path,
                totalTokens: report.summary?.totalTokens,
                totalCostUSD: report.summary?.totalCostUSD,
                daily: report.data,
                modelBreakdowns: modelBreakdowns,
                sources: [CostUsageProjectSourceBreakdown(
                    name: name,
                    path: path,
                    totalTokens: report.summary?.totalTokens,
                    totalCostUSD: report.summary?.totalCostUSD,
                    daily: report.data,
                    modelBreakdowns: modelBreakdowns)])
        }
        .sorted { lhs, rhs in
            let lhsRank = (lhs.totalCostUSD ?? -1, lhs.totalTokens ?? -1)
            let rhsRank = (rhs.totalCostUSD ?? -1, rhs.totalTokens ?? -1)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return ClaudeReportBreakdowns(projects: projects, sessions: sessions)
    }

    /// A session's project is the cwd of its first contributing transcript, parents before subagents,
    /// counting losing duplicates, so a cwd-less winning copy still lands in its session's project.
    private static func claudeProjectPathsBySession(cache: CostUsageCache) -> [String: String] {
        let paths = cache.files.keys.sorted { lhs, rhs in
            let lhsSubagent = lhs.contains("/subagents/")
            let rhsSubagent = rhs.contains("/subagents/")
            return lhsSubagent != rhsSubagent ? !lhsSubagent : lhs < rhs
        }
        var projectBySession: [String: String] = [:]
        for path in paths {
            guard let file = cache.files[path],
                  let cwd = file.projectPath, !cwd.isEmpty,
                  let rows = file.claudeRows, !rows.isEmpty
            else { continue }
            let fallbackKey = Self.claudeFallbackSessionKey(filePath: path)
            for row in rows {
                let sessionKey = Self.claudeSessionKey(row: row) ?? fallbackKey
                if projectBySession[sessionKey] == nil {
                    projectBySession[sessionKey] = cwd
                }
            }
        }
        return projectBySession
    }

    private static func claudeSessionKey(row: ClaudeUsageRow) -> String? {
        guard let sessionId = row.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty
        else { return nil }
        return sessionId
    }

    /// Subagent transcripts live under `<sessionId>/subagents/`; other transcripts are named `<sessionId>.jsonl`.
    private static func claudeFallbackSessionKey(filePath: String) -> String {
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
