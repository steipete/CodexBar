import Foundation

/// In-memory working set for one bounded scan. Codex persists this shape as normalized
/// `CostUsageStore` rows; Claude and Vertex use their independent compact JSON cache.
struct CostUsageCache: Codable, Equatable, @unchecked Sendable {
    var version: Int = 1
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var codexPricingKey: String?
    var codexPriorityMetadataKey: String?
    var codexProjectMetadataVersion: Int?
    var codexPriorityTurnKeys: [String: String]?
    var codexPriorityTurnIDsByDay: [String: [String]]?
    var codexPriorityTurnsCursor: CostUsageScanner.CodexPriorityTurnsPersistedCursor?
    var codexScanCatchUpPending: Bool?
    var codexScanProcessedBytes: Int64?
    var codexScanTotalBytes: Int64?
    var codexScanCompletedFiles: Int?
    var codexScanTotalFiles: Int?
    var codexScanInventoryPaths: [String]?
    var codexPreviousReport: CostUsageCodexPreviousReport?
    var codexSessionDiscovery: CostUsageCodexSessionDiscovery?
    var codexActiveLookbackState: CostUsageCodexActiveLookbackState?
    var files: [String: CostUsageFileUsage] = [:]
    var days: [String: [String: [Int]]] = [:]
    var roots: [String: Int64]?
}

struct CostUsageCodexActiveLookbackState: Codable, Equatable {
    var scanSinceKey: String
    var rootPaths: [String]
    var nextDayKeyByRoot: [String: String] = [:]
    var nextDirectoryOffsetByRoot: [String: Int64]?
    var completedRootPaths: [String] = []
    var pendingFilePaths: [String] = []
    var legacyRecursivePendingRootPaths: [String] = []
    var currentWindowNextDayKeyByRoot: [String: String]?
    var currentWindowDirectoryOffsetByRoot: [String: Int64]?
    var completedCurrentWindowRootPaths: [String]?
    var currentWindowFlatDirectoryOffsetByRoot: [String: Int64]?
    var completedCurrentWindowFlatRootPaths: [String]?
    var cacheWideMigrationQueueActive: Bool?
}

struct CostUsageCodexSessionDiscovery: Codable, Equatable {
    struct DirectoryStamp: Codable, Equatable {
        var mtimeUnixMs: Int64
        var jsonlFileCount: Int
    }

    struct FileStamp: Codable, Equatable {
        var mtimeUnixMs: Int64
        var size: Int64
        var fileId: String?
    }

    struct HeadScan: Codable, Equatable {
        var path: String
        var offset: Int64
        var resumeState: CostUsageJsonl.ResumeState?
    }

    var roots: [String]
    var generation: String?
    var directoryStamps: [String: DirectoryStamp]
    var directoryPaths: [String]
    var nextDirectoryIndex: Int
    var filePaths: [String]
    var nextFileIndex: Int
    var fileStamps: [String: FileStamp]
    var headScan: HeadScan?
    var filePathBySessionId: [String: String]
    var missingSessionIds: [String]
    var pendingSessionIds: [String]
    var validationDirectoryIndex: Int
    var isComplete: Bool
}

struct CostUsageCodexPreviousReport: Codable, Equatable {
    struct ModelBreakdown: Codable, Equatable {
        var modelName: String
        var costUSD: Double?
        var totalTokens: Int?
        var requestCount: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var reasoningTokens: Int?
        var standardCostUSD: Double?
        var priorityCostUSD: Double?
        var standardTokens: Int?
        var priorityTokens: Int?

        init(_ breakdown: CostUsageDailyReport.ModelBreakdown) {
            self.modelName = breakdown.modelName
            self.costUSD = breakdown.costUSD
            self.totalTokens = breakdown.totalTokens
            self.requestCount = breakdown.requestCount
            self.inputTokens = breakdown.inputTokens
            self.outputTokens = breakdown.outputTokens
            self.cacheReadTokens = breakdown.cacheReadTokens
            self.reasoningTokens = breakdown.reasoningTokens
            self.standardCostUSD = breakdown.standardCostUSD
            self.priorityCostUSD = breakdown.priorityCostUSD
            self.standardTokens = breakdown.standardTokens
            self.priorityTokens = breakdown.priorityTokens
        }

