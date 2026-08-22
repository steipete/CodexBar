import Foundation

// swiftlint:disable file_length

public enum CostUsageError: LocalizedError, Sendable {
    case unsupportedProvider(UsageProvider)
    case timedOut(seconds: Int)
    case cursorPaginationIncomplete(expected: Int?, received: Int)
    case cursorPaginationInconsistent(expected: Int, received: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "Cost summary is not supported for \(provider.rawValue)."
        case let .timedOut(seconds):
            if seconds >= 60, seconds % 60 == 0 {
                return "Cost refresh timed out after \(seconds / 60)m."
            }
            return "Cost refresh timed out after \(seconds)s."
        case let .cursorPaginationIncomplete(expected, received):
            if let expected {
                return "Cursor cost refresh was incomplete (received \(received) of \(expected) events)."
            }
            return "Cursor cost refresh reached its pagination safety limit after \(received) events."
        case let .cursorPaginationInconsistent(expected, received):
            return "Cursor cost pagination was inconsistent (expected \(expected), received \(received) events)."
        }
    }
}

// swiftlint:disable:next type_body_length
public struct CostUsageFetcher: Sendable {
    private static let codexAutomaticScanDurationPerRefresh: TimeInterval = 2

    package struct CachedCodexTokenSnapshotResult: Sendable {
        package let snapshot: CostUsageTokenSnapshot
        package let lastRefreshAt: Date?
        package let staleSnapshotUpdatedAt: Date?
    }

    package struct CodexScanCatchUpStatus: Sendable, Equatable {
        package let pending: Bool
        package let progressKey: String
        package let processedBytes: Int64
        package let totalBytes: Int64
        package let completedFiles: Int
        package let totalFiles: Int
        package let staleSnapshotUpdatedAt: Date?

        package init(
            pending: Bool,
            progressKey: String,
            processedBytes: Int64 = 0,
            totalBytes: Int64 = 0,
            completedFiles: Int = 0,
            totalFiles: Int = 0,
            staleSnapshotUpdatedAt: Date? = nil)
        {
            self.pending = pending
            self.progressKey = progressKey
            self.processedBytes = max(0, processedBytes)
            self.totalBytes = max(0, totalBytes)
            self.completedFiles = max(0, completedFiles)
            self.totalFiles = max(0, totalFiles)
            self.staleSnapshotUpdatedAt = staleSnapshotUpdatedAt
        }
    }

    private let scannerOptions: CostUsageScanner.Options?

    public init(cacheRoot: URL? = nil, calendar: Calendar? = nil) {
        if cacheRoot == nil, calendar == nil {
            self.scannerOptions = nil
        } else {
            var options = CostUsageScanner.Options()
            options.cacheRoot = cacheRoot
            options.cliProxyAPIHome = Self.defaultCLIProxyAPIHome()
            if let calendar {
                options.calendar = calendar
            }
            self.scannerOptions = options
        }
    }

    init(scannerOptions: CostUsageScanner.Options) {
        self.scannerOptions = scannerOptions
    }

