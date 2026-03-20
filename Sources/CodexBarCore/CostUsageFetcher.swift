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
    public init() {}

    public func loadTokenSnapshot(
        provider: UsageProvider,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexSessionsRoot: URL? = nil,
        claudeProjectsRoots: [URL]? = nil) async throws -> CostUsageTokenSnapshot
    {
        guard provider == .codex || provider == .claude || provider == .vertexai else {
            throw CostUsageError.unsupportedProvider(provider)
        }

        let until = now
        // Rolling window: last 30 days (inclusive). Use -29 for inclusive boundaries.
        let since = Calendar.current.date(byAdding: .day, value: -29, to: now) ?? now

        var options = CostUsageScanner.Options()
        options.codexSessionsRoot = codexSessionsRoot
        options.claudeProjectsRoots = claudeProjectsRoots
        // Isolate on-disk cost cache per Codex credentials tree. Otherwise switching accounts within the
        // refresh TTL reuses the previous account's aggregated cache and shows identical totals.
        if provider == .codex {
            options.cacheRoot = Self.codexCostCacheParentURL(forSessionsRoot: codexSessionsRoot)
        }
        if provider == .vertexai {
            options.claudeLogProviderFilter = allowVertexClaudeFallback ? .all : .vertexAIOnly
        } else if provider == .claude {
            options.claudeLogProviderFilter = .excludeVertexAI
        }
        if forceRefresh {
            options.refreshMinIntervalSeconds = 0
            options.forceRescan = true
        }
        var daily = CostUsageScanner.loadDailyReport(
            provider: provider,
            since: since,
            until: until,
            now: now,
            options: options)

        if provider == .vertexai,
           !allowVertexClaudeFallback,
           options.claudeLogProviderFilter == .vertexAIOnly,
           daily.data.isEmpty
        {
            var fallback = options
            fallback.claudeLogProviderFilter = .all
            daily = CostUsageScanner.loadDailyReport(
                provider: provider,
                since: since,
                until: until,
                now: now,
                options: fallback)
        }

        return Self.tokenSnapshot(from: daily, now: now)
    }

    /// Parent directory for `cost-usage/` (see `CostUsageCacheIO`). `nil` = default `~/Library/Caches/CodexBar/`.
    private static func codexCostCacheParentURL(forSessionsRoot sessionsRoot: URL?) -> URL? {
        guard let sessionsRoot else { return nil }
        let tag = Self.stablePathFingerprint(sessionsRoot.path)
        return Self.defaultCodexBarCachesParent()
            .appendingPathComponent("codex-sessions-\(tag)", isDirectory: true)
    }

    private static func defaultCodexBarCachesParent() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
    }

    /// Stable short id for a filesystem path (FNV-1a 64-bit).
    private static func stablePathFingerprint(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_003
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    static func tokenSnapshot(from daily: CostUsageDailyReport, now: Date) -> CostUsageTokenSnapshot {
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
