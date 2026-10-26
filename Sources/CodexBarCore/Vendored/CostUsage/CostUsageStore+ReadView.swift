import Foundation

/// A read-only adapter for the existing report builders and progress semantics. Its scanner-shaped
/// storage is private: omitted parser state must never be handed back to scanner persistence.
struct CostUsageStoreReadView: Sendable {
    private let cache: CostUsageCache
    private let purpose: CostUsageStoreReadPurpose
    private let source: OpenCodeLocalHistoryAdapter.StoredSummary?

    init(
        cache: CostUsageCache,
        purpose: CostUsageStoreReadPurpose,
        source: OpenCodeLocalHistoryAdapter.StoredSummary? = nil)
    {
        self.cache = cache
        self.purpose = purpose
        self.source = source
    }

    var roots: [String: Int64]? {
        self.cache.roots
    }

    var timeZoneIdentifier: String? {
        self.cache.timeZoneIdentifier
    }

    var scanSinceKey: String? {
        self.cache.scanSinceKey
    }

    var scanUntilKey: String? {
        self.cache.scanUntilKey
    }

    var lastScanUnixMs: Int64 {
        self.cache.lastScanUnixMs
    }

    var projectMetadataVersion: Int? {
        self.cache.codexProjectMetadataVersion
    }

    var days: [String: [String: [Int]]] {
        self.cache.days
    }

    var hasPendingScan: Bool {
        self.source?.hasPendingWork == true || self.cache.codexScanCatchUpPending == true
            || self.cache.files.values.contains(where: \.hasPendingCodexScanWork)
    }

    var hasHistory: Bool {
        !self.cache.days.isEmpty || self.source?.hasRows == true
    }

    func scoped(to roots: [URL]) -> Self {
        let source = self.source?.scope.roots == roots.map(\.standardizedFileURL.path).sorted() ? self.source : nil
        return Self(
            cache: CostUsageScanner.codexCache(self.cache, scopedTo: roots),
            purpose: self.purpose,
            source: source)
    }

    func windowExpandsCache(_ range: CostUsageScanner.CostUsageDayRange) -> Bool {
        CostUsageScanner.requestedWindowExpandsCache(range: range, cache: self.cache)
    }

