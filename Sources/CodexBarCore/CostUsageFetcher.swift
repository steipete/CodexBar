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
            return Self.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
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
        let checkCancellation: CostUsageScanner.CancellationCheck = {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        var daily = try CostUsageScanner.loadDailyReportCancellable(
            provider: provider,
            since: since,
            until: until,
            now: now,
            options: options,
            checkCancellation: checkCancellation)
        try Task.checkCancellation()

        if provider == .vertexai,
           !allowVertexClaudeFallback,
           options.claudeLogProviderFilter == .vertexAIOnly,
           daily.data.isEmpty
        {
            var fallback = options
            fallback.claudeLogProviderFilter = .all
            daily = try CostUsageScanner.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: fallback,
                checkCancellation: checkCancellation)
            try Task.checkCancellation()
        }

        if provider == .codex || provider == .claude {
            var piOptions = overridePiScannerOptions ?? PiSessionCostScanner.Options()
            if piOptions.cacheRoot == nil {
                piOptions.cacheRoot = options.cacheRoot
            }
            if forceRefresh {
                piOptions.refreshMinIntervalSeconds = 0
            }
            let piReport = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: piOptions,
                checkCancellation: checkCancellation)
            try Task.checkCancellation()
            daily = CostUsageDailyReport.merged([daily, piReport])
        }

        return Self.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
    }

    static func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async -> CostUsageTokenSnapshot?
    {
        if let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            return nil
        }

        return await Task.detached(priority: .utility) {
            let clampedHistoryDays = max(1, min(365, historyDays))
            let until = now
            let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now
            let range = CostUsageScanner.CostUsageDayRange(since: since, until: until)
            let options = overrideScannerOptions ?? CostUsageScanner.Options()
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
            var reports: [CostUsageDailyReport] = []

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
            }

            guard !reports.isEmpty else { return nil }
            return Self.tokenSnapshot(
                from: CostUsageDailyReport.merged(reports),
                now: now,
                historyDays: clampedHistoryDays)
        }.value
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
        historyDays: Int = 30) -> CostUsageTokenSnapshot
    {
        // Pick the most recent day; break ties by cost/tokens to keep a stable "session" row.
        let currentDay = daily.data.max { lhs, rhs in
            let lDate = CostUsageDateParser.parse(lhs.date) ?? .distantPast
            let rDate = CostUsageDateParser.parse(rhs.date) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.date < rhs.date
        }
        // Prefer summary totals when present; fall back to summing daily entries.
        let totalFromSummary = daily.summary?.totalCostUSD
        let totalFromEntries = daily.data.compactMap(\.costUSD).reduce(0, +)
        let last30DaysCostUSD = totalFromSummary ?? (totalFromEntries > 0 ? totalFromEntries : nil)
        let totalTokensFromSummary = daily.summary?.totalTokens
        let totalTokensFromEntries = daily.data.compactMap(\.totalTokens).reduce(0, +)
        let last30DaysTokens = totalTokensFromSummary ?? (totalTokensFromEntries > 0 ? totalTokensFromEntries : nil)

        return CostUsageTokenSnapshot(
            sessionTokens: currentDay?.totalTokens,
            sessionCostUSD: currentDay?.costUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: historyDays,
            daily: daily.data,
            updatedAt: now)
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
