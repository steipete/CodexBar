import Foundation

extension CostUsageScanner {
    static func buildCodexProjectBreakdownsFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:],
        modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
            CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
        }) -> [CostUsageProjectBreakdown]
    {
        // Project rollups build one report per cached session file. Resolve pricing once so every
        // row does not fall back through ModelsDevCache.load and repeat filesystem metadata reads.
        let resolvedModelsDevCatalog = modelsDevCatalog
            ?? modelsDevCatalogLoader(modelsDevCacheRoot)
            ?? ModelsDevCatalog(providers: [:])
        let projectPathResolver = CodexCanonicalProjectPathResolver()
        var accumulatorsByProjectPath: [String: CodexProjectBreakdownAccumulator] = [:]
        for (filePath, usage) in cache.files {
            guard usage.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) else {
                continue
            }
            var fileCache = CostUsageCache()
            fileCache.files[filePath] = usage
            fileCache.days = usage.days
            let report = Self.buildCodexReportFromCache(
                cache: fileCache,
                range: range,
                modelsDevCatalog: resolvedModelsDevCatalog,
                priorityTurns: priorityTurns)
            guard !report.data.isEmpty else { continue }
            let projectKey = usage.canonicalProjectPath
                ?? projectPathResolver.canonicalProjectPath(for: usage.projectPath)
                ?? ""
            let sourceKey = usage.projectPath ?? ""
            var accumulator = accumulatorsByProjectPath[projectKey] ?? CodexProjectBreakdownAccumulator()
            accumulator.add(report: report, sourcePath: sourceKey)
            accumulatorsByProjectPath[projectKey] = accumulator
        }

        return accumulatorsByProjectPath.map { projectPath, accumulator in
            let merged = CostUsageDailyReport.merged(accumulator.reports)
            let resolvedPath = projectPath.isEmpty ? nil : projectPath
            return CostUsageProjectBreakdown(
                name: Self.codexProjectName(path: resolvedPath),
                path: resolvedPath,
                totalTokens: merged.summary?.totalTokens,
                totalCostUSD: merged.summary?.totalCostUSD,
                daily: merged.data,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: merged.data),
                sources: Self.codexProjectSourceBreakdowns(from: accumulator.reportsBySourcePath))
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.totalCostUSD ?? -1
            let rhsCost = rhs.totalCostUSD ?? -1
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func codexProjectName(path: String?) -> String {
        guard let path, !path.isEmpty else { return CostUsageProjectBreakdown.unknownProjectName }
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    private struct CodexProjectBreakdownAccumulator {
        var reports: [CostUsageDailyReport] = []
        var reportsBySourcePath: [String: [CostUsageDailyReport]] = [:]

        mutating func add(report: CostUsageDailyReport, sourcePath: String) {
            self.reports.append(report)
            self.reportsBySourcePath[sourcePath, default: []].append(report)
        }
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
            let lhsCost = lhs.totalCostUSD ?? -1
            let rhsCost = rhs.totalCostUSD ?? -1
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private struct ProjectBreakdownAccumulator {
        var totalTokens = 0
        var sawTotalTokens = false
        var costUSD: Double = 0
        var sawCost = false
        var standardCostUSD: Double = 0
        var sawStandardCost = false
        var priorityCostUSD: Double = 0
        var sawPriorityCost = false
        var standardTokens = 0
        var sawStandardTokens = false
        var priorityTokens = 0
        var sawPriorityTokens = false

        mutating func add(_ breakdown: CostUsageDailyReport.ModelBreakdown) {
            if let totalTokens = breakdown.totalTokens {
                self.totalTokens += totalTokens
                self.sawTotalTokens = true
            }
            if let costUSD = breakdown.costUSD {
                self.costUSD += costUSD
                self.sawCost = true
            }
            if let standardCostUSD = breakdown.standardCostUSD {
                self.standardCostUSD += standardCostUSD
                self.sawStandardCost = true
            }
            if let priorityCostUSD = breakdown.priorityCostUSD {
                self.priorityCostUSD += priorityCostUSD
                self.sawPriorityCost = true
            }
            if let standardTokens = breakdown.standardTokens {
                self.standardTokens += standardTokens
                self.sawStandardTokens = true
            }
            if let priorityTokens = breakdown.priorityTokens {
                self.priorityTokens += priorityTokens
                self.sawPriorityTokens = true
            }
        }

        func build(modelName: String) -> CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: modelName,
                costUSD: self.sawCost ? self.costUSD : nil,
                totalTokens: self.sawTotalTokens ? self.totalTokens : nil,
                standardCostUSD: self.sawStandardCost ? self.standardCostUSD : nil,
                priorityCostUSD: self.sawPriorityCost ? self.priorityCostUSD : nil,
                standardTokens: self.sawStandardTokens ? self.standardTokens : nil,
                priorityTokens: self.sawPriorityTokens ? self.priorityTokens : nil)
        }
    }

    private static func codexProjectModelBreakdowns(
        from entries: [CostUsageDailyReport.Entry]) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        var accumulators: [String: ProjectBreakdownAccumulator] = [:]
        for entry in entries {
            for breakdown in entry.modelBreakdowns ?? [] {
                var accumulator = accumulators[breakdown.modelName] ?? ProjectBreakdownAccumulator()
                accumulator.add(breakdown)
                accumulators[breakdown.modelName] = accumulator
            }
        }
        guard !accumulators.isEmpty else { return nil }
        return Self.sortedModelBreakdowns(accumulators.map { modelName, accumulator in
            accumulator.build(modelName: modelName)
        })
    }
}