    func historyCoverageIsEstablished(
        range: CostUsageScanner.CostUsageDayRange,
        rootsFingerprint: [String: Int64]) -> Bool
    {
        guard self.source?.covers(range) != false,
              self.lastScanUnixMs > 0,
              self.timeZoneIdentifier == range.calendar.timeZone.identifier,
              self.roots == rootsFingerprint,
              !self.windowExpandsCache(range)
        else { return false }

        let roots = rootsFingerprint.keys.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let scoped = self.scoped(to: roots)
        // Exhausted parent discovery settles scheduling, not accounting. Only disjoint,
        // fully parsed windows can be published while the missing baseline is retained.
        guard scoped.cache.files.values.allSatisfy({ usage in
            !CostUsageScanner.isUnresolvedMissingParentFork(usage)
                || (usage.codexScanComplete == true && usage.hasCurrentCodexParser
                    && !usage.touchesCodexScanWindow(
                        sinceKey: range.sinceKey, untilKey: range.untilKey, calendar: range.calendar))
        }) else { return false }
        guard scoped.hasPendingScan else { return true }

        if let discovery = scoped.cache.codexSessionDiscovery,
           !discovery.isComplete, !discovery.pendingSessionIds.isEmpty || discovery.headScan != nil
        {
            return false
        }

        // Omitted day maps and unfinished or unowned work cannot prove absence from this window.
        guard scoped.purpose != .status,
              scoped.cache.files.values.allSatisfy({ usage in
                  usage.codexScanComplete == true && usage.codexCostCacheComplete == true
                      && usage.hasCurrentCodexParser && !usage.hasPendingCodexForkRetry
              })
        else { return false }

        guard let lookback = self.cache.codexActiveLookbackState,
              lookback.scanSinceKey <= range.scanSinceKey
        else { return false }
        let rootPaths = Set(roots.map(Self.resolvedCodexPath))
        guard Set(lookback.rootPaths) == rootPaths,
              Set(lookback.completedRootPaths) == rootPaths,
              lookback.legacyRecursivePendingRootPaths.isEmpty,
              Set(lookback.completedCurrentWindowRootPaths ?? []) == rootPaths,
              Set(lookback.completedCurrentWindowFlatRootPaths ?? []) == rootPaths
        else { return false }

        var filesByResolvedPath: [String: CostUsageFileUsage] = [:]
        for (path, usage) in scoped.cache.files {
            filesByResolvedPath[Self.resolvedCodexPath(URL(fileURLWithPath: path, isDirectory: false))] = usage
        }
        for path in lookback.pendingFilePaths {
            let resolvedPath = Self.resolvedCodexPath(URL(fileURLWithPath: path, isDirectory: false))
            guard let usage = filesByResolvedPath[resolvedPath] else { return false }
            if lookback.cacheWideMigrationQueueActive == true,
               usage.touchesCodexScanWindow(
                   sinceKey: range.scanSinceKey,
                   untilKey: range.scanUntilKey,
                   calendar: range.calendar)
            {
                return false
            }
            let fileURL = URL(fileURLWithPath: resolvedPath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            if CostUsageScanner.codexLogicalTargetHasUnconsumedTail(metadata: metadata, cached: usage)
                || usage.size != metadata.size
                || usage.mtimeUnixMs != metadata.mtimeUnixMs
                || usage.codexScanFileId != metadata.fileId
            {
                return false
            }
        }

        return true
    }

    func previousReport(
        range: CostUsageScanner.CostUsageDayRange,
        rootsFingerprint: [String: Int64]) -> CostUsageCodexPreviousReport?
    {
        guard !self.historyCoverageIsEstablished(range: range, rootsFingerprint: rootsFingerprint) else {
            return nil
        }
        return CostUsageScanner.codexPreviousReport(
            cache: self.cache,
            range: range,
            rootsFingerprint: rootsFingerprint)
    }

    private static func resolvedCodexPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    func dailyReport(range: CostUsageScanner.CostUsageDayRange, cacheRoot: URL?) -> CostUsageDailyReport {
        self.mergingSource(
            into: CostUsageScanner.buildCodexReportFromCache(
                cache: self.cache,
                range: range,
                modelsDevCacheRoot: cacheRoot),
            range: range)
    }

    func mergingSource(
        into report: CostUsageDailyReport,
        range: CostUsageScanner.CostUsageDayRange) -> CostUsageDailyReport
    {
        guard let source else { return report }
        return report.merged(with: source.report(range), calendar: range.calendar)
    }

    func reports(
        range: CostUsageScanner.CostUsageDayRange,
        cacheRoot: URL?,
        roots: [URL],
        includeBreakdowns: Bool = true,
        includeProjects: Bool = true)
        -> (daily: CostUsageDailyReport, projects: [CostUsageProjectBreakdown], sessions: [CostUsageSessionBreakdown])
    {
        let result = CostUsageScanner.buildCodexReportProjectionsFromCache(
            cache: self.cache,
            range: range,
            modelsDevCacheRoot: cacheRoot,
            sessionRoots: roots,
            includeBreakdowns: includeBreakdowns,
            includeProjects: includeProjects)
        return (self.mergingSource(into: result.daily, range: range), result.projects, result.sessions)
    }

    func projectSessionIDs(range: CostUsageScanner.CostUsageDayRange) -> [String: Set<String>] {
        // Session rows deduplicate to the latest file. Ownership must include older files too,
        // even after a thread moves directories. This conservative superset is refresh-only.
        var sessionIDsByPath: [String: Set<String>] = [:]
        for (filePath, usage) in self.cache.files {
            guard let path = usage.projectPath,
                  usage.touchesCodexScanWindow(
                      sinceKey: range.scanSinceKey,
                      untilKey: range.scanUntilKey,
                      calendar: range.calendar) else { continue }
            let id = usage.sessionId ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            sessionIDsByPath[path, default: []].insert(id)
        }
        return sessionIDsByPath
    }

    func catchUpStatus(
        roots: [URL],
        rootsFingerprint: [String: Int64],
        requiredRange: CostUsageScanner.CostUsageDayRange? = nil) -> CostUsageFetcher.CodexScanCatchUpStatus
    {
        guard self.roots == rootsFingerprint else {
            return .init(pending: false, progressKey: "scope-mismatch")
        }
        let scoped = self.scoped(to: roots)
        let pending = scoped.hasPendingScan
        return .init(
            pending: pending,
            progressKey: CostUsageFetcher.codexScanProgressKey(cache: self.cache, scopedFiles: scoped.cache.files)
                + (scoped.source.map { ":" + $0.progressKey } ?? ""),
            processedBytes: self.cache.codexScanProcessedBytes ?? 0,
            totalBytes: self.cache.codexScanTotalBytes ?? 0,
            completedFiles: self.cache.codexScanCompletedFiles ?? 0,
            totalFiles: self.cache.codexScanTotalFiles ?? 0,
            staleSnapshotUpdatedAt: pending ? self.cache.codexPreviousReport?.updatedAt : nil,
            completionIsConfirmed: !pending && requiredRange.map {
                self.historyCoverageIsEstablished(range: $0, rootsFingerprint: rootsFingerprint)
            } == true)
    }
}

enum CostUsageStoreReadPurpose: Sendable {
    case status
    /// Scoped token totals and coverage only; no per-event history for detailed reports.
    case activity
    case report

