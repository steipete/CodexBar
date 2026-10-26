import Foundation

struct CostUsageStoreTotals: Codable, Equatable, Sendable {
    var input: Int64
    var cached: Int64
    var output: Int64
    var reasoning: Int64?

    static let zero = Self(input: 0, cached: 0, output: 0, reasoning: nil)
}

struct CostUsageStoreValidationAnchor: Codable, Equatable, Sendable {
    var indexedBytes: Int64
    var windowStart: Int64
    var sha256: String
}

/// Which adapter produced a `files` record and owns decoding of its `scan_state`
/// payloads. The discriminator is an optional JSON field so every record written before
/// the source seam existed decodes as native Codex — no schema migration or table rebuild
/// is involved (#4752 point 1).
enum CostUsageStoreSource: String, Codable, Sendable {
    /// Native Codex JSONL session logs (the store's original and default content).
    case nativeCodexSessionLogs
    /// The OpenCode local history adapter feeding an external `opencode.db` into the
    /// store behind the #3273 opt-in.
    case opencodeLocalHistory
}

struct CostUsageStoreScanState: Codable, Equatable, Sendable {
    /// Source discriminator; `nil` on records persisted before the source seam. The
    /// default keeps the synthesized memberwise initializer source-compatible with every
    /// existing call site.
    var source: CostUsageStoreSource?
    var targetSize: Int64?
    var isComplete: Bool
    var resumePayload: Data?
    var tokenTimestampsMonotonic: Bool?
    var nextUsageRowIndex: Int?
    var lastModel: String?
    var lastTurnID: String?
    var fileIdentity: String?
    var detailsPayload: Data?

    /// The source this record actually belongs to: native Codex unless explicitly
    /// registered otherwise. Restore paths must dispatch on this before touching the
    /// Codex-JSONL-specific payloads.
    var resolvedSource: CostUsageStoreSource {
        self.source ?? .nativeCodexSessionLogs
    }
}

struct CostUsageStoreFile: Codable, Equatable, Sendable {
    var path: String
    var inode: Int64?
    var mtimeUnixMs: Int64
    var size: Int64
    var parsedBytes: Int64?
    var anchor: CostUsageStoreValidationAnchor?
    var scanState: CostUsageStoreScanState
    var sessionID: String?
    var coverageSinceDay: String?
    var coverageUntilDay: String?
    var updatedAtUnixMs: Int64

    /// True when this record belongs to the OpenCode local history adapter — restore and
    /// scanning code written for Codex JSONL logs must not decode its payloads as JSONL
    /// state (#4752 point 1: source-aware dispatch).
    var belongsToOpenCodeLocalHistory: Bool {
        self.scanState.resolvedSource == .opencodeLocalHistory
    }
}

struct CostUsageStoreTokenSnapshot: Codable, Equatable, Sendable {
    var path: String
    var eventIndex: Int
    var timestamp: String
    var timestampUnixMs: Int64?
    var day: String?
    var last: CostUsageStoreTotals?
    var total: CostUsageStoreTotals?
    var endOffset: Int64?
}

struct CostUsageStoreUsageRow: Codable, Equatable, Sendable {
    var path: String
    var rowIndex: Int
    var payload: Data
}

struct CostUsageStoreDayAggregate: Codable, Equatable, Sendable {
    var day: String
    var model: String
    var inputTokens: Int64
    var cachedTokens: Int64
    var outputTokens: Int64
    var reasoningTokens: Int64
    var requestCount: Int64
    var authoritativeCostNanos: Int64
    var standardInputTokens: Int64
    var standardCachedTokens: Int64
    var standardOutputTokens: Int64
    var priorityInputTokens: Int64
    var priorityCachedTokens: Int64
    var priorityOutputTokens: Int64
    var standardTokens: Int64
    var priorityTokens: Int64

    static func zero(day: String, model: String) -> Self {
        Self(
            day: day,
            model: model,
            inputTokens: 0,
            cachedTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            requestCount: 0,
            authoritativeCostNanos: 0,
            standardInputTokens: 0,
            standardCachedTokens: 0,
            standardOutputTokens: 0,
            priorityInputTokens: 0,
            priorityCachedTokens: 0,
            priorityOutputTokens: 0,
            standardTokens: 0,
            priorityTokens: 0)
    }
}

struct CostUsageStoreFileDayAggregate: Codable, Equatable, Sendable {
    var path: String
    var aggregate: CostUsageStoreDayAggregate
}

struct CostUsageStoreForkLineage: Codable, Equatable, Sendable {
    var path: String
    var sessionID: String?
    var forkedFromID: String?
    var forkTimestamp: String?
    var dependencyKey: String?
    var subagentState: Data?
    var accountingState: Data?
}

enum CostUsageStoreBufferedLineKind: String, Codable, CaseIterable, Sendable {
    case pricingEvidence
    case sourcePricingEvidence
    case sourcePricingAnchor
    case subagent
    case unresolvedFork
    case deferredReplay
}

