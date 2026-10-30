import Foundation
import SQLite3
@testable import CodexBarCore

/// Convenience defaults for synthetic cache fixtures. Production calls the value initializer directly.
extension CostUsageScanner {
    static func makeFileUsage(
        mtimeUnixMs: Int64,
        size: Int64,
        days: [String: [String: [Int]]],
        parsedBytes: Int64?,
        lastModel: String? = nil,
        lastTotals: CostUsageCodexTotals? = nil,
        lastCountedTotals: CostUsageCodexTotals? = nil,
        lastRawTotalsBaseline: CostUsageCodexTotals? = nil,
        lastRawTotalsWatermark: CostUsageCodexTotals? = nil,
        seenRawTotals: [CostUsageCodexTotals]? = nil,
        hasDivergentTotals: Bool? = nil,
        hasInterleavedTotals: Bool? = nil,
        lastCodexTurnID: String? = nil,
        sessionId: String? = nil,
        forkedFromId: String? = nil,
        forkBaselineDependencyKey: String? = nil,
        projectPath: String? = nil,
        canonicalProjectPath: String? = nil,
        codexCostCacheComplete: Bool? = true,
        codexSession: CostUsageCodexSessionMetadata? = nil,
        codexCostNanos: [String: [String: Int64]]? = nil,
        codexPrioritySurchargeNanos: [String: [String: Int64]]? = nil,
        codexStandardCostNanos: [String: [String: Int64]]? = nil,
        codexPriorityCostNanos: [String: [String: Int64]]? = nil,
        codexStandardTokens: [String: [String: Int]]? = nil,
        codexPriorityTokens: [String: [String: Int]]? = nil,
        codexTurnIDs: [String]? = nil,
        codexRows: [CodexUsageRow]? = nil,
        codexTokenSnapshots: [CostUsageCodexTokenSnapshot]? = nil,
        codexTokenCheckpoints: [CostUsageCodexTokenCheckpoint]? = nil,
        codexTokenTimestampsMonotonic: Bool? = nil,
        codexTokenIndexAnchor: CostUsageCodexTokenIndexAnchor? = nil,
        claudeRows: [ClaudeUsageRow]? = nil,
        codexScanFileId: String? = nil,
        codexScanTargetSize: Int64? = nil,
        codexScanComplete: Bool? = nil,
        codexJSONLResumeState: CostUsageJsonl.ResumeState? = nil,
        codexForkAccountingState: CodexForkAccountingState? = nil,
        codexRequestLedgerState: CodexRequestLedgerState? = nil,
        codexBufferedSubagentLines: [CodexBufferedFastLine]? = nil,
        codexBufferedUnresolvedForkLines: [CodexBufferedFastLine]? = nil) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            mtimeUnixMs: mtimeUnixMs,
            size: size,
            days: days,
            parsedBytes: parsedBytes,
            lastModel: lastModel,
            lastTotals: lastTotals,
            lastCountedTotals: lastCountedTotals,
            lastRawTotalsBaseline: lastRawTotalsBaseline,
            lastRawTotalsWatermark: lastRawTotalsWatermark,
            seenRawTotals: seenRawTotals,
            hasDivergentTotals: hasDivergentTotals,
            hasInterleavedTotals: hasInterleavedTotals,
            lastCodexTurnID: lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            forkBaselineDependencyKey: forkBaselineDependencyKey,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexCostCacheComplete: codexCostCacheComplete,
            codexSession: codexSession,
            codexCostNanos: codexCostNanos,
            codexPrioritySurchargeNanos: codexPrioritySurchargeNanos,
            codexStandardCostNanos: codexStandardCostNanos,
            codexPriorityCostNanos: codexPriorityCostNanos,
            codexStandardTokens: codexStandardTokens,
            codexPriorityTokens: codexPriorityTokens,
            codexTurnIDs: codexTurnIDs,
            codexRows: codexRows,
            codexTokenSnapshots: codexTokenSnapshots,
            codexTokenCheckpoints: codexTokenCheckpoints,
            codexTokenTimestampsMonotonic: codexTokenTimestampsMonotonic,
            codexTokenIndexAnchor: codexTokenIndexAnchor,
            claudeRows: claudeRows,
            codexScanFileId: codexScanFileId,
            codexScanTargetSize: codexScanTargetSize,
            codexScanComplete: codexScanComplete,
            codexJSONLResumeState: codexJSONLResumeState,
            codexForkAccountingState: codexForkAccountingState,
            codexRequestLedgerState: codexRequestLedgerState,
            codexBufferedSubagentLines: codexBufferedSubagentLines,
            codexBufferedUnresolvedForkLines: codexBufferedUnresolvedForkLines)
    }
}