        var dailyReportValue: CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: self.modelName,
                costUSD: self.costUSD,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                inputTokens: self.inputTokens,
                outputTokens: self.outputTokens,
                cacheReadTokens: self.cacheReadTokens,
                reasoningTokens: self.reasoningTokens,
                standardCostUSD: self.standardCostUSD,
                priorityCostUSD: self.priorityCostUSD,
                standardTokens: self.standardTokens,
                priorityTokens: self.priorityTokens)
        }
    }

    struct Entry: Codable, Equatable {
        var date: String
        var inputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var outputTokens: Int?
        var reasoningTokens: Int?
        var totalTokens: Int?
        var requestCount: Int?
        var costUSD: Double?
        var modelsUsed: [String]?
        var modelBreakdowns: [ModelBreakdown]?
        var unpricedRequestCount: Int?
        var unmeteredRequestCount: Int?
        var estimatedRequestCount: Int?

        init(_ entry: CostUsageDailyReport.Entry) {
            self.date = entry.date
            self.inputTokens = entry.inputTokens
            self.cacheReadTokens = entry.cacheReadTokens
            self.cacheCreationTokens = entry.cacheCreationTokens
            self.outputTokens = entry.outputTokens
            self.reasoningTokens = entry.reasoningTokens
            self.totalTokens = entry.totalTokens
            self.requestCount = entry.requestCount
            self.costUSD = entry.costUSD
            self.modelsUsed = entry.modelsUsed
            self.modelBreakdowns = entry.modelBreakdowns?.map(ModelBreakdown.init)
            self.unpricedRequestCount = entry.unpricedRequestCount
            self.unmeteredRequestCount = entry.unmeteredRequestCount
            self.estimatedRequestCount = entry.estimatedRequestCount
        }

        var dailyReportValue: CostUsageDailyReport.Entry {
            CostUsageDailyReport.Entry(
                date: self.date,
                inputTokens: self.inputTokens,
                outputTokens: self.outputTokens,
                cacheReadTokens: self.cacheReadTokens,
                cacheCreationTokens: self.cacheCreationTokens,
                reasoningTokens: self.reasoningTokens,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                costUSD: self.costUSD,
                modelsUsed: self.modelsUsed,
                modelBreakdowns: self.modelBreakdowns?.map(\.dailyReportValue),
                unpricedRequestCount: self.unpricedRequestCount,
                unmeteredRequestCount: self.unmeteredRequestCount,
                estimatedRequestCount: self.estimatedRequestCount)
        }
    }

    struct Summary: Codable, Equatable {
        var totalInputTokens: Int?
        var totalOutputTokens: Int?
        var cacheReadTokens: Int?
        var cacheCreationTokens: Int?
        var totalTokens: Int?
        var totalCostUSD: Double?

        init(_ summary: CostUsageDailyReport.Summary) {
            self.totalInputTokens = summary.totalInputTokens
            self.totalOutputTokens = summary.totalOutputTokens
            self.cacheReadTokens = summary.cacheReadTokens
            self.cacheCreationTokens = summary.cacheCreationTokens
            self.totalTokens = summary.totalTokens
            self.totalCostUSD = summary.totalCostUSD
        }

        var dailyReportValue: CostUsageDailyReport.Summary {
            CostUsageDailyReport.Summary(
                totalInputTokens: self.totalInputTokens,
                totalOutputTokens: self.totalOutputTokens,
                cacheReadTokens: self.cacheReadTokens,
                cacheCreationTokens: self.cacheCreationTokens,
                totalTokens: self.totalTokens,
                totalCostUSD: self.totalCostUSD)
        }
    }

    var data: [Entry]
    var summary: Summary?
    var updatedAtUnixMs: Int64
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var roots: [String: Int64]?

    init?(
        report: CostUsageDailyReport,
        cache: CostUsageCache,
        reportSinceKey: String,
        reportUntilKey: String)
    {
        guard !report.data.isEmpty else { return nil }
        self.data = report.data.map(Entry.init)
        self.summary = report.summary.map(Summary.init)
        self.updatedAtUnixMs = cache.lastScanUnixMs
        self.scanSinceKey = reportSinceKey
        self.scanUntilKey = reportUntilKey
        self.timeZoneIdentifier = cache.timeZoneIdentifier
        self.roots = cache.roots
    }

    var report: CostUsageDailyReport {
        CostUsageDailyReport(data: self.data.map(\.dailyReportValue), summary: self.summary?.dailyReportValue)
    }

    var updatedAt: Date? {
        guard self.updatedAtUnixMs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(self.updatedAtUnixMs) / 1000)
    }

    func matches(
        scanSinceKey: String,
        scanUntilKey: String,
        timeZoneIdentifier: String,
        roots: [String: Int64]) -> Bool
    {
        guard self.timeZoneIdentifier == timeZoneIdentifier,
              self.roots == roots,
              let cachedSince = self.scanSinceKey,
              let cachedUntil = self.scanUntilKey
        else { return false }
        return scanSinceKey >= cachedSince && scanUntilKey <= cachedUntil
    }
}