    public func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        calendar: Calendar? = nil) async -> CostUsageTokenSnapshot?
    {
        await Self.loadCachedCodexTokenSnapshot(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            scannerOptions: self.scannerOptions(calendar: calendar))
    }

    package func loadCachedCodexTokenActivity(
        now: Date = Date(),
        codexHomePath: String? = nil,
        maximumDays: Int = 365,
        calendar: Calendar? = nil) async -> CostUsageTokenActivityCache?
    {
        await Self.loadCachedCodexTokenActivity(
            now: now,
            codexHomePath: codexHomePath,
            maximumDays: maximumDays,
            scannerOptions: self.scannerOptions(calendar: calendar))
    }

    package func loadCachedCodexTokenSnapshotResult(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        calendar: Calendar? = nil) async -> CachedCodexTokenSnapshotResult?
    {
        await Self.loadCachedCodexTokenSnapshotResult(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            scannerOptions: self.scannerOptions(calendar: calendar))
    }

    package func loadCachedCodexTokenSnapshotForScopedHome(
        now: Date = Date(),
        codexHomePath: String,
        historyDays: Int = 30,
        includePiSessions: Bool = false,
        includeProjectAndSessionBreakdowns: Bool = false,
        calendar: Calendar? = nil) async -> CostUsageTokenSnapshot?
    {
        await Self.loadCachedCodexTokenSnapshot(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            allowScopedCodexHome: true,
            includePiSessions: includePiSessions,
            includeProjectAndSessionBreakdowns: includeProjectAndSessionBreakdowns,
            scannerOptions: self.scannerOptions(calendar: calendar))
    }

    public func loadCachedCodexLocalProjectUsageSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        hidePersonalInfo: Bool) async -> CodexLocalProjectUsageSnapshot?
    {
        await Self.loadCachedCodexLocalProjectUsageSnapshot(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            hidePersonalInfo: hidePersonalInfo,
            scannerOptions: self.scannerOptionsOverride())
    }

    public func loadCodexLocalProjectUsageSnapshot(
        now: Date = Date(),
        forceRefresh: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        hidePersonalInfo: Bool,
        progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)? = nil)
        async throws -> CodexLocalProjectUsageSnapshot
    {
        try await Self.loadCodexLocalProjectUsageSnapshot(
            now: now,
            forceRefresh: forceRefresh,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            hidePersonalInfo: hidePersonalInfo,
            progress: progress,
            scannerOptions: self.scannerOptionsOverride())
    }

    public func clearCachedCodexLocalProjectUsageSnapshot(codexHomePath: String? = nil) async {
        await Self.clearCachedCodexLocalProjectUsageSnapshot(
            codexHomePath: codexHomePath,
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
        cursorCookieHeaderOverride: String? = nil,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true,
        includePiSessions: Bool = true,
        includeClaudeProxyUsage: Bool = true) async throws -> CostUsageTokenSnapshot
    {
        try await Self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            cursorCookieHeaderOverride: cursorCookieHeaderOverride,
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground,
            includePiSessions: includePiSessions,
            includeClaudeProxyUsage: includeClaudeProxyUsage,
            bypassScannerDebounce: false,
            scannerOptions: self.scannerOptionsOverride())
    }

    package func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        cursorCookieHeaderOverride: String? = nil,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true,
        includePiSessions: Bool = true,
        includeClaudeProxyUsage: Bool = true,
        bypassScannerDebounce: Bool,
        calendar: Calendar? = nil) async throws -> CostUsageTokenSnapshot
    {
        let options = self.resolvedTokenSnapshotScannerOptions(
            provider: provider,
            codexHomePath: codexHomePath,
            calendar: calendar)
        return try await Self.loadTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            forceRefresh: forceRefresh,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            cursorCookieHeaderOverride: cursorCookieHeaderOverride,
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground,
            includePiSessions: includePiSessions,
            includeClaudeProxyUsage: includeClaudeProxyUsage,
            bypassScannerDebounce: bypassScannerDebounce,
            scannerOptions: options)
    }

    package func loadCodexProxyTokenSnapshot(
        now: Date = Date(),
        forceRefresh: Bool = false,
        historyDays: Int = 30,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true) async throws -> CostUsageTokenSnapshot
    {
        try await self.loadCodexProxyTokenSnapshot(
            now: now,
            forceRefresh: forceRefresh,
            historyDays: historyDays,
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground,
            modelsDevClient: ModelsDevClient())
    }

    func loadCodexProxyTokenSnapshot(
        now: Date,
        forceRefresh: Bool,
        historyDays: Int = 30,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool,
        modelsDevClient: ModelsDevClient) async throws -> CostUsageTokenSnapshot
    {
        try await Self.loadCodexProxyTokenSnapshot(CodexProxyTokenSnapshotOptions(
            now: now,
            forceRefresh: forceRefresh,
            historyDays: historyDays,
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground,
            scannerOptions: self.scannerOptionsOverride(),
            modelsDevClient: modelsDevClient,
            retryUnknownPricing: true))
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
        allowPricingRefresh: Bool = true,
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
            allowPricingRefresh: allowPricingRefresh,
            refreshPricingInBackground: refreshPricingInBackground)
    }

    func scannerOptionsOverride() -> CostUsageScanner.Options? {
        self.scannerOptions
    }

    func scannerOptions(calendar: Calendar?) -> CostUsageScanner.Options? {
        guard calendar != nil || self.scannerOptions != nil else { return self.scannerOptions }
        var options = Self.resolvedScannerOptions(
            self.scannerOptions,
            provider: .codex,
            codexHomePath: nil)
        if let calendar {
            options.calendar = calendar
        }
        return options
    }

    func resolvedTokenSnapshotScannerOptions(
        provider: UsageProvider,
        codexHomePath: String?,
        calendar: Calendar?) -> CostUsageScanner.Options
    {
        var options = Self.resolvedScannerOptions(
            self.scannerOptionsOverride(),
            provider: provider,
            codexHomePath: codexHomePath)
        if let calendar {
            options.calendar = calendar
        }
        return options
    }

    package func cliProxyAPIConfigurationGeneration() -> String? {
        let options = Self.resolvedScannerOptions(
            self.scannerOptionsOverride(),
            provider: .codex,
            codexHomePath: nil)
        return CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(stateRoot: options.cacheRoot)
    }

    package func codexScanCatchUpStatus(
        codexHomePath: String? = nil,
        calendar: Calendar? = nil) async -> CodexScanCatchUpStatus
    {
        // Provider-specific by design: Codex exposes bounded background catch-up for its incremental JSONL scanner.
        let options = Self.resolvedScannerOptions(
            self.scannerOptions(calendar: calendar),
            provider: .codex,
            codexHomePath: codexHomePath)
        return await (try? CostUsageScanExecutor.run { checkCancellation in
            try checkCancellation()
            return Self.codexScanCatchUpStatus(options: options)
        }) ?? CodexScanCatchUpStatus(pending: false, progressKey: "unavailable")
    }

    package func advanceCodexScanCatchUp(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        calendar: Calendar? = nil) async throws -> CodexScanCatchUpStatus
    {
        var options = Self.resolvedScannerOptions(
            self.scannerOptions(calendar: calendar),
            provider: .codex,
            codexHomePath: codexHomePath)
        options.forceRescan = false
        options.refreshMinIntervalSeconds = 0
        options.maxCodexScanDurationPerRefresh = Self.codexAutomaticScanDurationPerRefresh
        let clampedHistoryDays = max(1, min(365, historyDays))
        let since = options.calendar.date(
            byAdding: .day,
            value: -(clampedHistoryDays - 1),
            to: now) ?? now
        let scanOptions = options
        // Provider-specific by design: this catch-up step advances only the Codex incremental scanner.
        return try await CostUsageScanExecutor.run { checkCancellation in
            _ = try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex,
                since: since,
                until: now,
                now: now,
                options: scanOptions,
                checkCancellation: checkCancellation)
            try checkCancellation()
            return Self.codexScanCatchUpStatus(options: scanOptions)
        }
    }

    private static func codexScanCatchUpStatus(
        options: CostUsageScanner.Options) -> CodexScanCatchUpStatus
    {
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
        let rootsFingerprint = CostUsageScanner.codexRootsFingerprint(options: options)
        let cache = CostUsageStoreAccess.read(
            cacheRoot: options.cacheRoot,
            calendar: options.calendar)
        guard cache.roots == rootsFingerprint else {
            return CodexScanCatchUpStatus(pending: false, progressKey: "scope-mismatch")
        }

        let scoped = CostUsageScanner.codexCache(cache, scopedTo: roots)
        let progressKey = self.codexScanProgressKey(cache: cache, scopedFiles: scoped.files)
        let hasIncompleteFile = scoped.files.values.contains {
            $0.codexScanComplete == false || $0.hasBufferedCodexForkRetryLines
        }
        let pending = cache.codexScanCatchUpPending == true || hasIncompleteFile
        return CodexScanCatchUpStatus(
            pending: pending,
            progressKey: progressKey,
            processedBytes: cache.codexScanProcessedBytes ?? 0,
            totalBytes: cache.codexScanTotalBytes ?? 0,
            completedFiles: cache.codexScanCompletedFiles ?? 0,
            totalFiles: cache.codexScanTotalFiles ?? 0,
            staleSnapshotUpdatedAt: pending ? cache.codexPreviousReport?.updatedAt : nil)
    }

    private static func codexHistoryCoverageIsEstablished(
        options: CostUsageScanner.Options) -> Bool
    {
        let status = self.codexScanCatchUpStatus(options: options)
        return !status.pending && status.progressKey != "scope-mismatch"
    }

    private static let establishedEmptyCodexDailyReport = CostUsageDailyReport(data: [], summary: nil)

    private static func codexCachedHistoryCoverageIsEstablished(
        cache: CostUsageCache,
        range: CostUsageScanner.CostUsageDayRange,
        rootsFingerprint: [String: Int64]) -> Bool
    {
        guard cache.lastScanUnixMs > 0,
              cache.timeZoneIdentifier == range.calendar.timeZone.identifier,
              cache.roots == rootsFingerprint,
              cache.codexScanCatchUpPending != true,
              !cache.files.values.contains(where: {
                  $0.codexScanComplete == false || $0.hasBufferedCodexForkRetryLines
              }),
              !CostUsageScanner.requestedWindowExpandsCache(range: range, cache: cache)
        else { return false }
        return true
    }

    static func resolvedScannerOptions(
        _ override: CostUsageScanner.Options?,
        provider: UsageProvider,
        codexHomePath: String?) -> CostUsageScanner.Options
    {
        var options = override ?? CostUsageScanner.Options()
        if override == nil {
            options.cliProxyAPIHome = Self.defaultCLIProxyAPIHome()
        }
        // Provider-specific by design: Codex managed profiles relocate sessions and archived_sessions roots.
        if provider == .codex,
           let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            options.codexSessionsRoot = URL(fileURLWithPath: codexHomePath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return options
    }

    static func defaultScannerOptions(
        cacheRoot: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CostUsageScanner.Options?
    {
        cacheRoot.map {
            CostUsageScanner.Options(
                cacheRoot: $0,
                cliProxyAPIHome: Self.defaultCLIProxyAPIHome(homeDirectory: homeDirectory))
        }
    }

    private static func defaultCLIProxyAPIHome(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        homeDirectory.appendingPathComponent(".cli-proxy-api", isDirectory: true)
    }

    static func loadTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        forceRefresh: Bool = false,
        allowVertexClaudeFallback: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        cursorCookieHeaderOverride: String? = nil,
        allowPricingRefresh: Bool = true,
        refreshPricingInBackground: Bool = true,
        includePiSessions: Bool = true,
        includeClaudeProxyUsage: Bool = true,
        bypassScannerDebounce: Bool = false,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil,
        piScannerOptions overridePiScannerOptions: PiSessionCostScanner
            .Options? = nil,
        modelsDevClient: ModelsDevClient = ModelsDevClient(),
        retryUnknownPricing: Bool = true) async throws -> CostUsageTokenSnapshot
    {
        guard self.supportsTokenSnapshot(provider) else {
            throw CostUsageError.unsupportedProvider(provider)
        }

        let clampedHistoryDays = max(1, min(365, historyDays))

        if let remoteSnapshot = try await self.loadRemoteTokenSnapshot(
            provider: provider,
            environment: environment,
            now: now,
            historyDays: clampedHistoryDays,
            cursorCookieHeaderOverride: cursorCookieHeaderOverride)
        {
            return remoteSnapshot
        }

        var options = Self.resolvedScannerOptions(
            overrideScannerOptions,
            provider: provider,
            codexHomePath: codexHomePath)
        let cliProxyAPIAttributionEnabled = Self.isCLIProxyAPIAttributionEnabled(options: options)
        if !cliProxyAPIAttributionEnabled {
            options.cliProxyAPIHome = nil
        }
        // Rolling window is inclusive, so a 30-day display starts 29 days before `now`.
        let since = options.calendar.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now
        let scopedCodexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Provider-specific by design: scoped Codex homes exclude ambient Pi sessions from managed-profile totals.
        let shouldMergeGlobalCodexUsage = provider != .codex || scopedCodexHomePath?.isEmpty != false
        await Self.refreshPricingIfAllowed(
            options: PricingRefreshOptions(
                provider: provider,
                isAllowed: allowPricingRefresh,
                retryUnknown: retryUnknownPricing,
                inBackground: refreshPricingInBackground),
            now: now,
            cacheRoot: options.cacheRoot,
            client: modelsDevClient)

        Self.configureScannerRefresh(
            &options,
            provider: provider,
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            forceRefresh: forceRefresh,
            bypassScannerDebounce: bypassScannerDebounce)
        // Provider-specific by design: Claude's view excludes rows reassigned to the Codex proxy source.
        if provider == .claude {
            options.claudeAttributionFilter = cliProxyAPIAttributionEnabled ? .excludeCodexBackend : .all
        }
        var resolvedPiOptions = overridePiScannerOptions ?? PiSessionCostScanner.Options()
        if resolvedPiOptions.cacheRoot == nil {
            resolvedPiOptions.cacheRoot = options.cacheRoot
        }
        resolvedPiOptions.calendar = options.calendar
        if forceRefresh || bypassScannerDebounce {
            resolvedPiOptions.refreshMinIntervalSeconds = 0
        }
        let piOptions = resolvedPiOptions

        let scanOptions = options
        let localScanOptions = LocalTokenScanOptions(
            allowVertexClaudeFallback: allowVertexClaudeFallback,
            includePiSessions: includePiSessions,
            includeClaudeProxyUsage: includeClaudeProxyUsage,
            shouldMergeGlobalCodexUsage: shouldMergeGlobalCodexUsage,
            scanOptions: scanOptions,
            piOptions: piOptions)
        let scanResult = try await Self.loadLocalTokenScanResult(
            provider: provider,
            since: since,
            now: now,
            options: localScanOptions)

        if allowPricingRefresh,
           retryUnknownPricing,
           let request = Self.unknownPricingRefreshRequest(
               provider: provider,
               daily: scanResult.daily,
               now: now,
               cacheRoot: options.cacheRoot,
               client: modelsDevClient),
           await Self.refreshUnknownPricingIfNeeded(request, inBackground: refreshPricingInBackground)
        {
            return try await self.loadTokenSnapshot(
                provider: provider,
                environment: environment,
                now: now,
                forceRefresh: forceRefresh,
                allowVertexClaudeFallback: allowVertexClaudeFallback,
                codexHomePath: codexHomePath,
                historyDays: historyDays,
                cursorCookieHeaderOverride: cursorCookieHeaderOverride,
                allowPricingRefresh: allowPricingRefresh,
                refreshPricingInBackground: false,
                includePiSessions: includePiSessions,
                includeClaudeProxyUsage: includeClaudeProxyUsage,
                scannerOptions: options,
                piScannerOptions: piOptions,
                modelsDevClient: modelsDevClient,
                retryUnknownPricing: false)
        }

        return Self.tokenSnapshot(
            from: scanResult.daily,
            now: now,
            historyDays: clampedHistoryDays,
            calendar: scanOptions.calendar,
            historyCoverageIsEstablished: scanResult.historyCoverageIsEstablished,
            costProvenance: .listPriceEstimate,
            projects: scanResult.projects,
            sessions: scanResult.sessions,
            updatedAt: scanResult.staleSnapshotUpdatedAt)
    }

    private struct LocalTokenScanResult: Sendable {
        let daily: CostUsageDailyReport
        let projects: [CostUsageProjectBreakdown]
        let sessions: [CostUsageSessionBreakdown]
        let staleSnapshotUpdatedAt: Date?
        let historyCoverageIsEstablished: Bool
    }

    private struct LocalTokenScanOptions: Sendable {
        let allowVertexClaudeFallback: Bool
        let includePiSessions: Bool
        let includeClaudeProxyUsage: Bool
        let shouldMergeGlobalCodexUsage: Bool
        let scanOptions: CostUsageScanner.Options
        let piOptions: PiSessionCostScanner.Options
    }

    private static func loadLocalTokenScanResult(
        provider: UsageProvider,
        since: Date,
        now: Date,
        options: LocalTokenScanOptions) async throws -> LocalTokenScanResult
    {
        try Task.checkCancellation()
        // Provider-specific by design: Codex owns project/session attribution and optional Pi merge state, while
        // Claude/Vertex share the transcript scanner with mutually exclusive filters.
        // These synchronous scans can run for minutes on large archives. The dedicated queue keeps
        // them off the cooperative pool and bridges task cancellation into scanner-level checks.
        return try await CostUsageScanExecutor.run { checkCancellation in
            var daily = try CostUsageScanner.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: now,
                now: now,
                options: options.scanOptions,
                checkCancellation: checkCancellation)
            try checkCancellation()

            if provider == .vertexai,
               !options.allowVertexClaudeFallback,
               options.scanOptions.claudeLogProviderFilter == .vertexAIOnly,
               daily.data.isEmpty
            {
                var fallback = options.scanOptions
                fallback.claudeLogProviderFilter = .all
                daily = try CostUsageScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: now,
                    now: now,
                    options: fallback,
                    checkCancellation: checkCancellation)
                try checkCancellation()
            }

            var projects: [CostUsageProjectBreakdown] = []
            var sessions: [CostUsageSessionBreakdown] = []
            var piDaily: CostUsageDailyReport?
            var claudeProxyDaily: CostUsageDailyReport?
            var staleSnapshotUpdatedAt: Date?
            if provider == .codex {
                let roots = CostUsageScanner.codexSessionsRoots(options: options.scanOptions)
                let cache = CostUsageScanner.codexCache(
                    CostUsageStoreAccess.read(
                        cacheRoot: options.scanOptions.cacheRoot,
                        calendar: options.scanOptions.calendar),
                    scopedTo: roots)
                let range = CostUsageScanner.CostUsageDayRange(
                    since: since, until: now, calendar: options.scanOptions.calendar)
                let supplemental = try Self.loadCodexSupplementalScan(
                    options: options.scanOptions,
                    range: range,
                    now: now,
                    includeClaudeProxy: options.includeClaudeProxyUsage
                        && options.shouldMergeGlobalCodexUsage,
                    checkCancellation: checkCancellation)
                claudeProxyDaily = supplemental.claudeProxyDaily
                daily = claudeProxyDaily.map { daily.merged(with: $0) } ?? daily
                if let previous = CostUsageScanner.codexPreviousReport(
                    cache: cache,
                    range: range,
                    rootsFingerprint: CostUsageScanner.codexRootsFingerprint(options: options.scanOptions))
                {
                    staleSnapshotUpdatedAt = previous.updatedAt
                } else {
                    projects = supplemental.projects
                    sessions = supplemental.sessions
                }
            }
            if options.includePiSessions,
               provider == .claude || (provider == .codex && options.shouldMergeGlobalCodexUsage)
            {
                let piReport = try PiSessionCostScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: since,
                    until: now,
                    now: now,
                    options: options.piOptions,
                    checkCancellation: checkCancellation)
                try checkCancellation()
                if provider == .codex {
                    piDaily = piReport
                }
                daily = CostUsageDailyReport.merged([daily, piReport])
            }
            if provider == .codex {
                let finalized = Self.finalizeCodexSupplementalScan(
                    projects: projects,
                    sessions: sessions,
                    claudeProxyDaily: claudeProxyDaily,
                    piDaily: piDaily)
                projects = finalized.projects
                sessions = finalized.sessions
            }
            return LocalTokenScanResult(
                daily: daily,
                projects: projects,
                sessions: sessions,
                staleSnapshotUpdatedAt: staleSnapshotUpdatedAt,
                // Provider-specific by design: Codex alone tracks whether its supplemental history is complete.
                historyCoverageIsEstablished: provider != .codex
                    || Self.codexHistoryCoverageIsEstablished(options: options.scanOptions))
        }
    }

    private struct PricingRefreshOptions: Sendable {
        let provider: UsageProvider
        let isAllowed: Bool
        let retryUnknown: Bool
        let inBackground: Bool
    }

    private static func refreshPricingIfAllowed(
        options: PricingRefreshOptions,
        now: Date,
        cacheRoot: URL?,
        client: ModelsDevClient) async
    {
        guard options.isAllowed,
              options.retryUnknown,
              options.provider == .codex || options.provider == .claude
        else { return }

        if options.inBackground {
            Task.detached(priority: .utility) {
                await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot, client: client)
            }
        } else {
            await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot, client: client)
        }
    }

    private struct ModelsDevPricingTarget: Hashable, Sendable {
        let providerID: String
        let modelID: String
    }

    private struct UnknownPricingRefreshRequest: Sendable {
        let targets: Set<ModelsDevPricingTarget>
        let now: Date
        let cacheRoot: URL?
        let client: ModelsDevClient
    }

    private static func unknownPricingRefreshRequest(
        provider: UsageProvider,
        daily: CostUsageDailyReport,
        now: Date,
        cacheRoot: URL?,
        client: ModelsDevClient) -> UnknownPricingRefreshRequest?
    {
        guard provider == .codex || provider == .claude else { return nil }
        var targets = Set<ModelsDevPricingTarget>()
        for entry in daily.data {
            for breakdown in entry.modelBreakdowns ?? [] {
                guard breakdown.costUSD == nil else { continue }
                if breakdown.attribution?.route == .cliProxyAPI,
                   let upstreamModel = breakdown.attribution?.upstream?.model?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                       !upstreamModel.isEmpty
                {
                    for target in CostUsagePricing.claudeModelsDevPricingTargets(for: upstreamModel) {
                        targets.insert(ModelsDevPricingTarget(
                            providerID: target.providerID,
                            modelID: target.modelID))
                    }
                    continue
                }
                // Provider-specific by design: non-proxy Codex rows use the native OpenAI pricing route.
                if provider == .codex {
                    guard OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: breakdown.modelName)
                    else { continue }
                    guard !CostUsagePricing.isCodexUnattributedModel(breakdown.modelName) else { continue }
                    for target in CostUsagePricing.codexModelsDevPricingTargets(for: breakdown.modelName) {
                        targets.insert(ModelsDevPricingTarget(providerID: target.providerID, modelID: target.modelID))
                    }
                } else {
                    for target in CostUsagePricing.claudeModelsDevPricingTargets(for: breakdown.modelName) {
                        targets.insert(ModelsDevPricingTarget(
                            providerID: target.providerID,
                            modelID: target.modelID))
                    }
                }
            }
        }
        guard !targets.isEmpty else { return nil }

        return UnknownPricingRefreshRequest(
            targets: targets,
            now: now,
            cacheRoot: cacheRoot,
            client: client)
    }

    private static func refreshUnknownPricingIfNeeded(
        _ request: UnknownPricingRefreshRequest,
        inBackground: Bool) async -> Bool
    {
        func refreshTargets() async -> Bool {
            let targetsByProvider = Dictionary(grouping: request.targets, by: \.providerID)
            for providerID in targetsByProvider.keys.sorted() {
                let modelIDs = Set(targetsByProvider[providerID, default: []].map(\.modelID))
                let outcome = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
                    providerID: providerID,
                    modelIDs: modelIDs,
                    now: request.now,
                    cacheRoot: request.cacheRoot,
                    client: request.client)
                if outcome == .pricingAvailable {
                    return true
                }
            }
            return false
        }

        if inBackground {
            Task.detached(priority: .utility) {
                _ = await refreshTargets()
            }
            return false
        }
        return await refreshTargets()
    }

    static func loadCachedCodexTokenSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        allowScopedCodexHome: Bool = false,
        includePiSessions: Bool = true,
        includeProjectAndSessionBreakdowns: Bool = true,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async -> CostUsageTokenSnapshot?
    {
        await self.loadCachedCodexTokenSnapshotResult(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            allowScopedCodexHome: allowScopedCodexHome,
            includePiSessions: includePiSessions,
            includeProjectAndSessionBreakdowns: includeProjectAndSessionBreakdowns,
            scannerOptions: overrideScannerOptions)?.snapshot
    }

    static func loadCachedCodexTokenActivity(
        now: Date = Date(),
        codexHomePath: String? = nil,
        maximumDays: Int = 365,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async
        -> CostUsageTokenActivityCache?
    {
        let cachedActivity: CostUsageTokenActivityCache?? = try? await CostUsageScanExecutor.run { _ in
            let options = Self.resolvedScannerOptions(
                overrideScannerOptions,
                provider: .codex,
                codexHomePath: codexHomePath)
            let days = max(1, min(365, maximumDays))
            let since = options.calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now
            let requestedRange = CostUsageScanner.CostUsageDayRange(
                since: since,
                until: now,
                calendar: options.calendar)
            let roots = CostUsageScanner.codexSessionsRoots(options: options)
            let rootsFingerprint = CostUsageScanner.codexRootsFingerprint(options: options)
            let cache = CostUsageScanner.codexCache(
                CostUsageStoreAccess.read(
                    cacheRoot: options.cacheRoot,
                    calendar: options.calendar),
                scopedTo: roots)
            guard cache.timeZoneIdentifier == options.calendar.timeZone.identifier,
                  cache.roots == rootsFingerprint,
                  cache.codexScanCatchUpPending != true,
                  !cache.files.values.contains(where: {
                      $0.codexScanComplete == false || $0.hasBufferedCodexForkRetryLines
                  }),
                  let cachedSince = cache.scanSinceKey,
                  let cachedUntil = cache.scanUntilKey
            else { return nil }

            let coverageSince = max(cachedSince, requestedRange.scanSinceKey)
            let coverageUntil = min(cachedUntil, requestedRange.scanUntilKey)
            guard coverageSince <= coverageUntil else { return nil }
            let daily = cache.days.keys
                .filter { $0 >= coverageSince && $0 <= coverageUntil }
                .sorted()
                .map { day -> CostUsageDailyReport.Entry in
                    var total = 0
                    for (model, packed) in cache.days[day, default: [:]] {
                        guard OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: model) else {
                            continue
                        }
                        for value in [packed[safe: 0] ?? 0, packed[safe: 2] ?? 0] {
                            let addition = total.addingReportingOverflow(max(0, value))
                            total = addition.overflow ? Int.max : addition.partialValue
                        }
                    }
                    return CostUsageDailyReport.Entry(
                        date: day,
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: total,
                        costUSD: nil,
                        modelsUsed: nil,
                        modelBreakdowns: nil)
                }
            return CostUsageTokenActivityCache(
                daily: daily,
                coverageSinceKey: coverageSince,
                coverageUntilKey: coverageUntil)
        }
        return cachedActivity.flatMap(\.self)
    }

    static func loadCachedCodexTokenSnapshotResult(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        allowScopedCodexHome: Bool = false,
        includePiSessions: Bool = true,
        includeProjectAndSessionBreakdowns: Bool = true,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async
        -> CachedCodexTokenSnapshotResult?
    {
        let scopedCodexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if scopedCodexHomePath?.isEmpty == false, !allowScopedCodexHome {
            return nil
        }

        // Snapshot assembly can touch many SQLite rows; keep it off the cooperative pool
        // alongside the scans themselves.
        let cachedSnapshot: CachedCodexTokenSnapshotResult?? = try? await CostUsageScanExecutor
            .run { checkCancellation in
                let clampedHistoryDays = max(1, min(365, historyDays))
                let options = Self.resolvedScannerOptions(
                    overrideScannerOptions,
                    provider: .codex,
                    codexHomePath: codexHomePath)
                let until = now
                let since = options.calendar.date(
                    byAdding: .day,
                    value: -(clampedHistoryDays - 1),
                    to: now) ?? now
                let range = CostUsageScanner.CostUsageDayRange(
                    since: since,
                    until: until,
                    calendar: options.calendar)
                let shouldMergePiUsage = scopedCodexHomePath?.isEmpty != false
                let roots = CostUsageScanner.codexSessionsRoots(options: options)
                let rootsFingerprint = CostUsageScanner.codexRootsFingerprint(options: options)
                let loadedCache = CostUsageStoreAccess.read(
                    cacheRoot: options.cacheRoot,
                    calendar: options.calendar)
                let cache = CostUsageScanner.codexCache(
                    loadedCache,
                    scopedTo: roots)
                var reports: [CostUsageDailyReport] = []
                var projects: [CostUsageProjectBreakdown] = []
                var sessions: [CostUsageSessionBreakdown] = []
                // Raw inputs for the derived result fields below: the native cache's own scan
                // time, every constituent scan time, and whether a second source joined the merge.
                var nativeScanAt: Date?
                var scanTimes: [Date] = []
                var piMerged = false
                var claudeProxyMerged = false
                var staleSnapshotUpdatedAt: Date?
                let nativeHistoryCoverageIsEstablished = Self.codexCachedHistoryCoverageIsEstablished(
                    cache: cache,
                    range: range,
                    rootsFingerprint: rootsFingerprint)

                if let previous = CostUsageScanner.codexPreviousReport(
                    cache: cache,
                    range: range,
                    rootsFingerprint: rootsFingerprint)
                {
                    reports.append(previous.report)
                    staleSnapshotUpdatedAt = previous.updatedAt
                    if let updatedAt = previous.updatedAt {
                        scanTimes.append(updatedAt)
                    }
                } else if cache.timeZoneIdentifier == range.calendar.timeZone.identifier,
                          !cache.days.isEmpty,
                          cache.roots == rootsFingerprint,
                          !CostUsageScanner.requestedWindowExpandsCache(range: range, cache: cache)
                {
                    let daily = CostUsageScanner.buildCodexReportFromCache(
                        cache: cache,
                        range: range,
                        modelsDevCacheRoot: options.cacheRoot)
                    if !daily.data.isEmpty {
                        reports.append(daily)
                        if cache.lastScanUnixMs > 0 {
                            let scanAt = Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)
                            nativeScanAt = scanAt
                            scanTimes.append(scanAt)
                        }
                        if includeProjectAndSessionBreakdowns {
                            sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
                                cache: cache,
                                range: range,
                                modelsDevCacheRoot: options.cacheRoot,
                                sessionRoots: roots)
                            if cache.codexProjectMetadataVersion == CostUsageScanner.codexProjectMetadataVersion {
                                projects.append(contentsOf: CostUsageScanner.buildCodexProjectBreakdownsFromCache(
                                    cache: cache,
                                    range: range,
                                    modelsDevCacheRoot: options.cacheRoot))
                            }
                        }
                    }
                }

                // A completed scan can legitimately have no rows (a fresh account or a quiet
                // window). Keep that established-empty state across app restarts instead of
                // collapsing it back to "unavailable" merely because the cache has no day map.
                if reports.isEmpty, nativeHistoryCoverageIsEstablished {
                    reports.append(Self.establishedEmptyCodexDailyReport)
                    if cache.lastScanUnixMs > 0 {
                        let scanAt = Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)
                        nativeScanAt = scanAt
                        scanTimes.append(scanAt)
                    }
                }

                if shouldMergePiUsage,
                   let proxy = try Self.loadCachedCodexProxyReport(
                       options: options,
                       range: range,
                       now: now,
                       checkCancellation: checkCancellation)
                {
                    reports.append(proxy.report)
                    claudeProxyMerged = true
                    if let scanAt = proxy.scanAt {
                        scanTimes.append(scanAt)
                    }
                    if includeProjectAndSessionBreakdowns, let project = proxy.project {
                        projects.append(project)
                        sessions = []
                    }
                }

                if includePiSessions,
                   shouldMergePiUsage,
                   let piResult = PiSessionCostScanner.loadCachedDailyReportResult(
                       provider: .codex,
                       since: since,
                       until: until,
                       now: now,
                       cacheRoot: options.cacheRoot,
                       calendar: options.calendar)
                {
                    reports.append(piResult.report)
                    piMerged = true
                    if let piLastScanAt = piResult.lastScanAt {
                        scanTimes.append(piLastScanAt)
                    }
                    if includeProjectAndSessionBreakdowns,
                       let piProject = Self.unknownProjectBreakdown(from: piResult.report)
                    {
                        projects.append(piProject)
                    }
                    if includeProjectAndSessionBreakdowns, !piResult.report.data.isEmpty {
                        sessions = []
                    }
                }

                guard !reports.isEmpty else { return nil }
                // updatedAt keeps the caches' real (oldest) scan time; stamping the hydration time
                // would let stale token rows inherit app-start freshness (#1964). lastRefreshAt
                // drives TTL suppression and stays native-only: a merged load must never delay a
                // rescan on the strength of another source's scan.
                return CachedCodexTokenSnapshotResult(
                    snapshot: Self.tokenSnapshot(
                        from: CostUsageDailyReport.merged(reports),
                        now: now,
                        historyDays: clampedHistoryDays,
                        calendar: options.calendar,
                        historyCoverageIsEstablished: Self.codexHistoryCoverageIsEstablished(options: options),
                        costProvenance: .listPriceEstimate,
                        projects: Self.mergedProjectBreakdowns(projects),
                        sessions: sessions,
                        updatedAt: scanTimes.min()),
                    lastRefreshAt: piMerged || claudeProxyMerged || staleSnapshotUpdatedAt != nil ? nil : nativeScanAt,
                    staleSnapshotUpdatedAt: staleSnapshotUpdatedAt)
            }
        return cachedSnapshot.flatMap(\.self)
    }

    private static func loadCachedCodexProxyReport(
        options: CostUsageScanner.Options,
        range: CostUsageScanner.CostUsageDayRange,
        now: Date,
        checkCancellation: @escaping CostUsageScanner.CancellationCheck) throws -> (
        report: CostUsageDailyReport,
        scanAt: Date?,
        project: CostUsageProjectBreakdown?)?
    {
        guard self.isCLIProxyAPIAttributionEnabled(options: options) else { return nil }
        // Provider-specific by design: attributed proxy history is read from the Claude scanner's persistent cache.
        let claudeCache = CostUsageClaudeCacheIO.load(
            provider: .claude,
            cacheRoot: options.cacheRoot,
            calendar: range.calendar)
        guard !claudeCache.days.isEmpty,
              !CostUsageScanner.requestedWindowExpandsCache(range: range, cache: claudeCache)
        else { return nil }

        let attributionResolver: CLIProxyAPIAttributionResolver? = if let home = options.cliProxyAPIHome {
            try CLIProxyAPIAttributionResolver.load(
                home: home,
                cacheRoot: options.cacheRoot,
                forceReload: options.forceRescan,
                checkCancellation: checkCancellation)
        } else {
            nil
        }
        let report = CostUsageScanner.buildClaudeReportFromCache(
            cache: claudeCache,
            range: range,
            attributionFilter: .codexBackendOnly,
            attributionResolver: attributionResolver,
            modelsDevCatalog: CostUsagePricing.modelsDevCatalog(
                now: now,
                cacheRoot: options.cacheRoot),
            modelsDevCacheRoot: options.cacheRoot)
        guard !report.data.isEmpty else { return nil }

        let scanAt = claudeCache.lastScanUnixMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(claudeCache.lastScanUnixMs) / 1000)
            : nil
        return (
            report,
            scanAt,
            self.unknownProjectBreakdown(
                from: report,
                name: "Claude Code via CLIProxyAPI"))
    }

    /// Providers whose token-cost snapshot `loadTokenSnapshot` can produce. Cursor is
    /// macOS-only because it reuses the macOS Cursor session resolution.
    static func supportsTokenSnapshot(_ provider: UsageProvider) -> Bool {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenSnapshot
    }

    static func loadCachedCodexLocalProjectUsageSnapshot(
        now: Date = Date(),
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        hidePersonalInfo: Bool,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async -> CodexLocalProjectUsageSnapshot?
    {
        let cachedSnapshot: CodexLocalProjectUsageSnapshot?? = try? await CostUsageScanExecutor.run { _ in
            let options = Self.codexLocalScannerOptions(
                codexHomePath: codexHomePath,
                overrideScannerOptions: overrideScannerOptions)
            return CodexLocalProjectUsageIndexer.cachedSnapshot(
                now: now,
                historyDays: historyDays,
                options: CodexLocalProjectUsageIndexer.Options(scannerOptions: options))
        }
        return cachedSnapshot.flatMap(\.self)?.hidingPersonalInformation(hidePersonalInfo)
    }

    static func loadCodexLocalProjectUsageSnapshot(
        now: Date = Date(),
        forceRefresh: Bool = false,
        codexHomePath: String? = nil,
        historyDays: Int = 30,
        hidePersonalInfo: Bool,
        progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)? = nil,
        scannerOptions overrideScannerOptions: CostUsageScanner
            .Options? = nil) async throws -> CodexLocalProjectUsageSnapshot
    {
        let options = Self.codexLocalScannerOptions(
            codexHomePath: codexHomePath,
            overrideScannerOptions: overrideScannerOptions)
        let scanOptions = options
        let snapshot = try await CostUsageScanExecutor.run { checkCancellation in
            try CodexLocalProjectUsageIndexer.loadSnapshot(
                now: now,
                historyDays: historyDays,
                forceRefresh: forceRefresh,
                options: CodexLocalProjectUsageIndexer.Options(scannerOptions: scanOptions),
                progress: progress,
                checkCancellation: checkCancellation)
        }
        return snapshot.hidingPersonalInformation(hidePersonalInfo)
    }

    static func clearCachedCodexLocalProjectUsageSnapshot(
        codexHomePath: String? = nil,
        scannerOptions overrideScannerOptions: CostUsageScanner.Options? = nil) async
    {
        _ = try? await CostUsageScanExecutor.run { _ in
            let options = Self.codexLocalScannerOptions(
                codexHomePath: codexHomePath,
                overrideScannerOptions: overrideScannerOptions)
            CodexWorkspaceUsageSidecar(cacheRoot: options.cacheRoot).clear()
        }
    }

    private static func codexLocalScannerOptions(
        codexHomePath: String?,
        overrideScannerOptions: CostUsageScanner.Options?) -> CostUsageScanner.Options
    {
        var options = overrideScannerOptions ?? CostUsageScanner.Options()
        if let codexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHomePath.isEmpty
        {
            options.codexSessionsRoot = URL(fileURLWithPath: codexHomePath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return CodexLocalDataScope.resolve(options: options).applying(to: options)
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

    /// Snap a Cursor window start to the local day boundary so the dashboard query keeps full days.
    /// `since` arrives as the current instant N-1 days back, so a 1-day window would otherwise become
    /// an empty exact-instant range; snapping to 00:00 keeps all of today (and the first day's early
    /// hours for wider windows).
    static func cursorWindowStart(_ since: Date?, calendar: Calendar = .current) -> Date? {
        since.map { calendar.startOfDay(for: $0) }
    }

    #if os(macOS)
    /// Fetch Cursor's per-day token-cost plus its Cursor-metered total via the cookie-authenticated
    /// dashboard API, reusing the same session resolution as the Cursor status probe. Like Codex and
    /// Claude, the report covers the rolling `historyDays` window and the session line is tied to the
    /// current local day (so a stale latest entry is never labeled as Today).
    private static func loadCursorTokenSnapshot(
        now: Date,
        since: Date?,
        historyDays: Int,
        cookieHeaderOverride: String? = nil) async throws -> CostUsageTokenSnapshot
    {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection())
        // `since` arrives as the current instant N-1 days back; snap it to the local day boundary so
        // the dashboard query keeps the full first day (and all of today for a 1-day window) instead
        // of filtering out earlier events at the same time-of-day.
        let windowStart = Self.cursorWindowStart(since)
        let report = try await probe.fetchCostReport(
            since: windowStart,
            until: now,
            cookieHeaderOverride: cookieHeaderOverride)
        return Self.tokenSnapshot(
            from: report.daily,
            now: now,
            historyDays: historyDays,
            useCurrentLocalDayForSession: true,
            meteredCostUSD: report.meteredCostUSD,
            costProvenance: Self.cursorCostProvenance(
                meteredCostUSD: report.meteredCostUSD,
                daily: report.daily.data),
            credentialScopeFingerprint: report.credentialScopeFingerprint)
    }
    #endif

    static func tokenSnapshot(
        from daily: CostUsageDailyReport,
        now: Date,
        historyDays: Int = 30,
        useCurrentLocalDayForSession: Bool = true,
        calendar: Calendar = .current,
        historyCoverageIsEstablished: Bool = true,
        meteredCostUSD: Double? = nil,
        costProvenance: CostProvenance = .unknown,
        credentialScopeFingerprint: String? = nil,
        historyLabel: String? = nil,
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = [],
        updatedAt: Date? = nil) -> CostUsageTokenSnapshot
    {
        let sessionEntry = useCurrentLocalDayForSession
            ? CostUsageTokenSnapshot.entry(in: daily.data, forLocalDayContaining: now, calendar: calendar)
            : CostUsageTokenSnapshot.latestEntry(in: daily.data)
        let hasHistoricalRows = !daily.data.isEmpty
        let establishedEmptyHistory = historyCoverageIsEstablished && daily.data.isEmpty
        let sessionTokens: Int? = if let sessionEntry {
            sessionEntry.totalTokens
        } else if hasHistoricalRows {
            0
        } else if establishedEmptyHistory {
            0
        } else {
            nil
        }
        let sessionCostUSD: Double? = if let sessionEntry {
            sessionEntry.costUSD
        } else if hasHistoricalRows {
            0
        } else if establishedEmptyHistory {
            0
        } else {
            nil
        }
        // Prefer summary totals when present; fall back to summing daily entries. A non-empty
        // row set where every row carries an explicit value is a known total even when it sums
        // to zero; keep nil only for genuinely missing values.
        let totalFromSummary = daily.summary?.totalCostUSD
        let totalFromEntries = daily.data.compactMap(\.costUSD).reduce(0, +)
        let allEntriesCarryCost = !daily.data.isEmpty && daily.data.allSatisfy { $0.costUSD != nil }
        let last30DaysCostUSD = totalFromSummary
            ?? (allEntriesCarryCost
                ? totalFromEntries
                : establishedEmptyHistory ? 0 : nil)
        let totalTokensFromSummary = daily.summary?.totalTokens
        let totalTokensFromEntries = daily.data.compactMap(\.totalTokens).reduce(0, +)
        let allEntriesCarryTokens = !daily.data.isEmpty && daily.data.allSatisfy { $0.totalTokens != nil }
        let last30DaysTokens = totalTokensFromSummary
            ?? (allEntriesCarryTokens
                ? totalTokensFromEntries
                : establishedEmptyHistory ? 0 : nil)

        return CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: historyDays,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            historyLabel: historyLabel,
            meteredCostUSD: meteredCostUSD,
            costProvenance: costProvenance,
            credentialScopeFingerprint: credentialScopeFingerprint,
            daily: daily.data,
            projects: projects,
            sessions: sessions,
            updatedAt: updatedAt ?? now)
    }
}

