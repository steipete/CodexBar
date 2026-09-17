import Foundation

public enum CodexCombinedCostPhase: Sendable {
    case fetching, scanning, cleaning
}

public struct CodexCombinedCostRequest: Sendable {
    public let source: CodexRemoteLogSource
    public let localCodexHome: URL
    public let historyDays: Int
    public let calendar: Calendar
    public let now: Date
    public let pricingCacheRoot: URL?
    public let localCostCacheRoot: URL?

    public init(
        source: CodexRemoteLogSource,
        localCodexHome: URL,
        historyDays: Int,
        calendar: Calendar,
        now: Date = Date(),
        pricingCacheRoot: URL? = nil,
        localCostCacheRoot: URL? = nil)
    {
        self.source = source
        self.localCodexHome = localCodexHome
        self.historyDays = max(1, min(365, historyDays))
        self.calendar = calendar
        self.now = now
        self.pricingCacheRoot = pricingCacheRoot
        self.localCostCacheRoot = localCostCacheRoot
    }
}

public struct CodexCombinedCostResult: Sendable {
    public let snapshot: CostUsageTokenSnapshot
    public let source: CodexRemoteLogSource
    public let capturedFrom: Date
    public let capturedTo: Date
    public let notices: [String]

    public init(
        snapshot: CostUsageTokenSnapshot,
        source: CodexRemoteLogSource,
        capturedFrom: Date,
        capturedTo: Date,
        notices: [String])
    {
        self.snapshot = snapshot
        self.source = source
        self.capturedFrom = capturedFrom
        self.capturedTo = capturedTo
        self.notices = notices
    }
}

public enum CodexCombinedCostError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedOverlap, missingAncestor, localCoverage, pricingEvidence, incompleteScan, unsafeLocalLogs

    public var errorDescription: String? {
        switch self {
        case .unsupportedOverlap:
            "Log overlap cannot be verified as identical records or a complete ordered prefix. Showing local usage."
        case .missingAncestor:
            "A required parent session is unavailable or has unsupported ancestry. Showing local usage."
        case .localCoverage:
            "Retained local history cannot be fully reconstructed from current logs. Showing local usage."
        case .pricingEvidence:
            "Known priority pricing evidence cannot safely be retained in this combined scan. Showing local usage."
        case .incompleteScan:
            "The combined log scan did not establish complete coverage. Showing local usage."
        case .unsafeLocalLogs:
            "Local logs could not be read as stable regular files within the request limit. Showing local usage."
        }
    }
}

/// Immutable value copies; the underlying catalog types have no reference-backed mutable state.
struct CodexCombinedPricingContext: @unchecked Sendable {
    let artifact: ModelsDevCacheArtifact?
    let custom: CostUsageCustomPricing

    var catalog: ModelsDevCatalog {
        self.artifact?.catalog ?? ModelsDevCatalog(providers: [:])
    }

    static func freeze(request: CodexCombinedCostRequest) -> Self {
        Self(
            artifact: ModelsDevCache.load(
                now: request.now,
                cacheRoot: request.pricingCacheRoot).artifact,
            custom: CostUsageCustomPricing.load(fileURL: request.pricingCacheRoot.map {
                $0.appendingPathComponent(CostUsageCustomPricing.fileName)
            }))
    }
}