struct CostUsageStoreBufferedLine: Codable, Equatable, Sendable {
    var path: String
    var kind: CostUsageStoreBufferedLineKind
    var lineIndex: Int
    var ordinal: Int?
    var endOffset: Int64?
    var payload: Data
}

struct CostUsageStoreDiscoveryState: Codable, Equatable, Sendable {
    var roots: [String]
    var generation: String?
    var directoryPaths: [String]
    var nextDirectoryIndex: Int
    var filePaths: [String]
    var nextFileIndex: Int
    var filePathBySessionID: [String: String]
    var missingSessionIDs: [String]
    var pendingSessionIDs: [String]
    var validationDirectoryIndex: Int
    var isComplete: Bool
    var payload: Data?
}

struct CostUsageStoreLookbackState: Codable, Equatable, Sendable {
    var scanSinceDay: String
    var rootPaths: [String]
    var nextDayByRoot: [String: String]
    var nextDirectoryOffsetByRoot: [String: Int64]?
    var completedRootPaths: [String]
    var pendingFilePaths: [String]
    var legacyRecursivePendingRootPaths: [String]
    var currentWindowNextDayKeyByRoot: [String: String]?
    var currentWindowDirectoryOffsetByRoot: [String: Int64]?
    var completedCurrentWindowRootPaths: [String]?
    var currentWindowFlatDirectoryOffsetByRoot: [String: Int64]?
    var completedCurrentWindowFlatRootPaths: [String]?
    var cacheWideMigrationQueueActive: Bool?
}

struct CostUsageStoreAccumulator: Codable, Equatable, Sendable {
    var path: String
    var eventCount: Int
    var nextUsageRowIndex: Int?
    var countedTotals: CostUsageStoreTotals?
    var rawTotalsBaseline: CostUsageStoreTotals?
    var rawTotalsWatermark: CostUsageStoreTotals?
    var sawDivergentTotals: Bool
    var sawInterleavedTotals: Bool
    var seenRawTotals: [CostUsageStoreTotals]
    var updatedAtUnixMs: Int64
}

struct CostUsageStoreMetadata: Codable, Equatable, Sendable {
    var lastScanUnixMs: Int64
    var scanSinceDay: String?
    var scanUntilDay: String?
    var timeZoneIdentifier: String?
    var pricingKey: String?
    var priorityMetadataKey: String?
    var catchUpPending: Bool
    var processedBytes: Int64?
    var totalBytes: Int64?
    var completedFiles: Int?
    var totalFiles: Int?
    var scanInventoryPaths: [String]?
    var rootMtimes: [String: Int64]?
    var previousReportPayload: Data?
    var priorityTurnStatePayload: Data?
    var projectMetadataVersion: Int?

    static let empty = Self(
        lastScanUnixMs: 0,
        scanSinceDay: nil,
        scanUntilDay: nil,
        timeZoneIdentifier: nil,
        pricingKey: nil,
        priorityMetadataKey: nil,
        catchUpPending: false,
        processedBytes: nil,
        totalBytes: nil,
        completedFiles: nil,
        totalFiles: nil,
        scanInventoryPaths: nil,
        rootMtimes: nil,
        previousReportPayload: nil,
        priorityTurnStatePayload: nil,
        projectMetadataVersion: nil)
}

struct CostUsageStoreReport: Equatable, Sendable {
    var metadata: CostUsageStoreMetadata
    var aggregates: [CostUsageStoreDayAggregate]
}

struct CostUsageStoreSnapshot: Equatable, Sendable {
    var metadata: CostUsageStoreMetadata
    var files: [CostUsageStoreFile]
    var tokenSnapshots: [CostUsageStoreTokenSnapshot]
    var usageRows: [CostUsageStoreUsageRow] = []
    var fileDayAggregates: [CostUsageStoreFileDayAggregate]
    var dayAggregates: [CostUsageStoreDayAggregate]
    var forkLineage: [CostUsageStoreForkLineage]
    var bufferedLines: [CostUsageStoreBufferedLine]
    var discoveryState: CostUsageStoreDiscoveryState?
    var lookbackState: CostUsageStoreLookbackState?
    var accumulators: [CostUsageStoreAccumulator]
}

struct CostUsageStoreRetentionResult: Equatable, Sendable {
    var deletedFiles: Int
    var deletedTokenSnapshots: Int
    var deletedFileDayAggregates: Int
    var deletedDayAggregates: Int
}

struct CostUsageStoreBudgetResult: Equatable, Sendable {
    var deletedRows: Int
    var rowCount: Int
    var fileBytes: Int64
    var catchUpRequired: Bool = false
}

struct CostUsageStoreConfiguration: Equatable, Sendable {
    var journalMode: String
    var busyTimeoutMilliseconds: Int
    var foreignKeysEnabled: Bool
    var autoVacuumMode: Int
    var userVersion: Int
}