struct CostUsageFileUsage: Codable, Equatable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    var lastTotals: CostUsageCodexTotals?
    var lastCountedTotals: CostUsageCodexTotals?
    var lastRawTotalsBaseline: CostUsageCodexTotals?
    var lastRawTotalsWatermark: CostUsageCodexTotals?
    var seenRawTotals: [CostUsageCodexTotals]?
    var hasDivergentTotals: Bool?
    var hasInterleavedTotals: Bool?
    var lastCodexTurnID: String?
    var sessionId: String?
    var forkedFromId: String?
    var forkBaselineDependencyKey: String?
    var projectPath: String?
    var canonicalProjectPath: String?
    var codexCostCacheComplete: Bool?
    var codexSession: CostUsageCodexSessionMetadata?
    var codexCostNanos: [String: [String: Int64]]?
    var codexPrioritySurchargeNanos: [String: [String: Int64]]?
    var codexStandardCostNanos: [String: [String: Int64]]?
    var codexPriorityCostNanos: [String: [String: Int64]]?
    var codexStandardTokens: [String: [String: Int]]?
    var codexPriorityTokens: [String: [String: Int]]?
    var codexTurnIDs: [String]?
    var codexWorkspaceContentFingerprint: String?
    var codexRows: [CostUsageScanner.CodexUsageRow]?
    var codexTokenSnapshots: [CostUsageCodexTokenSnapshot]?
    var codexTokenCheckpoints: [CostUsageCodexTokenCheckpoint]?
    var codexTokenTimestampsMonotonic: Bool?
    var codexTokenIndexAnchor: CostUsageCodexTokenIndexAnchor?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
    var codexScanFileId: String?
    var codexScanTargetSize: Int64?
    var codexScanComplete: Bool?
    var codexJSONLResumeState: CostUsageJsonl.ResumeState?
    var codexBufferedSubagentLines: [CostUsageScanner.CodexBufferedFastLine]?
    var codexBufferedUnresolvedForkLines: [CostUsageScanner.CodexBufferedFastLine]?

    var hasBufferedCodexForkRetryLines: Bool {
        self.codexBufferedSubagentLines?.isEmpty == false
            || self.codexBufferedUnresolvedForkLines?.isEmpty == false
    }
}

struct CostUsageCodexSessionMetadata: Codable, Equatable {
    var sessionId: String?
    var forkedFromId: String?
    var cwd: String?
    var title: String?
    var startedAtUnixMs: Int64?
    var latestActivityUnixMs: Int64?

    var isEmpty: Bool {
        self.sessionId == nil && self.forkedFromId == nil && self.cwd == nil && self.title == nil
            && self.startedAtUnixMs == nil && self.latestActivityUnixMs == nil
    }

    func merging(_ newer: CostUsageCodexSessionMetadata) -> CostUsageCodexSessionMetadata {
        CostUsageCodexSessionMetadata(
            sessionId: newer.sessionId ?? self.sessionId,
            forkedFromId: newer.forkedFromId ?? self.forkedFromId,
            cwd: newer.cwd ?? self.cwd,
            title: newer.title ?? self.title,
            startedAtUnixMs: Self.earlier(self.startedAtUnixMs, newer.startedAtUnixMs),
            latestActivityUnixMs: Self.later(self.latestActivityUnixMs, newer.latestActivityUnixMs))
    }

    private static func earlier(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func later(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}

struct CostUsageCodexTotals: Codable, Equatable {
    var input: Int
    var cached: Int
    var output: Int
    var reasoning: Int?

    init(input: Int, cached: Int, output: Int, reasoning: Int? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
    }
}

struct CostUsageCodexTokenSnapshot: Codable, Equatable {
    var timestamp: String
    var last: CostUsageCodexTotals?
    var total: CostUsageCodexTotals?
    var endOffset: Int64?

    init(
        timestamp: String,
        last: CostUsageCodexTotals?,
        total: CostUsageCodexTotals?,
        endOffset: Int64? = nil)
    {
        self.timestamp = timestamp
        self.last = last
        self.total = total
        self.endOffset = endOffset
    }
}

struct CostUsageCodexTokenAccumulatorState: Codable, Equatable {
    var countedTotals: CostUsageCodexTotals?
    var rawTotalsBaseline: CostUsageCodexTotals?
    var sawDivergentTotals: Bool
    var rawTotalsWatermark: CostUsageCodexTotals?
    var seenRawTotals: [CostUsageCodexTotals]
    var sawInterleavedTotals: Bool
}

struct CostUsageCodexTokenCheckpoint: Codable, Equatable {
    var eventIndex: Int
    var timestamp: String
    var endOffset: Int64
    var state: CostUsageCodexTokenAccumulatorState
}

struct CostUsageCodexTokenIndexAnchor: Codable, Equatable {
    var indexedBytes: Int64
    var windowStart: Int64
    var sha256: String
}