extension CostUsageFetcher {
    private struct CodexProxyTokenSnapshotOptions {
        let now: Date
        let forceRefresh: Bool
        let historyDays: Int
        let allowPricingRefresh: Bool
        let refreshPricingInBackground: Bool
        let scannerOptions: CostUsageScanner.Options?
        let modelsDevClient: ModelsDevClient
        let retryUnknownPricing: Bool
    }

    private struct CodexSupplementalScan {
        let projects: [CostUsageProjectBreakdown]
        let sessions: [CostUsageSessionBreakdown]
        let claudeProxyDaily: CostUsageDailyReport?
    }

    private static func loadCodexProxyTokenSnapshot(
        _ request: CodexProxyTokenSnapshotOptions) async throws -> CostUsageTokenSnapshot
    {
        let clampedHistoryDays = max(1, min(365, request.historyDays))
        // Provider-specific by design: this loader publishes the synthetic proxy source in the Codex spend family.
        var options = Self.resolvedScannerOptions(
            request.scannerOptions,
            provider: .codex,
            codexHomePath: nil)
        let since = options.calendar.date(
            byAdding: .day,
            value: -(clampedHistoryDays - 1),
            to: request.now) ?? request.now
        await Self.refreshPricingIfAllowed(
            options: PricingRefreshOptions(
                provider: .codex,
                isAllowed: request.allowPricingRefresh,
                retryUnknown: request.retryUnknownPricing,
                inBackground: request.refreshPricingInBackground),
            now: request.now,
            cacheRoot: options.cacheRoot,
            client: request.modelsDevClient)
        if request.forceRefresh {
            options.refreshMinIntervalSeconds = 0
        }

        let scan = options
        let proxyDaily = try await CostUsageScanExecutor.run { checkCancellation in
            let range = CostUsageScanner.CostUsageDayRange(since: since, until: request.now, calendar: scan.calendar)
            let supplemental = try Self.loadCodexSupplementalScan(
                options: scan,
                range: range,
                now: request.now,
                includeClaudeProxy: true,
                checkCancellation: checkCancellation)
            return supplemental.claudeProxyDaily
        }
        let daily = proxyDaily ?? CostUsageDailyReport(data: [], summary: nil)
        let projects = proxyDaily.flatMap {
            Self.unknownProjectBreakdown(
                from: $0,
                name: "Claude Code via CLIProxyAPI")
        }.map { [$0] } ?? []
        if request.allowPricingRefresh,
           request.retryUnknownPricing,
           // Provider-specific by design: proxy rows are rendered under Codex while pricing follows their upstream.
           let refreshRequest = Self.unknownPricingRefreshRequest(
               provider: .codex,
               daily: daily,
               now: request.now,
               cacheRoot: options.cacheRoot,
               client: request.modelsDevClient),
           await Self.refreshUnknownPricingIfNeeded(
               refreshRequest,
               inBackground: request.refreshPricingInBackground)
        {
            return try await Self.loadCodexProxyTokenSnapshot(CodexProxyTokenSnapshotOptions(
                now: request.now,
                forceRefresh: request.forceRefresh,
                historyDays: request.historyDays,
                allowPricingRefresh: request.allowPricingRefresh,
                refreshPricingInBackground: false,
                scannerOptions: options,
                modelsDevClient: request.modelsDevClient,
                retryUnknownPricing: false))
        }
        return Self.tokenSnapshot(
            from: daily,
            now: request.now,
            historyDays: clampedHistoryDays,
            calendar: options.calendar,
            costProvenance: .listPriceEstimate,
            projects: projects)
    }

