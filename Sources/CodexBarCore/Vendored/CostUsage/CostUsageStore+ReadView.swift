import Foundation

/// A read-only adapter for the existing report builders and progress semantics. Its scanner-shaped
/// storage is private: omitted parser state must never be handed back to scanner persistence.
struct CostUsageStoreReadView: Sendable {
    private let cache: CostUsageCache

    init(cache: CostUsageCache) {
        self.cache = cache
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
        Self(cache: CostUsageScanner.codexCache(self.cache, scopedTo: roots))
    }

    func windowExpandsCache(_ range: CostUsageScanner.CostUsageDayRange) -> Bool {
        CostUsageScanner.requestedWindowExpandsCache(range: range, cache: self.cache)
    }

    func historyCoverageIsEstablished(
        range: CostUsageScanner.CostUsageDayRange,
        rootsFingerprint: [String: Int64]) -> Bool
    {
        self.lastScanUnixMs > 0
            && self.timeZoneIdentifier == range.calendar.timeZone.identifier
            && self.roots == rootsFingerprint
            && !self.hasPendingScan
            && !self.windowExpandsCache(range)
    }

    func previousReport(
        range: CostUsageScanner.CostUsageDayRange,
        rootsFingerprint: [String: Int64]) -> CostUsageCodexPreviousReport?
    {
        CostUsageScanner.codexPreviousReport(cache: self.cache, range: range, rootsFingerprint: rootsFingerprint)
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

enum CostUsageStoreReadPurpose {
    case status
    case report
}
