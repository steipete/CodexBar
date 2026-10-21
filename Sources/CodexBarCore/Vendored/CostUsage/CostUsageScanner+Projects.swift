import Foundation

extension CostUsageScanner {
    static func codexCache(_ cache: CostUsageCache, scopedTo roots: [URL]) -> CostUsageCache {
        var scoped = cache
        scoped.files = cache.files.filter { filePath, _ in
            Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: filePath), roots: roots)
        }
        scoped.days = [:]
        for usage in scoped.files.values {
            Self.applyFileDays(cache: &scoped, fileDays: usage.days, sign: 1)
        }
        return scoped
    }

    static func buildCodexReportProjectionsFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        sessionRoots: [URL]? = nil,
        includeBreakdowns: Bool = true,
        includeProjects: Bool = true,
        priorityTurns: [String: CodexPriorityTurnMetadata]? = nil,
        modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
            CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
        })
        -> (
            daily: CostUsageDailyReport,
            projects: [CostUsageProjectBreakdown],
            sessions: [CostUsageSessionBreakdown])
    {
        let priorityTurns = priorityTurns ?? cache.codexResolvedPriorityTurns ?? [:]
        // One refresh owns the pricing context; file reports feed both session and project projections.
        let resolvedModelsDevCatalog = modelsDevCatalog
            ?? modelsDevCatalogLoader(modelsDevCacheRoot)
            ?? ModelsDevCatalog(providers: [:])
        let pricingResolver = CostUsagePricing.CodexResolver(catalog: resolvedModelsDevCatalog)
        let daily = Self.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: resolvedModelsDevCatalog,
            priorityTurns: priorityTurns,
            pricingResolver: pricingResolver)
        guard includeBreakdowns else { return (daily, [], []) }
        var latestSessions: [String: (usage: CostUsageFileUsage, report: CostUsageDailyReport, path: String)] = [:]
        let projectPathResolver = CodexCanonicalProjectPathResolver()
        var accumulatorsByProjectPath: [String: CodexProjectBreakdownAccumulator] = [:]
        for (filePath, usage) in cache.files {
            guard usage.touchesCodexScanWindow(
                sinceKey: range.scanSinceKey,
                untilKey: range.scanUntilKey,
                calendar: range.calendar)
                || !Self.codexTurnPerformanceSamples(usage: usage, range: range).isEmpty
            else {
                continue
            }
            var fileCache = CostUsageCache()
            fileCache.files[filePath] = usage
            fileCache.days = usage.days
            let report = Self.buildCodexReportFromCache(
                cache: fileCache,
                range: range,
                modelsDevCatalog: resolvedModelsDevCatalog,
                priorityTurns: priorityTurns,
                pricingResolver: pricingResolver)
            let includeSession = sessionRoots.map {
                Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: filePath), roots: $0)
            } ?? true
            if includeSession {
                let id = usage.sessionId ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
                if !id.isEmpty, latestSessions[id].map({ $0.usage.mtimeUnixMs < usage.mtimeUnixMs }) ?? true {
                    latestSessions[id] = (usage, report, filePath)
                }
            }
            guard includeProjects, !report.data.isEmpty else { continue }
            let projectKey = usage.canonicalProjectPath
                ?? projectPathResolver.canonicalProjectPath(for: usage.projectPath)
                ?? ""
            let sourceKey = usage.projectPath ?? ""
            var accumulator = accumulatorsByProjectPath[projectKey] ?? CodexProjectBreakdownAccumulator()
            accumulator.files[filePath] = usage
            accumulator.reportsBySourcePath[sourceKey, default: []].append(report)
            accumulatorsByProjectPath[projectKey] = accumulator
        }

        let projects = accumulatorsByProjectPath.map { projectPath, accumulator in
            var projectCache = CostUsageCache()
            projectCache.files = accumulator.files
            for usage in accumulator.files.values {
                Self.applyFileDays(cache: &projectCache, fileDays: usage.days, sign: 1)
            }
            let report = Self.buildCodexReportFromCache(
                cache: projectCache,
                range: range,
                modelsDevCatalog: resolvedModelsDevCatalog,
                priorityTurns: priorityTurns,
                pricingResolver: pricingResolver)
            let resolvedPath = projectPath.isEmpty ? nil : projectPath
            return CostUsageProjectBreakdown(
                name: Self.codexProjectName(path: resolvedPath),
                path: resolvedPath,
                totalTokens: report.summary?.totalTokens,
                totalCostUSD: report.summary?.totalCostUSD,
                daily: report.data,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: report.data),
                sources: Self.codexProjectSourceBreakdowns(from: accumulator.reportsBySourcePath))
        }
        .sorted { lhs, rhs in
            let lhsRank = (lhs.totalCostUSD ?? -1, lhs.totalTokens ?? -1)
            let rhsRank = (rhs.totalCostUSD ?? -1, rhs.totalTokens ?? -1)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let sessions = latestSessions.compactMap { id, file -> CostUsageSessionBreakdown? in
            let performanceSamples = Self.codexTurnPerformanceSamples(usage: file.usage, range: range)
            // A turn can complete after midnight with all billed requests on the previous day.
            guard !file.report.data.isEmpty || !performanceSamples.isEmpty else { return nil }
            return Self.codexSessionBreakdown(
                source: SessionToolActivitySource(fileURL: URL(fileURLWithPath: file.path), sessionID: id),
                usage: file.usage,
                report: file.report,
                projectPathResolver: projectPathResolver,
                performanceSamples: performanceSamples)
        }
        .sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID > rhs.sessionID
        }
        return (daily, projects, sessions)
    }

    private static func codexSessionBreakdown(
        source: SessionToolActivitySource,
        usage: CostUsageFileUsage,
        report: CostUsageDailyReport,
        projectPathResolver: CodexCanonicalProjectPathResolver,
        performanceSamples: [CostUsageTurnPerformanceSample]) -> CostUsageSessionBreakdown
    {
        let summary = report.summary
        let requestCounts = report.data.compactMap(\.requestCount)
        let resolvedProjectPath = usage.canonicalProjectPath
            ?? projectPathResolver.canonicalProjectPath(for: usage.projectPath)
        let projectPath = resolvedProjectPath?.isEmpty == false ? resolvedProjectPath : nil
        var session = CostUsageSessionBreakdown(
            sessionID: source.sessionID,
            lastActivity: Date(timeIntervalSince1970: TimeInterval(usage.mtimeUnixMs) / 1000),
            inputTokens: summary?.totalInputTokens,
            cachedInputTokens: summary?.cacheReadTokens,
            outputTokens: summary?.totalOutputTokens,
            totalTokens: summary?.totalTokens,
            requestCount: requestCounts.isEmpty ? nil : requestCounts.reduce(0, +),
            costUSD: summary?.totalCostUSD,
            modelBreakdowns: Self.codexProjectModelBreakdowns(from: report.data) ?? [],
            projectPath: projectPath,
            projectName: projectPath.map { Self.codexProjectName(path: $0) },
            title: usage.codexSession?.title,
            turnPerformanceSamples: performanceSamples,
            toolActivitySource: source)
        session.workingDirectory = usage.projectPath
        return session
    }

    private static func codexProjectName(path: String?) -> String {
        guard let path, !path.isEmpty else { return CostUsageProjectBreakdown.unknownProjectName }
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    private struct CodexProjectBreakdownAccumulator {
        var files: [String: CostUsageFileUsage] = [:]
        var reportsBySourcePath: [String: [CostUsageDailyReport]] = [:]
    }

    private static func codexProjectSourceBreakdowns(
        from reportsBySourcePath: [String: [CostUsageDailyReport]]) -> [CostUsageProjectSourceBreakdown]
    {
        reportsBySourcePath.map { sourcePath, reports in
            let merged = CostUsageDailyReport.merged(reports)
            let resolvedPath = sourcePath.isEmpty ? nil : sourcePath
            return CostUsageProjectSourceBreakdown(
                name: Self.codexProjectName(path: resolvedPath),
                path: resolvedPath,
                totalTokens: merged.summary?.totalTokens,
                totalCostUSD: merged.summary?.totalCostUSD,
                daily: merged.data,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: merged.data))
        }
        .sorted { lhs, rhs in
            let lhsRank = (lhs.totalCostUSD ?? -1, lhs.totalTokens ?? -1)
            let rhsRank = (rhs.totalCostUSD ?? -1, rhs.totalTokens ?? -1)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func codexProjectModelBreakdowns(
        from entries: [CostUsageDailyReport.Entry]) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        let summaries = CostUsageDailyReport.modelCostSummaries(from: entries)
        return summaries.isEmpty ? nil : Self.sortedModelBreakdowns(summaries)
    }
}