extension CostUsageScanner {
    static func needsCodexPricingMetadata(_ usage: CostUsageFileUsage) -> Bool {
        !(usage.codexRows?.isEmpty ?? true)
            && (usage.codexCostCacheComplete != true || self.needsCodexModeSplitCache(usage))
    }
}

extension CostUsageScanner {
    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialRawTotalsBaseline: CostUsageCodexTotals? = nil,
        initialHasDivergentTotals: Bool = false,
        initialCodexTurnID: String? = nil,
        initialCodexUsageRowIndex: Int = 0,
        inheritedTotalsResolver: ((String, String) -> CodexForkBaseline)? = nil) -> CodexParseResult
    {
        let throwingResolver: ((String, String) throws -> CodexForkBaseline)? = inheritedTotalsResolver
            .map { resolver in
                { sessionId, timestamp in resolver(sessionId, timestamp) }
            }
        return (
            try? Self.parseCodexFileCancellable(
                fileURL: fileURL,
                range: range,
                startOffset: startOffset,
                initialModel: initialModel,
                initialTotals: initialTotals,
                initialRawTotalsBaseline: initialRawTotalsBaseline,
                initialHasDivergentTotals: initialHasDivergentTotals,
                initialCodexTurnID: initialCodexTurnID,
                initialCodexUsageRowIndex: initialCodexUsageRowIndex,
                inheritedTotalsResolver: throwingResolver,
                checkCancellation: nil)) ?? CodexParseResult(
            days: [:],
            parsedBytes: startOffset,
            scanTargetSize: startOffset,
            lastModel: initialModel,
            lastTotals: initialTotals,
            lastCountedTotals: initialTotals,
            lastRawTotalsBaseline: initialRawTotalsBaseline,
            lastRawTotalsWatermark: initialRawTotalsBaseline,
            seenRawTotals: [],
            hasDivergentTotals: initialHasDivergentTotals,
            hasInterleavedTotals: false,
            lastCodexTurnID: initialCodexTurnID,
            sessionId: nil,
            forkedFromId: nil,
            dependsOnParentTotals: false,
            projectPath: nil,
            codexSession: CostUsageCodexSessionMetadata(
                sessionId: nil,
                forkedFromId: nil,
                cwd: nil,
                title: nil,
                startedAtUnixMs: nil,
                latestActivityUnixMs: nil),
            rows: [],
            nextUsageRowIndex: initialCodexUsageRowIndex,
            tokenSnapshots: [],
            jsonlResumeState: nil,
            bufferedSubagentLines: nil,
            bufferedUnresolvedForkLines: nil)
    }
}

