import Foundation

/// A read-only adapter for the existing report builders and progress semantics. Its scanner-shaped
/// storage is private: omitted parser state must never be handed back to scanner persistence.
struct CostUsageStoreReadView: Sendable {
    private let cache: CostUsageCache
    private let purpose: CostUsageStoreReadPurpose

    init(cache: CostUsageCache, purpose: CostUsageStoreReadPurpose) {
        self.cache = cache
        self.purpose = purpose
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
        self.cache.codexScanCatchUpPending == true || self.cache.files.values.contains {
            $0.codexScanComplete == false || $0.hasBufferedCodexForkRetryLines
        }
    }

    func scoped(to roots: [URL]) -> Self {
        Self(cache: CostUsageScanner.codexCache(self.cache, scopedTo: roots), purpose: self.purpose)
    }

    func windowExpandsCache(_ range: CostUsageScanner.CostUsageDayRange) -> Bool {
        CostUsageScanner.requestedWindowExpandsCache(range: range, cache: self.cache)
    }

    func historyCoverageIsEstablished(
        range: CostUsageScanner.CostUsageDayRange,
        rootsFingerprint: [String: Int64]) -> Bool
    {
        guard self.lastScanUnixMs > 0,
              self.timeZoneIdentifier == range.calendar.timeZone.identifier,
              self.roots == rootsFingerprint,
              !self.windowExpandsCache(range)
        else { return false }

        let roots = rootsFingerprint.keys.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let scoped = self.scoped(to: roots)
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
                      && usage.hasCurrentCodexParser && !usage.hasBufferedCodexForkRetryLines
                      && !CostUsageScanner.isUnresolvedMissingParentFork(usage)
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
            filesByResolvedPath[Self.resolvedCodexPath(URL(fileURLWithPath: path))] = usage
        }
        for path in lookback.pendingFilePaths {
            let resolvedPath = Self.resolvedCodexPath(URL(fileURLWithPath: path))
            guard let usage = filesByResolvedPath[resolvedPath] else { return false }
            if lookback.cacheWideMigrationQueueActive == true,
               usage.touchesCodexScanWindow(
                   sinceKey: range.scanSinceKey,
                   untilKey: range.scanUntilKey,
                   calendar: range.calendar)
            {
                return false
            }
            let fileURL = URL(fileURLWithPath: resolvedPath)
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
        CostUsageScanner.buildCodexReportFromCache(cache: self.cache, range: range, modelsDevCacheRoot: cacheRoot)
    }

    func projects(range: CostUsageScanner.CostUsageDayRange, cacheRoot: URL?) -> [CostUsageProjectBreakdown] {
        CostUsageScanner.buildCodexProjectBreakdownsFromCache(
            cache: self.cache, range: range, modelsDevCacheRoot: cacheRoot)
    }

    func sessions(
        range: CostUsageScanner.CostUsageDayRange,
        cacheRoot: URL?,
        roots: [URL]) -> [CostUsageSessionBreakdown]
    {
        CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: self.cache, range: range, modelsDevCacheRoot: cacheRoot, sessionRoots: roots)
    }

    func catchUpStatus(
        roots: [URL],
        rootsFingerprint: [String: Int64]) -> CostUsageFetcher.CodexScanCatchUpStatus
    {
        guard self.roots == rootsFingerprint else {
            return .init(pending: false, progressKey: "scope-mismatch")
        }
        let scoped = self.scoped(to: roots)
        let pending = scoped.hasPendingScan
        return .init(
            pending: pending,
            progressKey: CostUsageFetcher.codexScanProgressKey(cache: self.cache, scopedFiles: scoped.cache.files),
            processedBytes: self.cache.codexScanProcessedBytes ?? 0,
            totalBytes: self.cache.codexScanTotalBytes ?? 0,
            completedFiles: self.cache.codexScanCompletedFiles ?? 0,
            totalFiles: self.cache.codexScanTotalFiles ?? 0,
            staleSnapshotUpdatedAt: pending ? self.cache.codexPreviousReport?.updatedAt : nil)
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
