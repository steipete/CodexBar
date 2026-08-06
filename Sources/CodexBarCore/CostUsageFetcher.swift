import Foundation

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

    package func loadCachedCodexTokenActivity(
        now: Date = Date(),
        codexHomePath: String? = nil,
        maximumDays: Int = 365) async -> CostUsageTokenActivityCache?
    {
        await Self.loadCachedCodexTokenActivity(
            now: now,
            codexHomePath: codexHomePath,
            maximumDays: maximumDays,
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

    package func loadCachedCodexTokenSnapshotForScopedHome(
        now: Date = Date(),
        codexHomePath: String,
        historyDays: Int = 30,
        includePiSessions: Bool = false,
        includeProjectAndSessionBreakdowns: Bool = false) async -> CostUsageTokenSnapshot?
    {
        await Self.loadCachedCodexTokenSnapshot(
            now: now,
            codexHomePath: codexHomePath,
            historyDays: historyDays,
            allowScopedCodexHome: true,
            includePiSessions: includePiSessions,
            includeProjectAndSessionBreakdowns: includeProjectAndSessionBreakdowns,
            scannerOptions: self.scannerOptionsOverride())
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
        includePiSessions: Bool = true) async throws -> CostUsageTokenSnapshot
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
        bypassScannerDebounce: Bool) async throws -> CostUsageTokenSnapshot
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
            bypassScannerDebounce: bypassScannerDebounce,
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

    private func scannerOptionsOverride() -> CostUsageScanner.Options? {
        self.scannerOptions
    }

    package func codexScanCatchUpStatus(
        codexHomePath: String? = nil) async -> CodexScanCatchUpStatus
    {
        // Provider-specific by design: Codex exposes bounded background catch-up for its incremental JSONL scanner.
        let options = Self.resolvedScannerOptions(
            self.scannerOptionsOverride(),
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
        historyDays: Int = 30) async throws -> CodexScanCatchUpStatus
    {
        var options = Self.resolvedScannerOptions(
            self.scannerOptionsOverride(),
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
        let loadedCache = CostUsageCacheIO.loadCodexForMigration(
            cacheRoot: options.cacheRoot,
            calendar: options.calendar)
        let cache = loadedCache.cache
        guard cache.roots == rootsFingerprint else {
            if let incompatibleCache = loadedCache.incompatibleCache,
               incompatibleCache.roots == rootsFingerprint
            {
                let staleSnapshotUpdatedAt: Date? = if incompatibleCache.lastScanUnixMs > 0 {
                    Date(timeIntervalSince1970: TimeInterval(incompatibleCache.lastScanUnixMs) / 1000)
                } else {
                    nil
                }
                return CodexScanCatchUpStatus(
                    pending: true,
                    progressKey: "producer-upgrade",
                    staleSnapshotUpdatedAt: staleSnapshotUpdatedAt)
            }
            return CodexScanCatchUpStatus(pending: false, progressKey: "scope-mismatch")
        }

        let scoped = CostUsageScanner.codexCache(cache, scopedTo: roots)
        var progressHasher = Hasher()
        for (path, usage) in scoped.files.sorted(by: { $0.key < $1.key }) {
            progressHasher.combine(path)
            progressHasher.combine(usage.codexScanFileId)
            progressHasher.combine(usage.parsedBytes)
            progressHasher.combine(usage.size)
            progressHasher.combine(usage.codexScanComplete)
        }
        let hasIncompleteFile = scoped.files.values.contains { $0.codexScanComplete == false }
        let pending = cache.codexScanCatchUpPending == true || hasIncompleteFile
        return CodexScanCatchUpStatus(
            pending: pending,
            progressKey: "\(scoped.files.count):\(progressHasher.finalize())",
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

    private static func resolvedScannerOptions(
        _ override: CostUsageScanner.Options?,
        provider: UsageProvider,
        codexHomePath: String?) -> CostUsageScanner.Options
    {
        var options = override ?? CostUsageScanner.Options()
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
        // Rolling window is inclusive, so a 30-day display starts 29 days before `now`.
        let since = options.calendar.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now
        let scopedCodexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Provider-specific by design: scoped Codex homes exclude ambient Pi sessions from managed-profile totals.
        let shouldMergePiUsage = provider != .codex || scopedCodexHomePath?.isEmpty != false
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
            shouldMergePiUsage: shouldMergePiUsage,
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
            historyIsIncomplete: scanResult.historyIsIncomplete,
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
        let historyIsIncomplete: Bool
    }

    private struct LocalTokenScanOptions: Sendable {
        let allowVertexClaudeFallback: Bool
        let includePiSessions: Bool
        let shouldMergePiUsage: Bool
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
            // Grok: single-pass local session scan (daily + projects + sessions).
            if provider == .grok {
                var grokOptions = GrokTurnUsageScanner.Options()
                if let override = options.scanOptions.grokSessionsRoot {
                    grokOptions.sessionsRoot = override
                }
                grokOptions.cacheRoot = options.scanOptions.cacheRoot
                let bundle = try GrokTurnUsageScanner.loadScanBundle(
                    since: since,
                    until: now,
                    now: now,
                    options: grokOptions,
                    checkCancellation: checkCancellation)
                return LocalTokenScanResult(
                    daily: bundle.daily,
                    projects: bundle.projects,
                    sessions: bundle.sessions,
                    staleSnapshotUpdatedAt: nil,
                    historyCoverageIsEstablished: true,
                    historyIsIncomplete: bundle.historyIsIncomplete)
            }

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
            var staleSnapshotUpdatedAt: Date?
            if provider == .codex {
                let roots = CostUsageScanner.codexSessionsRoots(options: options.scanOptions)
                let cache = CostUsageScanner.codexCache(
                    CostUsageCacheIO.load(provider: .codex, cacheRoot: options.scanOptions.cacheRoot),
                    scopedTo: roots)
                let range = CostUsageScanner.CostUsageDayRange(
                    since: since, until: now, calendar: options.scanOptions.calendar)
                if let previous = CostUsageScanner.codexPreviousReport(
                    cache: cache,
                    range: range,
                    rootsFingerprint: CostUsageScanner.codexRootsFingerprint(options: options.scanOptions))
                {
                    staleSnapshotUpdatedAt = previous.updatedAt
                } else {
                    projects = CostUsageScanner.buildCodexProjectBreakdownsFromCache(
                        cache: cache,
                        range: range,
                        modelsDevCacheRoot: options.scanOptions.cacheRoot)
                    sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
                        cache: cache,
                        range: range,
                        modelsDevCacheRoot: options.scanOptions.cacheRoot,
                        sessionRoots: roots)
                }
            }
            if options.includePiSessions,
               provider == .claude || (provider == .codex && options.shouldMergePiUsage)
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
                projects = Self.mergedProjectBreakdowns(
                    projects + [piDaily.flatMap(Self.unknownProjectBreakdown(from:))].compactMap(\.self))
                if piDaily?.data.isEmpty == false {
                    sessions = []
                }
            }
            return LocalTokenScanResult(
                daily: daily,
                projects: projects,
                sessions: sessions,
                staleSnapshotUpdatedAt: staleSnapshotUpdatedAt,
                historyCoverageIsEstablished: provider != .codex
                    || Self.codexHistoryCoverageIsEstablished(options: options.scanOptions),
                historyIsIncomplete: false)
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

    private struct UnknownPricingRefreshRequest: Sendable {
        let providerID: String
        let modelIDs: Set<String>
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
        let unknownModelIDs = Set(daily.data.flatMap { entry in
            entry.modelBreakdowns?.compactMap { breakdown -> String? in
                guard breakdown.costUSD == nil else { return nil }
                if provider == .codex,
                   CostUsagePricing.isCodexUnattributedModel(breakdown.modelName)
                {
                    return nil
                }
                return breakdown.modelName
            } ?? []
        })
        guard !unknownModelIDs.isEmpty else { return nil }

        return UnknownPricingRefreshRequest(
            providerID: provider == .codex ? "openai" : "anthropic",
            modelIDs: unknownModelIDs,
            now: now,
            cacheRoot: cacheRoot,
            client: client)
    }

    private static func refreshUnknownPricingIfNeeded(
        _ request: UnknownPricingRefreshRequest,
        inBackground: Bool) async -> Bool
    {
        if inBackground {
            Task.detached(priority: .utility) {
                _ = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
                    providerID: request.providerID,
                    modelIDs: request.modelIDs,
                    now: request.now,
                    cacheRoot: request.cacheRoot,
                    client: request.client)
            }
            return false
        }
        return await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
            providerID: request.providerID,
            modelIDs: request.modelIDs,
            now: request.now,
            cacheRoot: request.cacheRoot,
            client: request.client) == .pricingAvailable
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
                CostUsageCacheIO.loadCodexForMigration(
                    cacheRoot: options.cacheRoot,
                    calendar: options.calendar).cache,
                scopedTo: roots)
            guard cache.timeZoneIdentifier == options.calendar.timeZone.identifier,
                  cache.roots == rootsFingerprint,
                  cache.codexScanCatchUpPending != true,
                  !cache.files.values.contains(where: { $0.codexScanComplete == false }),
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
                    for packed in cache.days[day, default: [:]].values {
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

        // Decoding the persisted scan cache parses multi-megabyte JSON; keep it off the
        // cooperative pool alongside the scans themselves.
        let cachedSnapshot: CachedCodexTokenSnapshotResult?? = try? await CostUsageScanExecutor.run { _ in
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
            let loadedCache = CostUsageCacheIO.loadCodexForMigration(
                cacheRoot: options.cacheRoot,
                calendar: options.calendar)
            let cache = CostUsageScanner.codexCache(
                loadedCache.cache,
                scopedTo: roots)
            var reports: [CostUsageDailyReport] = []
            var projects: [CostUsageProjectBreakdown] = []
            var sessions: [CostUsageSessionBreakdown] = []
            // Raw inputs for the derived result fields below: the native cache's own scan
            // time, every constituent scan time, and whether a second source joined the merge.
            var nativeScanAt: Date?
            var scanTimes: [Date] = []
            var piMerged = false
            var staleSnapshotUpdatedAt: Date?

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
            } else if let incompatibleCache = loadedCache.incompatibleCache,
                      incompatibleCache.timeZoneIdentifier == range.calendar.timeZone.identifier,
                      !incompatibleCache.days.isEmpty,
                      incompatibleCache.roots == rootsFingerprint,
                      !CostUsageScanner.requestedWindowExpandsCache(range: range, cache: incompatibleCache)
            {
                let daily = CostUsageScanner.buildCodexReportFromCache(
                    cache: incompatibleCache,
                    range: range,
                    modelsDevCacheRoot: options.cacheRoot)
                if !daily.data.isEmpty {
                    reports.append(daily)
                    if incompatibleCache.lastScanUnixMs > 0 {
                        let scanAt = Date(
                            timeIntervalSince1970: TimeInterval(incompatibleCache.lastScanUnixMs) / 1000)
                        staleSnapshotUpdatedAt = scanAt
                        scanTimes.append(scanAt)
                    }
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
                if let piProject = Self.unknownProjectBreakdown(from: piResult.report) {
                    projects.append(piProject)
                }
                if !piResult.report.data.isEmpty {
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
                    projects: Self.mergedProjectBreakdowns(projects),
                    sessions: sessions,
                    updatedAt: scanTimes.min()),
                lastRefreshAt: piMerged || staleSnapshotUpdatedAt != nil ? nil : nativeScanAt,
                staleSnapshotUpdatedAt: staleSnapshotUpdatedAt)
        }
        return cachedSnapshot.flatMap(\.self)
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
        credentialScopeFingerprint: String? = nil,
        historyLabel: String? = nil,
        historyIsIncomplete: Bool = false,
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = [],
        updatedAt: Date? = nil) -> CostUsageTokenSnapshot
    {
        let sessionEntry = useCurrentLocalDayForSession
            ? CostUsageTokenSnapshot.entry(in: daily.data, forLocalDayContaining: now, calendar: calendar)
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
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            historyLabel: historyLabel,
            historyIsIncomplete: historyIsIncomplete,
            meteredCostUSD: meteredCostUSD,
            credentialScopeFingerprint: credentialScopeFingerprint,
            daily: daily.data,
            projects: projects,
            sessions: sessions,
            updatedAt: updatedAt ?? now)
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
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
            return lhs.modelName > rhs.modelName
        }
    }

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
                useCurrentLocalDayForSession: false)
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