    private static func loadCodexSupplementalScan(
        options: CostUsageScanner.Options,
        range: CostUsageScanner.CostUsageDayRange,
        now: Date,
        includeClaudeProxy: Bool,
        checkCancellation: @escaping CostUsageScanner.CancellationCheck) throws -> CodexSupplementalScan
    {
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
        let cache = CostUsageScanner.codexCache(
            CostUsageStoreAccess.read(
                cacheRoot: options.cacheRoot,
                calendar: range.calendar),
            scopedTo: roots)
        let projects = CostUsageScanner.buildCodexProjectBreakdownsFromCache(
            cache: cache,
            range: range,
            modelsDevCacheRoot: options.cacheRoot)
        let sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: cache,
            range: range,
            modelsDevCacheRoot: options.cacheRoot,
            sessionRoots: roots)

        guard includeClaudeProxy,
              self.hasCodexProxyEvidence(options: options)
        else {
            return CodexSupplementalScan(
                projects: projects,
                sessions: sessions,
                claudeProxyDaily: nil)
        }
        var proxyOptions = options
        proxyOptions.claudeLogProviderFilter = .excludeVertexAI
        proxyOptions.claudeAttributionFilter = .codexBackendOnly
        // Provider-specific by design: the Codex projection reuses Claude transcripts filtered to proxy-owned rows.
        let proxyDaily = try CostUsageScanner.loadClaudeDaily(
            provider: .claude,
            range: range,
            now: now,
            options: proxyOptions,
            checkCancellation: checkCancellation)
        return CodexSupplementalScan(
            projects: projects,
            sessions: sessions,
            claudeProxyDaily: proxyDaily.data.isEmpty ? nil : proxyDaily)
    }

    static func hasCodexProxyEvidence(
        options: CostUsageScanner.Options,
        fileManager: FileManager = .default) -> Bool
    {
        guard self.isCLIProxyAPIAttributionEnabled(options: options, fileManager: fileManager) else { return false }

        if CLIProxyAPIUsageCacheIO.load(cacheRoot: options.cacheRoot).contains(where: {
            // Provider-specific by design: a raw Codex usage record is direct evidence for proxy attribution.
            $0.provider.caseInsensitiveCompare("codex") == .orderedSame
        }) {
            return true
        }

        let cachedClaude = CostUsageClaudeCacheIO.load(
            provider: .claude,
            cacheRoot: options.cacheRoot,
            calendar: options.calendar)
        if cachedClaude.files.values.contains(where: { usage in
            usage.claudeRows?.contains {
                $0.attribution?.route == .cliProxyAPI
                    && $0.attribution?.upstream?.isCodex == true
            } == true
        }) {
            return true
        }

        guard let home = options.cliProxyAPIHome else { return false }
        if CLIProxyAPIAttributionResolver.hasCodexOAuthModelAliasRoute(
            home: home,
            fileManager: fileManager)
        {
            return true
        }
        let logDirectory = home.appendingPathComponent("logs", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return false }
        return urls.contains { url in
            guard url.pathExtension.caseInsensitiveCompare("log") == .orderedSame,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            else { return false }
            return values.isRegularFile == true
        }
    }

    private static func isCLIProxyAPIAttributionEnabled(
        options: CostUsageScanner.Options,
        fileManager: FileManager = .default) -> Bool
    {
        !CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: options.cacheRoot,
            fileManager: fileManager)
    }

    private static func finalizeCodexSupplementalScan(
        projects: [CostUsageProjectBreakdown],
        sessions: [CostUsageSessionBreakdown],
        claudeProxyDaily: CostUsageDailyReport?,
        piDaily: CostUsageDailyReport?) -> (
        projects: [CostUsageProjectBreakdown],
        sessions: [CostUsageSessionBreakdown])
    {
        let mergedProjects = Self.mergedProjectBreakdowns(
            projects + [
                claudeProxyDaily.flatMap {
                    Self.unknownProjectBreakdown(
                        from: $0,
                        name: "Claude Code via CLIProxyAPI")
                },
                piDaily.flatMap { Self.unknownProjectBreakdown(from: $0) },
            ].compactMap(\.self))
        let hasUnattributedSessions = piDaily?.data.isEmpty == false
            || claudeProxyDaily?.data.isEmpty == false
        return (mergedProjects, hasUnattributedSessions ? [] : sessions)
    }

    package static func resolvedCodexScanDurationPerRefresh(
        provider: UsageProvider,
        bypassScannerDebounce: Bool,
        configuredDuration: TimeInterval?) -> TimeInterval?
    {
        // Provider-specific by design: only Codex refresh uses a bounded initial scan before background catch-up.
        guard provider == .codex,
              bypassScannerDebounce,
              configuredDuration == nil
        else { return configuredDuration }

        // UsageStore refreshes set bypassScannerDebounce. Bound that first app scan too,
        // so it can publish a partial snapshot and hand remaining work to the persistent
        // catch-up loop instead of consuming the whole 512 MiB byte budget continuously.
        return self.codexAutomaticScanDurationPerRefresh
    }

    private static func cursorCostProvenance(
        meteredCostUSD: Double?,
        daily: [CostUsageDailyReport.Entry]) -> CostProvenance
    {
        let hasDailyCosts = daily.contains { $0.costUSD != nil }
        if meteredCostUSD != nil, hasDailyCosts {
            return .mixed
        }
        if meteredCostUSD != nil {
            return .vendorMetered
        }
        if hasDailyCosts {
            return .listPriceEstimate
        }
        return .unknown
    }

    private static func configureScannerRefresh(
        _ options: inout CostUsageScanner.Options,
        provider: UsageProvider,
        allowVertexClaudeFallback: Bool,
        forceRefresh: Bool,
        bypassScannerDebounce: Bool)
    {
        if provider == .vertexai {
            options.claudeLogProviderFilter = allowVertexClaudeFallback ? .all : .vertexAIOnly
        } else if provider == .claude {
            options.claudeLogProviderFilter = .excludeVertexAI
        }
        if forceRefresh || bypassScannerDebounce {
            options.refreshMinIntervalSeconds = 0
        }
        options.maxCodexScanDurationPerRefresh = self.resolvedCodexScanDurationPerRefresh(
            provider: provider,
            bypassScannerDebounce: bypassScannerDebounce,
            configuredDuration: options.maxCodexScanDurationPerRefresh)
    }

    private static func unknownProjectBreakdown(
        from daily: CostUsageDailyReport,
        name: String = CostUsageProjectBreakdown.unknownProjectName) -> CostUsageProjectBreakdown?
    {
        guard !daily.data.isEmpty else { return nil }
        return CostUsageProjectBreakdown(
            name: name,
            path: nil,
            totalTokens: daily.summary?.totalTokens,
            totalCostUSD: daily.summary?.totalCostUSD,
            daily: daily.data,
            modelBreakdowns: self.projectModelBreakdowns(from: daily.data),
            sources: [
                CostUsageProjectSourceBreakdown(
                    name: name,
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
        var dailyByPath: [ProjectMergeKey: [CostUsageDailyReport]] = [:]
        var namesByPath: [ProjectMergeKey: String] = [:]
        var sourceDailyByProjectPath: [ProjectMergeKey: [ProjectMergeKey: [CostUsageDailyReport]]] = [:]
        var sourceNamesByProjectPath: [ProjectMergeKey: [ProjectMergeKey: String]] = [:]
        for project in projects {
            let key = ProjectMergeKey(name: project.name, path: project.path)
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
                let sourceKey = ProjectMergeKey(name: source.name, path: source.path)
                sourceNamesByProjectPath[key, default: [:]][sourceKey] = source.name
                sourceDailyByProjectPath[key, default: [:]][sourceKey, default: []]
                    .append(CostUsageDailyReport(data: source.daily, summary: nil))
            }
        }
        return dailyByPath.map { key, reports in
            let merged = CostUsageDailyReport.merged(reports)
            return CostUsageProjectBreakdown(
                name: namesByPath[key] ?? CostUsageProjectBreakdown.unknownProjectName,
                path: key.path,
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
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private struct ProjectMergeKey: Hashable {
        let path: String?
        let syntheticName: String?

        init(name: String, path: String?) {
            self.path = path
            self.syntheticName = path == nil ? name : nil
        }
    }

    private static func mergedProjectSources(
        sourceDailyByPath: [ProjectMergeKey: [CostUsageDailyReport]],
        sourceNamesByPath: [ProjectMergeKey: String]) -> [CostUsageProjectSourceBreakdown]
    {
        sourceDailyByPath.map { key, reports in
            let merged = CostUsageDailyReport.merged(reports)
            return CostUsageProjectSourceBreakdown(
                name: sourceNamesByPath[key] ?? CostUsageProjectBreakdown.unknownProjectName,
                path: key.path,
                totalTokens: merged.summary?.totalTokens,
                totalCostUSD: merged.summary?.totalCostUSD,
                daily: merged.data,
                modelBreakdowns: Self.projectModelBreakdowns(from: merged.data))
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.totalCostUSD ?? -1
            let rhsCost = rhs.totalCostUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
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

        func build(
            modelName: String,
            attribution: CostUsageAttribution?) -> CostUsageDailyReport.ModelBreakdown
        {
            CostUsageDailyReport.ModelBreakdown(
                modelName: modelName,
                costUSD: self.sawCost ? self.costUSD : nil,
                totalTokens: self.sawTotalTokens ? self.totalTokens : nil,
                attribution: attribution)
        }
    }

    private struct ProjectBreakdownKey: Hashable {
        let modelName: String
        let attribution: CostUsageAttribution?
    }

    static func projectModelBreakdowns(
        from entries: [CostUsageDailyReport.Entry]) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        var accumulators: [ProjectBreakdownKey: ProjectBreakdownAccumulator] = [:]
        for entry in entries {
            for breakdown in entry.modelBreakdowns ?? [] {
                let key = ProjectBreakdownKey(
                    modelName: breakdown.modelName,
                    attribution: breakdown.attribution)
                var accumulator = accumulators[key] ?? ProjectBreakdownAccumulator()
                accumulator.add(breakdown)
                accumulators[key] = accumulator
            }
        }
        guard !accumulators.isEmpty else { return nil }
        return accumulators.map { key, accumulator in
            accumulator.build(
                modelName: key.modelName,
                attribution: key.attribution)
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
            if lhs.modelName != rhs.modelName {
                return lhs.modelName > rhs.modelName
            }
            let lhsAttribution = lhs.attribution?.deterministicSortKey ?? ""
            let rhsAttribution = rhs.attribution?.deterministicSortKey ?? ""
            return lhsAttribution > rhsAttribution
        }
    }
}

extension CostUsageFetcher {
    static func selectCurrentSession(from sessions: [CostUsageSessionReport.Entry])
        -> CostUsageSessionReport.Entry?
    {
        if sessions.isEmpty {
            return nil
        }
        return sessions.max { lhs, rhs in
            let lDate = CostUsageDateParser.parse(lhs.lastActivity) ?? .distantPast
            let rDate = CostUsageDateParser.parse(rhs.lastActivity) ?? .distantPast
            if lDate != rDate {
                return lDate < rDate
            }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost {
                return lCost < rCost
            }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens {
                return lTokens < rTokens
            }
            return lhs.session < rhs.session
        }
    }

    static func selectMostRecentMonth(from months: [CostUsageMonthlyReport.Entry])
        -> CostUsageMonthlyReport.Entry?
    {
        if months.isEmpty {
            return nil
        }
        return months.max { lhs, rhs in
            let lDate = CostUsageDateParser.parseMonth(lhs.month) ?? .distantPast
            let rDate = CostUsageDateParser.parseMonth(rhs.month) ?? .distantPast
            if lDate != rDate {
                return lDate < rDate
            }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost {
                return lCost < rCost
            }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens {
                return lTokens < rTokens
            }
            return lhs.month < rhs.month
        }
    }
}

extension CostUsageFetcher {
    static func codexScanProgressKey(
        cache: CostUsageCache,
        scopedFiles: [String: CostUsageFileUsage]) -> String
    {
        var progressHasher = Hasher()
        progressHasher.combine(cache.codexScanCompletedFiles)

        for (path, usage) in scopedFiles.sorted(by: { $0.key < $1.key }) {
            progressHasher.combine(path)
            progressHasher.combine(usage.codexScanFileId)
            progressHasher.combine(usage.codexScanComplete)
            if usage.codexScanComplete == false {
                progressHasher.combine(usage.parsedBytes)
                progressHasher.combine(usage.size)
                progressHasher.combine(usage.codexJSONLResumeState?.offset)
            }
            let hasBufferedRetry = usage.hasBufferedCodexForkRetryLines
            progressHasher.combine(hasBufferedRetry)
            if hasBufferedRetry {
                progressHasher.combine(usage.forkedFromId)
                progressHasher.combine(usage.forkBaselineDependencyKey)
                progressHasher.combine(usage.codexBufferedSubagentLines?.isEmpty == false)
                progressHasher.combine(usage.codexBufferedUnresolvedForkLines?.isEmpty == false)
            }
        }

        if let discovery = cache.codexSessionDiscovery {
            progressHasher.combine(discovery.generation)
            progressHasher.combine(discovery.directoryPaths.count)
            progressHasher.combine(discovery.nextDirectoryIndex)
            progressHasher.combine(discovery.filePaths.count)
            progressHasher.combine(discovery.nextFileIndex)
            progressHasher.combine(discovery.headScan?.path)
            progressHasher.combine(discovery.headScan?.offset)
            progressHasher.combine(discovery.headScan?.resumeState?.offset)
            progressHasher.combine(discovery.filePathBySessionId.count)
            progressHasher.combine(discovery.missingSessionIds.sorted())
            progressHasher.combine(discovery.pendingSessionIds.sorted())
            progressHasher.combine(discovery.validationDirectoryIndex)
            progressHasher.combine(discovery.isComplete)
        } else {
            progressHasher.combine("no-discovery")
        }

        if let lookback = cache.codexActiveLookbackState {
            progressHasher.combine(lookback.scanSinceKey)
            progressHasher.combine(lookback.rootPaths.sorted())
            progressHasher.combine("next-day")
            for (root, dayKey) in lookback.nextDayKeyByRoot.sorted(by: { $0.key < $1.key }) {
                progressHasher.combine(root)
                progressHasher.combine(dayKey)
            }
            progressHasher.combine("next-directory-offset")
            progressHasher.combine(lookback.nextDirectoryOffsetByRoot == nil)
            for (root, offset) in (lookback.nextDirectoryOffsetByRoot ?? [:]).sorted(by: { $0.key < $1.key }) {
                progressHasher.combine(root)
                progressHasher.combine(offset)
            }
            progressHasher.combine(lookback.completedRootPaths.sorted())
            progressHasher.combine(lookback.pendingFilePaths.sorted())
            progressHasher.combine(lookback.legacyRecursivePendingRootPaths.sorted())
            progressHasher.combine("current-window-next-day")
            progressHasher.combine(lookback.currentWindowNextDayKeyByRoot == nil)
            for (root, dayKey) in (lookback.currentWindowNextDayKeyByRoot ?? [:]).sorted(by: { $0.key < $1.key }) {
                progressHasher.combine(root)
                progressHasher.combine(dayKey)
            }
            progressHasher.combine("current-window-directory-offset")
            progressHasher.combine(lookback.currentWindowDirectoryOffsetByRoot == nil)
            for (root, offset) in (lookback.currentWindowDirectoryOffsetByRoot ?? [:])
                .sorted(by: { $0.key < $1.key })
            {
                progressHasher.combine(root)
                progressHasher.combine(offset)
            }
            progressHasher.combine("completed-current-window-roots")
            progressHasher.combine(lookback.completedCurrentWindowRootPaths == nil)
            progressHasher.combine((lookback.completedCurrentWindowRootPaths ?? []).sorted())
            progressHasher.combine("current-window-flat-directory-offset")
            progressHasher.combine(lookback.currentWindowFlatDirectoryOffsetByRoot == nil)
            for (root, offset) in (lookback.currentWindowFlatDirectoryOffsetByRoot ?? [:])
                .sorted(by: { $0.key < $1.key })
            {
                progressHasher.combine(root)
                progressHasher.combine(offset)
            }
            progressHasher.combine("completed-current-window-flat-roots")
            progressHasher.combine(lookback.completedCurrentWindowFlatRootPaths == nil)
            progressHasher.combine((lookback.completedCurrentWindowFlatRootPaths ?? []).sorted())
            progressHasher.combine(lookback.cacheWideMigrationQueueActive)
        } else {
            progressHasher.combine("no-lookback")
        }

        if let inventoryPaths = cache.codexScanInventoryPaths {
            progressHasher.combine("inventory")
            progressHasher.combine(inventoryPaths.sorted())
        } else {
            progressHasher.combine("no-inventory")
        }

        return "v2:\(scopedFiles.count):\(progressHasher.finalize())"
    }

    fileprivate static func loadRemoteTokenSnapshot(
        provider: UsageProvider,
        environment: [String: String],
        now: Date,
        historyDays: Int,
        cursorCookieHeaderOverride: String?) async throws -> CostUsageTokenSnapshot?
    {
        // Provider-specific by design: Bedrock uses AWS billing while Cursor uses its macOS dashboard session.
        let since = Calendar.current.date(byAdding: .day, value: -(historyDays - 1), to: now) ?? now
        if provider == .bedrock {
            let daily = try await Self.loadBedrockDailyReport(
                environment: environment,
                since: since,
                until: now)
            return Self.tokenSnapshot(
                from: daily,
                now: now,
                historyDays: historyDays,
                useCurrentLocalDayForSession: false,
                costProvenance: .vendorMetered)
        }

        #if os(macOS)
        if provider == .cursor {
            return try await self.loadCursorTokenSnapshot(
                now: now,
                since: since,
                historyDays: historyDays,
                cookieHeaderOverride: cursorCookieHeaderOverride)
        }
        #endif
        return nil
    }
}