public struct CodexCombinedCostFetcher: Sendable {
    private let mirror: CodexRemoteLogMirror

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, temporaryRoot: URL? = nil) {
        self.mirror = CodexRemoteLogMirror(environment: environment, temporaryRoot: temporaryRoot)
    }

    public func load(
        _ request: CodexCombinedCostRequest,
        progress: @escaping @Sendable (CodexCombinedCostPhase) async -> Void = { _ in })
        async throws -> CodexCombinedCostResult
    {
        try request.source.validate()
        let pricing = CodexCombinedPricingContext.freeze(request: request)
        await progress(.fetching)
        return try await self.mirror.withMirror(source: request.source) { remote in
            await progress(.scanning)
            do {
                let snapshot = try await CostUsageScanExecutor.run { checkCancellation in
                    try Self.scan(
                        request: request,
                        remote: remote,
                        pricing: pricing,
                        checkCancellation: checkCancellation)
                }
                await progress(.cleaning)
                return CodexCombinedCostResult(
                    snapshot: snapshot,
                    source: request.source,
                    capturedFrom: remote.capturedFrom,
                    capturedTo: remote.capturedTo,
                    notices: [
                        "API list-price estimate; server-only trace pricing metadata is not collected.",
                        "Identical ordered records and verified complete prefixes are counted once.",
                    ])
            } catch {
                await progress(.cleaning)
                if error is CancellationError || error is CodexCombinedCostError { throw error }
                throw CodexCombinedCostError.unsafeLocalLogs
            }
        }
    }

    static func scan(
        request: CodexCombinedCostRequest,
        remote: CodexRemoteLogSnapshot,
        pricing: CodexCombinedPricingContext,
        checkCancellation: @escaping @Sendable () throws -> Void) throws -> CostUsageTokenSnapshot
    {
        try checkCancellation()
        let since = request.calendar.date(
            byAdding: .day,
            value: -(request.historyDays - 1),
            to: request.calendar.startOfDay(for: request.now))
            ?? request.now
        let retainedPriority = try CodexCombinedLocalCoverage.validate(request: request, since: since)
        let localRoots = ["sessions", "archived_sessions"].map {
            request.localCodexHome.appendingPathComponent($0, isDirectory: true)
        }
        let prepared = try CodexCombinedLogPreparation.prepare(
            roots: localRoots + remote.roots,
            destination: remote.workDirectory.appendingPathComponent(
                "canonical",
                isDirectory: true),
            ownedRemoteDirectory: remote.workDirectory,
            localTraceURL: request.localCodexHome.appendingPathComponent("logs_2.sqlite"),
            since: since,
            until: request.now,
            calendar: request.calendar,
            retainedPriority: retainedPriority,
            checkCancellation: checkCancellation)
        let roots = prepared.roots
        try FileManager.default.createDirectory(
            at: remote.scanCacheRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var options = CostUsageScanner.Options(
            cacheRoot: remote.scanCacheRoot,
            codexTraceDatabaseURL: remote.workDirectory.appendingPathComponent("no-traces.sqlite"),
            calendar: request.calendar)
        options.codexPrivateStore = true
        options.codexExplicitSessionRoots = roots
        options.codexFrozenPricing = pricing
        options.refreshMinIntervalSeconds = 0
        _ = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: request.now,
            now: request.now,
            options: options,
            checkCancellation: checkCancellation)
        try checkCancellation()
        // This is exclusively the owned ephemeral store; never open the normal ledger through StoreAccess.
        let cache = CostUsageStore(cacheRoot: remote.scanCacheRoot).syncLoadCodexCache(
            calendar: request.calendar, loadTokenSnapshots: false)
        let view = CostUsageStoreReadView(cache: cache)
        let status = view.catchUpStatus(
            roots: roots,
            rootsFingerprint: CostUsageScanner.codexRootsFingerprint(options: options))
        guard status.historyCoverageIsEstablished, !status.pending else {
            throw CodexCombinedCostError.incompleteScan
        }
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: request.now, calendar: request.calendar)
        let pricedCache = try prepared.priority.applying(to: cache, range: range, checkCancellation: checkCancellation)
        let daily = CostUsageScanner.buildCodexReportFromCache(
            cache: pricedCache,
            range: range,
            modelsDevCatalog: pricing.catalog,
            priorityTurns: [:],
            customPricing: pricing.custom)
        try checkCancellation()
        guard daily.data.allSatisfy({ $0.coverageCounts.unmetered == 0 }) else {
            throw CodexCombinedCostError.missingAncestor
        }
        return CostUsageFetcher.tokenSnapshot(
            from: daily,
            now: request.now,
            historyDays: request.historyDays,
            calendar: request.calendar,
            costProvenance: .listPriceEstimate)
    }
}