/// Query adapters used only by store fixtures; production reads use the shared snapshot paths.
extension CostUsageStore {
    func fetchFile(path: String) -> CostUsageStoreFile? {
        self.withDatabase(default: nil) { database in
            let statement = try Self.prepare(database, Self.fileSelectSQL + " WHERE path = ? AND home = ?")
            defer { sqlite3_finalize(statement) }
            Self.bind(path, to: statement, at: 1)
            Self.bind(self.home, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            self.scopedReadWorkRecorderForTesting?.recordFile()
            return try Self.decodeFile(statement)
        }
    }

    func fetchTokenSnapshots(path: String) -> [CostUsageStoreTokenSnapshot] {
        self.withDatabase(default: []) { database in
            try Self.readTokenSnapshots(
                database,
                path: path,
                home: self.home,
                recorder: self.scopedReadWorkRecorderForTesting)
        }
    }

    func fetchUsageRows(path: String) -> [CostUsageStoreUsageRow] {
        self.withDatabase(default: []) { database in
            try Self.readUsageRows(
                database,
                path: path,
                home: self.home,
                recorder: self.scopedReadWorkRecorderForTesting)
        }
    }

    func fetchDayAggregates(sinceDay: String, untilDay: String) -> [CostUsageStoreDayAggregate] {
        guard sinceDay <= untilDay else { return [] }
        return self.withDatabase(default: []) { database in
            try Self.readDayAggregates(database, home: self.home, sinceDay: sinceDay, untilDay: untilDay)
        }
    }

    func fetchFileDayAggregates(path: String) -> [CostUsageStoreDayAggregate] {
        self.withDatabase(default: []) { database in
            try Self.readFileDayAggregates(database, path: path, home: self.home).map(\.aggregate)
        }
    }

    func fetchForkLineage(path: String) -> CostUsageStoreForkLineage? {
        self.withDatabase(default: nil) { database in
            let values = try Self.readForkLineage(database, path: path, home: self.home)
            return values.first
        }
    }

    func fetchBufferedLines(
        path: String,
        kind: CostUsageStoreBufferedLineKind? = nil) -> [CostUsageStoreBufferedLine]
    {
        self.withDatabase(default: []) { database in
            try Self.readBufferedLines(
                database, path: path, home: self.home, kind: kind, recorder: self.scopedReadWorkRecorderForTesting)
        }
    }

    func fetchAccumulator(path: String) -> CostUsageStoreAccumulator? {
        self.withDatabase(default: nil) { database in
            try Self.readAccumulators(
                database,
                path: path,
                home: self.home,
                recorder: self.scopedReadWorkRecorderForTesting).first
        }
    }

    func readReport(sinceDay: String, untilDay: String) -> CostUsageStoreReport {
        guard sinceDay <= untilDay else {
            return CostUsageStoreReport(metadata: .empty, aggregates: [])
        }
        return self.withDatabase(default: CostUsageStoreReport(metadata: .empty, aggregates: [])) { database in
            try Self.inReadTransaction(database) {
                let metadata = try Self.readSingleton(
                    CostUsageStoreMetadata.self,
                    database: database,
                    table: "scan_metadata",
                    home: self.home) ?? .empty
                let aggregates = try Self.readDayAggregates(
                    database,
                    home: self.home,
                    sinceDay: sinceDay,
                    untilDay: untilDay)
                return CostUsageStoreReport(metadata: metadata, aggregates: aggregates)
            }
        }
    }

    /// SQLite connection counters used by persistence regression tests. These count logical
    /// row changes and cache pages flushed by this connection; they supplement, but are not a
    /// substitute for, filesystem-level write evidence.
    func persistenceWriteMetricsForTesting(resetPageCounter: Bool = false) -> (rows: Int, pages: Int) {
        self.withDatabase(default: (rows: 0, pages: 0)) { database in
            var current: Int32 = 0
            var highwater: Int32 = 0
            let result = sqlite3_db_status(
                database,
                SQLITE_DBSTATUS_CACHE_WRITE,
                &current,
                &highwater,
                resetPageCounter ? 1 : 0)
            guard result == SQLITE_OK else { throw StoreError.sqlite(result) }
            return (rows: Int(sqlite3_total_changes(database)), pages: Int(current))
        }
    }

    func setWALAutoCheckpointForTesting(_ pages: Int32) -> Bool {
        self.withDatabase(default: false) { database in
            let result = sqlite3_wal_autocheckpoint(database, pages)
            guard result == SQLITE_OK else { throw StoreError.sqlite(result) }
            return true
        }
    }

    func truncateWALForTesting() -> Bool {
        self.withDatabase(default: false) { database in
            var logFrames: Int32 = 0
            var checkpointedFrames: Int32 = 0
            let result = sqlite3_wal_checkpoint_v2(
                database,
                nil,
                SQLITE_CHECKPOINT_TRUNCATE,
                &logFrames,
                &checkpointedFrames)
            guard result == SQLITE_OK else { throw StoreError.sqlite(result) }
            return true
        }
    }
}

extension CostUsageTestEnvironment {
    var codexStoreHome: String {
        CodexHomeCostStoreScope.key(sessionsRoot: self.codexSessionsRoot)
    }
}
