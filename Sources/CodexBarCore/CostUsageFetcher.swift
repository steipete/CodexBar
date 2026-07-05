import Foundation

public enum CostUsageError: LocalizedError, Sendable {
    case unsupportedProvider(UsageProvider)
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "Cost summary is not supported for \(provider.rawValue)."
        case let .timedOut(seconds):
            if seconds >= 60, seconds % 60 == 0 {
                return "Cost refresh timed out after \(seconds / 60)m."
            }
            return "Cost refresh timed out after \(seconds)s."
        }
    }
}

public struct CostUsageFetcher: Sendable {
    package struct CachedCodexTokenSnapshotResult: Sendable {
        package let snapshot: CostUsageTokenSnapshot
        package let lastRefreshAt: Date?
    }

    private let scannerOptions: CostUsageScanner.Options?

    public init(cacheRoot: URL? = nil) {
        self.scannerOptions = cacheRoot.map { CostUsageScanner.Options(cacheRoot: $0) }
    }

    init(scannerOptions: CostUsageScanner.Options) {
        self.scannerOptions = scannerOptions
    }

    public func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30) async -> CostUsageTokenSnapshot?
    {
        await Self.loadCachedCodexTokenSnapshot(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            scannerOptions: self.scannerOptionsOverride())
    }

    package func loadCachedCodexTokenSnapshotResult(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30) async -> CachedCodexTokenSnapshotResult?
    {
        await Self.loadCachedCodexTokenSnapshotResult(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            scannerOptions: self.scannerOptionsOverride())
    }

    public func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true) async throws -> CostUsageTokenSnapshot
    {
        try await Self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            refreshPricingInBackground: refreshPricingInBackground,
            scannerOptions: self.scannerOptionsOverride())
    }

    @available(*, deprecated, message: "Codex token-cost scans are uncapped; this limit is ignored.")
    public func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true,
        automaticCodexScanByteLimit _: Int64?) async throws -> CostUsageTokenSnapshot
    {
        try await self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            refreshPricingInBackground: refreshPricingInBackground)
    }

    private func scannerOptionsOverride() -> CostUsageScanner.Options? {
        self.scannerOptions
    }

    static func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        refreshPricingInBackground: Bool = true,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil,
        piScannerOptions overridePiScannerOptions: PiSessionCostScanner
            .Options? = nil) async throws -> CostUsageTokenSnapshot
    {
        guard provider == .codex || provider == .claude || provider == .vertexai || provider == .bedrock else {
            throw CostUsageError.unsupportedProvider(provider)
        }

        let until = now
        let clampedHistoryDays = max(1, min(365, historyDays))
        // Rolling window is inclusive, so a 30-day display starts 29 days before `now`.
        let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now

        if provider == .bedrock {
            let daily = try await Self.loadBedrockDailyReport(
                environment: environment,
                since: since,
                until: until)
            return Self.tokenSnapshot(
                from: daily,
                now: now,
                historyDays: clampedHistoryDays,
                useCurrentLocalDayForSession: false)
        }

        var options = overrideScannerOptions ?? CostUsageScanner.Options()
        if provider == .codex,
           let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            options.codexSessionsRoot = URL(fileURLWithPath: codexHomePath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        if provider == .codex || provider == .claude {
            let pricingCacheRoot = options.cacheRoot
            if refreshPricingInBackground {
                Task.detached(priority: .utility) {
                    await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: pricingCacheRoot)
                }
            } else {
                await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: pricingCacheRoot)
            }
        }

        if provider == .vertexai {
            options.claudeLogProviderFilter = allowVertexClaudeFallback ? .all : .vertexAIOnly
        } else if provider == .claude {
            options.claudeLogProviderFilter = .excludeVertexAI
        }
        if forceRefresh {
            options.refreshMinIntervalSeconds = 0
        }
        var resolvedPiOptions = overridePiScannerOptions ?? PiSessionCostScanner.Options()
        if resolvedPiOptions.cacheRoot == nil {
            resolvedPiOptions.cacheRoot = options.cacheRoot
        }
        if forceRefresh {
            resolvedPiOptions.refreshMinIntervalSeconds = 0
        }
        let piOptions = resolvedPiOptions

        try Task.checkCancellation()
        // The corpus scans below are synchronous and can run for minutes on large session
        // archives. They execute on the dedicated scan queue so they never occupy a cooperative
        // pool thread; CostUsageScanExecutor bridges this task's cancellation into the
        // scanner-level checks.
        let scanOptions = options
        let scanResult = try await CostUsageScanExecutor.run { checkCancellation in
            var daily = try CostUsageScanner.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: scanOptions,
                checkCancellation: checkCancellation)
            try checkCancellation()

            if provider == .vertexai,
               !allowVertexClaudeFallback,
               scanOptions.claudeLogProviderFilter == .vertexAIOnly,
               daily.data.isEmpty
            {
                var fallback = scanOptions
                fallback.claudeLogProviderFilter = .all
                daily = try CostUsageScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: until,
                    now: now,
                    options: fallback,
                    checkCancellation: checkCancellation)
                try checkCancellation()
            }

            var projects: [CostUsageProjectBreakdown] = []
            var piDaily: CostUsageDailyReport?
            if provider == .codex {
                let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: scanOptions.cacheRoot)
                projects = CostUsageScanner.buildCodexProjectBreakdownsFromCache(
                    cache: cache,
                    range: CostUsageScanner.CostUsageDayRange(since: since, until: until),
                    modelsDevCacheRoot: scanOptions.cacheRoot)
            }
            if provider == .codex || provider == .claude {
                let piReport = try PiSessionCostScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: until,
                    now: now,
                    options: piOptions,
                    checkCancellation: checkCancellation)
                try checkCancellation()
                if provider == .codex {
                    piDaily = piReport
                }
                daily = CostUsageDailyReport.merged([daily, piReport])
            }
            if provider == .codex {
                projects = Self.mergedProjectBreakdowns(
                    projects + [piDaily.flatMap(Self.unknownProjectBreakdown(from:))].compactMap(\.self))
            }
            return (daily: daily, projects: projects)
        }

        return Self.tokenSnapshot(
            from: scanResult.daily,
            now: now,
            historyDays: clampedHistoryDays,
            projects: scanResult.projects)
    }

    static func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async -> CostUsageTokenSnapshot?
    {
        await self.loadCachedCodexTokenSnapshotResult(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            scannerOptions: overrideScannerOptions)?.snapshot
    }

    static func loadCachedCodexTokenSnapshotResult(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async
        -> CachedCodexTokenSnapshotResult?
    {
        if let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            return nil
        }

        // Decoding the persisted scan cache parses multi-megabyte JSON; keep it off the
        // cooperative pool alongside the scans themselves.
        let cachedSnapshot: CachedCodexTokenSnapshotResult?? = try? await CostUsageScanExecutor.run { _ in
            let clampedHistoryDays = max(1, min(365, historyDays))
            let until = now
            let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now
            let range = CostUsageScanner.CostUsageDayRange(since: since, until: until)
            let options = overrideScannerOptions ?? CostUsageScanner.Options()
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
            var reports: [CostUsageDailyReport] = []
            var projects: [CostUsageProjectBreakdown] = []
            var nativeLastRefreshAt: Date?

            if !cache.days.isEmpty,
               cache.roots == CostUsageScanner.codexRootsFingerprint(options: options),
               !CostUsageScanner.requestedWindowExpandsCache(range: range, cache: cache)
            {
                let daily = CostUsageScanner.buildCodexReportFromCache(
                    cache: cache,
                    range: range,
                    modelsDevCacheRoot: options.cacheRoot)
                if !daily.data.isEmpty {
                    reports.append(daily)
                    if cache.lastScanUnixMs > 0 {
                        nativeLastRefreshAt = Date(
                            timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)
                    }
                    if cache.codexProjectMetadataVersion == CostUsageScanner.codexProjectMetadataVersion {
                        projects.append(contentsOf: CostUsageScanner.buildCodexProjectBreakdownsFromCache(
                            cache: cache,
                            range: range,
                            modelsDevCacheRoot: options.cacheRoot))
                    }
                }
            }

            if let piDaily = PiSessionCostScanner.loadCachedDailyReport(
                provider: .codex,
                since: since,
                until: until,
                now: now,
                cacheRoot: options.cacheRoot)
            {
                reports.append(piDaily)
                nativeLastRefreshAt = nil
                if let piProject = Self.unknownProjectBreakdown(from: piDaily) {
                    projects.append(piProject)
                }
            }

            guard !reports.isEmpty else { return nil }
            return CachedCodexTokenSnapshotResult(
                snapshot: Self.tokenSnapshot(
                    from: CostUsageDailyReport.merged(reports),
                    now: now,
                    historyDays: clampedHistoryDays,
                    projects: Self.mergedProjectBreakdowns(projects)),
                lastRefreshAt: nativeLastRefreshAt)
        }
        return cachedSnapshot.flatMap(\.self)
    }

    private static func loadBedrockDailyReport(
        environment: [String: String],
        since: Date,
        until: Date) async throws -> CostUsageDailyReport
    {
        let resolved = try await BedrockCredentialResolver.resolve(environment: environment)
        return try await BedrockUsageFetcher.fetchDailyReport(
            credentials: resolved.credentials,
            since: since,
            until: until,
            environment: environment)
    }

    static func tokenSnapshot(
        from daily: CostUsageDailyReport,
        now: Date,
        historyDays: Int = 30,
        useCurrentLocalDayForSession: Bool = true,
        projects: [CostUsageProjectBreakdown] = []) -> CostUsageTokenSnapshot
    {
        let sessionEntry = useCurrentLocalDayForSession
            ? CostUsageTokenSnapshot.entry(in: daily.data, forLocalDayContaining: now)
            : CostUsageTokenSnapshot.latestEntry(in: daily.data)
        let hasHistoricalRows = !daily.data.isEmpty
        let sessionTokens: Int? = if let sessionEntry {
            sessionEntry.totalTokens
        } else if hasHistoricalRows {
            0
        } else {
            nil
        }
        let sessionCostUSD: Double? = if let sessionEntry {
            sessionEntry.costUSD
        } else if hasHistoricalRows {
            0
        } else {
            nil
        }
        // Prefer summary totals when present; fall back to summing daily entries.
        let totalFromSummary = daily.summary?.totalCostUSD
        let totalFromEntries = daily.data.compactMap(\.costUSD).reduce(0, +)
        let last30DaysCostUSD = totalFromSummary ?? (totalFromEntries > 0 ? totalFromEntries : nil)
        let totalTokensFromSummary = daily.summary?.totalTokens
        let totalTokensFromEntries = daily.data.compactMap(\.totalTokens).reduce(0, +)
        let last30DaysTokens = totalTokensFromSummary ?? (totalTokensFromEntries > 0 ? totalTokensFromEntries : nil)

        return CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: historyDays,
            daily: daily.data,
            projects: projects,
            updatedAt: now)
    }

    private static func unknownProjectBreakdown(from daily: CostUsageDailyReport) -> CostUsageProjectBreakdown? {
        guard !daily.data.isEmpty else { return nil }
        return CostUsageProjectBreakdown(
            name: CostUsageProjectBreakdown.unknownProjectName,
            path: nil,
            totalTokens: daily.summary?.totalTokens,
            totalCostUSD: daily.summary?.totalCostUSD,
            daily: daily.data,
            modelBreakdowns: self.projectModelBreakdowns(from: daily.data),
            sources: [
                CostUsageProjectSourceBreakdown(
                    name: CostUsageProjectBreakdown.unknownProjectName,
                    path: nil,
                    totalTokens: daily.summary?.totalTokens,
                    totalCostUSD: daily.summary?.totalCostUSD,
                    daily: daily.data,
                    modelBreakdowns: self.projectModelBreakdowns(from: daily.data)),
            ])
    }

    private static func mergedProjectBreakdowns(
        _ projects: [CostUsageProjectBreakdown]) -> [CostUsageProjectBreakdown]
    {
        var dailyByPath: [String: [CostUsageDailyReport]] = [:]
        var namesByPath: [String: String] = [:]
        var sourceDailyByProjectPath: [String: [String: [CostUsageDailyReport]]] = [:]
        var sourceNamesByProjectPath: [String: [String: String]] = [:]
        for project in projects {
            let key = project.path ?? ""
            namesByPath[key] = project.name
            dailyByPath[key, default: []].append(CostUsageDailyReport(data: project.daily, summary: nil))
            let sources = project.sources.isEmpty
                ? [
                    CostUsageProjectSourceBreakdown(
                        name: project.name,
                        path: project.path,
                        totalTokens: project.totalTokens,
                        totalCostUSD: project.totalCostUSD,
                        daily: project.daily,
                        modelBreakdowns: project.modelBreakdowns),
                ]
                : project.sources
            for source in sources {
                let sourceKey = source.path ?? ""
                sourceNamesByProjectPath[key, default: [:]][sourceKey] = source.name
                sourceDailyByProjectPath[key, default: [:]][sourceKey, default: []]
                    .append(CostUsageDailyReport(data: source.daily, summary: nil))
            }
        }
        return dailyByPath.map { key, reports in
            let merged = CostUsageDailyReport.merged(reports)
            return CostUsageProjectBreakdown(
                name: namesByPath[key] ?? CostUsageProjectBreakdown.unknownProjectName,
                path: key.isEmpty ? nil : key,
                totalTokens: merged.summary?.totalTokens,
                totalCostUSD: merged.summary?.totalCostUSD,
                daily: merged.data,
                modelBreakdowns: Self.projectModelBreakdowns(from: merged.data),
                sources: Self.mergedProjectSources(
                    sourceDailyByPath: sourceDailyByProjectPath[key] ?? [:],
                    sourceNamesByPath: sourceNamesByProjectPath[key] ?? [:]))
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

    private static func mergedProjectSources(
        sourceDailyByPath: [String: [CostUsageDailyReport]],
        sourceNamesByPath: [String: String]) -> [CostUsageProjectSourceBreakdown]
    {
        sourceDailyByPath.map { key, reports in
            let merged = CostUsageDailyReport.merged(reports)
            return CostUsageProjectSourceBreakdown(
                name: sourceNamesByPath[key] ?? CostUsageProjectBreakdown.unknownProjectName,
                path: key.isEmpty ? nil : key,
                totalTokens: merged.summary?.totalTokens,
                totalCostUSD: merged.summary?.totalCostUSD,
                daily: merged.data,
                modelBreakdowns: Self.projectModelBreakdowns(from: merged.data))
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

        mutating func add(_ breakdown: CostUsageDailyReport.ModelBreakdown) {
            if let totalTokens = breakdown.totalTokens {
                self.totalTokens += totalTokens
                self.sawTotalTokens = true
            }
            if let costUSD = breakdown.costUSD {
                self.costUSD += costUSD
                self.sawCost = true
            }
        }

        func build(modelName: String) -> CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: modelName,
                costUSD: self.sawCost ? self.costUSD : nil,
                totalTokens: self.sawTotalTokens ? self.totalTokens : nil)
        }
    }

    private static func projectModelBreakdowns(
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
        return accumulators.map { modelName, accumulator in
            accumulator.build(modelName: modelName)
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
            return lhs.modelName > rhs.modelName
        }
    }

    static func selectCurrentSession(from sessions: [CostUsageSessionReport.Entry])
        -> CostUsageSessionReport.Entry?
    {
        if sessions.isEmpty { return nil }
        return sessions.max { lhs, rhs in
            let lDate = CostUsageDateParser.parse(lhs.lastActivity) ?? .distantPast
            let rDate = CostUsageDateParser.parse(rhs.lastActivity) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.session < rhs.session
        }
    }

    static func selectMostRecentMonth(from months: [CostUsageMonthlyReport.Entry])
        -> CostUsageMonthlyReport.Entry?
    {
        if months.isEmpty { return nil }
        return months.max { lhs, rhs in
            let lDate = CostUsageDateParser.parseMonth(lhs.month) ?? .distantPast
            let rDate = CostUsageDateParser.parseMonth(rhs.month) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.month < rhs.month
        }
    }
}
