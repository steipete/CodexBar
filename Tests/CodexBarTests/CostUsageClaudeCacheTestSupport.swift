import Foundation
@testable import CodexBarCore

/// Keep metrics and fixture orchestration in the test target; core only emits work events.
extension CostUsageScanner {
    struct ClaudeScanWorkMetrics: Equatable, Sendable {
        var cacheDecodes = 0
        var transcriptParses = 0
        var incrementalTranscriptParses = 0
        var reconciliations = 0
        var cacheEncodes = 0
        var fragmentEncodes = 0
        var fragmentFallbacks = 0
        var repricedRows = 0
        var normalizationCacheMisses = 0
        var vertexMetadataWalks = 0
        var claudeLineDecodes = 0
        var claudeCostCalculations = 0
        var catalogModelLookups = 0
        var catalogModelHits = 0
        var catalogModelMisses = 0
    }

    final class ClaudeScanWorkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var metrics = ClaudeScanWorkMetrics()
        private var artifactIO = (reads: 0, writes: 0)

        func record(_ work: ClaudeScanWork) {
            self.lock.lock()
            defer { self.lock.unlock() }
            switch work {
            case .cacheDecode: self.metrics.cacheDecodes += 1
            case let .transcriptParse(startOffset):
                self.metrics.transcriptParses += 1
                if startOffset > 0 {
                    self.metrics.incrementalTranscriptParses += 1
                }
            case .reconcile: self.metrics.reconciliations += 1
            case .cacheEncode: self.metrics.cacheEncodes += 1
            case .fragmentEncode: self.metrics.fragmentEncodes += 1
            case .fragmentFallback: self.metrics.fragmentFallbacks += 1
            case .artifactRead: self.artifactIO.reads += 1
            case .artifactWrite: self.artifactIO.writes += 1
            case .reprice: self.metrics.repricedRows += 1
            case .normalizationCacheMiss: self.metrics.normalizationCacheMisses += 1
            case .vertexMetadataWalk: self.metrics.vertexMetadataWalks += 1
            case .claudeLineDecode: self.metrics.claudeLineDecodes += 1
            case .claudeCostCalculation: self.metrics.claudeCostCalculations += 1
            case let .catalogModelLookup(found):
                self.metrics.catalogModelLookups += 1
                if found {
                    self.metrics.catalogModelHits += 1
                } else {
                    self.metrics.catalogModelMisses += 1
                }
            }
        }

        func snapshot() -> ClaudeScanWorkMetrics {
            self.lock.withLock { self.metrics }
        }

        func persistenceSnapshot() -> (reads: Int, writes: Int) {
            self.lock.withLock { self.artifactIO }
        }
    }

    static func withClaudeScanWorkRecorderForTesting<T>(
        _ recorder: ClaudeScanWorkRecorder,
        operation: () throws -> T) rethrows -> T
    {
        try self.$observeClaudeScanWorkForTesting.withValue(recorder.record) {
            try operation()
        }
    }

    static func evictClaudeReportMemoForTesting(
        provider: UsageProvider,
        cacheRoot: URL?,
        reportContext: CostUsageReportContext = .regular)
    {
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(
            provider: provider,
            cacheRoot: cacheRoot,
            reportContext: reportContext)
        let canonicalCachePath = cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
        CostUsageClaudeReportMemo.shared.evict(
            provider: provider,
            canonicalCachePath: canonicalCachePath)
    }

    static func evictPersistedClaudeReportMemoForTesting(provider: UsageProvider, cacheRoot: URL?) {
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: provider, cacheRoot: cacheRoot)
            .standardizedFileURL.resolvingSymlinksInPath()
        try? FileManager.default.removeItem(at: CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL))
    }
}

extension CostUsageClaudeCacheIO {
    static func withIsolatedCachesForTesting(operation: @Sendable () async throws -> Void) async throws {
        try await ArtifactMemo.$shared.withValue(ArtifactMemo()) {
            try await CostUsageClaudeReportMemo.$shared.withValue(CostUsageClaudeReportMemo()) {
                try await CostUsageClaudeFragments.$shared.withValue(CostUsageClaudeFragments()) {
                    try await operation()
                }
            }
        }
    }

    static func evictArtifactMemoForTesting(at url: URL) {
        ArtifactMemo.shared.entries.removeObject(forKey: url.standardizedFileURL.resolvingSymlinksInPath() as NSURL)
    }
}

/// Convenience entry points used only by scanner tests.
extension CostUsageScanner {
    static func parseClaudeFile(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> ClaudeParseResult
    {
        let pricingResolver = modelsDevCatalog.map { CostUsagePricing.ClaudeResolver(catalog: $0) }
            ?? CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: modelsDevCacheRoot)
        return (
            try? self.parseClaudeFileCancellable(
                fileURL: fileURL,
                range: range,
                providerFilter: providerFilter,
                startOffset: startOffset,
                pricingResolver: pricingResolver,
                checkCancellation: nil)) ?? ClaudeParseResult(rows: [], parsedBytes: startOffset)
    }

    static func buildClaudeReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        now: Date = Date(),
        modelsDevCacheRoot: URL? = nil) -> CostUsageDailyReport
    {
        self.buildClaudeReportFromCache(
            cache: cache,
            rows: self.reconciledClaudeRows(cache: cache),
            range: range,
            pricingResolver: CostUsagePricing.ClaudeResolver(now: now, cacheRoot: modelsDevCacheRoot))
    }
}