    func includes(_ requested: Self) -> Bool {
        self == requested || self == .report || (self == .activity && requested == .status)
    }
}

extension CostUsageStore {
    func loadCodexReadView(
        calendar: Calendar,
        purpose: CostUsageStoreReadPurpose,
        sourceScope: OpenCodeLocalHistoryAdapter.ReadScope? = nil) -> CostUsageStoreReadView
    {
        self.retainedCodexBaseline = nil
        _ = self.removeLegacyCodexArtifactIfPresent()
        return self.withDatabase(default: CostUsageStoreReadView(
            cache: CostUsageCache(),
            purpose: purpose))
        { database in
            let recorder = self.scopedReadWorkRecorderForTesting
            guard let before = try self.databaseStamp(database) else {
                self.retainedCodexRead = nil
                self.requiresReadReopen = true
                return CostUsageStoreReadView(cache: CostUsageCache(), purpose: purpose)
            }
            if let retained = self.retainedCodexRead,
               retained.stamp == before,
               retained.purpose.includes(purpose),
               retained.source?.scope == sourceScope
            {
                guard retained.decoded.timeZoneIdentifier == nil
                    || retained.decoded.timeZoneIdentifier == calendar.timeZone.identifier
                else { return CostUsageStoreReadView(cache: CostUsageCache(), purpose: purpose) }
                recorder?.recordReadViewConversion(database: database)
                return CostUsageStoreReadView(
                    cache: Self.reconciledCodexCache(retained.decoded, persistence: retained.persistence),
                    purpose: retained.purpose,
                    source: retained.source)
            }
            let (snapshot, usageRows, retryPresence, source) = try Self.inReadTransaction(database) {
                let files = try Self.readFiles(database, recorder: recorder)
                let snapshot = try CostUsageStoreSnapshot(
                    metadata: Self.readSingleton(
                        CostUsageStoreMetadata.self, database: database, table: "scan_metadata") ?? .empty,
                    files: files,
                    tokenSnapshots: [],
                    usageRows: [],
                    fileDayAggregates: purpose != .status
                        ? Self.readFileDayAggregates(database, path: nil, nativeOnly: true) : [],
                    dayAggregates: purpose != .status && !files.contains(where: \.belongsToOpenCodeLocalHistory)
                        ? Self.readDayAggregates(database, sinceDay: nil, untilDay: nil) : [],
                    forkLineage: Self.readForkLineage(database, path: nil),
                    bufferedLines: [],
                    discoveryState: Self.readSingleton(
                        CostUsageStoreDiscoveryState.self, database: database, table: "discovery_state"),
                    lookbackState: Self.readSingleton(
                        CostUsageStoreLookbackState.self, database: database, table: "lookback_state"),
                    accumulators: [])
                let usageRows = purpose == .report
                    ? try Self.readDecodedCodexUsageRows(database, files: snapshot.files, recorder: recorder)
                    : nil
                let retryPresence = try Self.readRetryBufferPresence(database, recorder: recorder)
                #if DEBUG
                try self.runCodexReadCheckpointForTesting()
                #endif
                let source = try sourceScope.map {
                    try OpenCodeLocalHistoryAdapter.StoredSummary.read(database, scope: $0, purpose: purpose)
                }
                return (snapshot, usageRows, retryPresence, source)
            }
            // A read transaction pins data_version. Cache only a snapshot that is still current
            // after COMMIT so an external writer can never make a stale warm view authoritative.
            let after = try self.databaseStamp(database)
            guard let after, before == after else {
                self.retainedCodexRead = nil
                // Re-enter open-time compatibility validation on the next access, after this handle's use ends.
                self.requiresReadReopen = after == nil
                return CostUsageStoreReadView(cache: CostUsageCache(), purpose: purpose)
            }
            guard snapshot.metadata.timeZoneIdentifier == nil
                || snapshot.metadata.timeZoneIdentifier == calendar.timeZone.identifier
            else { return CostUsageStoreReadView(cache: CostUsageCache(), purpose: purpose) }
            // Identity/anchor reconciliation touches the filesystem; do not pin a SQLite reader during it.
            let decoded = Self.decodeCodexCache(
                from: snapshot,
                recorder: recorder,
                retryPresence: retryPresence,
                decodedUsageRows: usageRows?.rowsByPath,
                // Only scanner reconciliation and report turn performance read the request ledger.
                includesRequestLedgerState: purpose == .report)
            let persistence = CodexPersistenceState(snapshot: snapshot, rowCounts: usageRows?.rowCounts)
            // Activity is a superset of status and becomes the one bounded warm read state.
            // Detailed reports keep their larger event history transient.
            if purpose != .report {
                self.retainedCodexRead = RetainedCodexRead(
                    decoded: decoded,
                    persistence: persistence,
                    stamp: after,
                    purpose: purpose,
                    source: source)
            }
            recorder?.recordReadViewConversion(database: database)
            return CostUsageStoreReadView(
                cache: Self.reconciledCodexCache(decoded, persistence: persistence),
                purpose: purpose,
                source: source)
        }
    }
}
