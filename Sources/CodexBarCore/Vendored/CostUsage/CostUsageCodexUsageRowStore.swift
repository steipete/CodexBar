// swiftlint:disable file_length
import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Complete usage rows emitted by the Codex parser. Pricing fields are generation-bound by
/// `pricingKey` and `priorityMetadataKey`. `eventIndex` is the parser's usage-row ordinal, not
/// the token-index event ordinal; gaps are valid when an event falls outside the retained window.
struct CostUsageCodexUsageRowRecord: Equatable {
    let eventIndex: Int
    let timestampUnixMs: Int64?
    let day: String
    let model: String
    let rawModel: String?
    let turnID: String?
    let input: Int
    let cached: Int
    let output: Int
    let reasoning: Int?
    let knownCostNanos: Int64?
    let unpricedTokens: Int?
    let pricingModel: String?
    let pricingMode: String?
    let dedupKey: Data

    init?(
        row: CostUsageScanner.CodexUsageRow,
        dedupKey: Data)
    {
        guard let eventIndex = row.eventIndex else { return nil }
        self.init(
            eventIndex: eventIndex,
            timestampUnixMs: row.timestampUnixMs,
            day: row.day,
            model: row.model,
            rawModel: row.rawModel,
            turnID: row.turnID,
            input: row.input,
            cached: row.cached,
            output: row.output,
            reasoning: row.reasoning,
            knownCostNanos: row.knownCostNanos,
            unpricedTokens: row.unpricedTokens,
            pricingModel: row.pricingModel,
            pricingMode: row.pricingMode,
            dedupKey: dedupKey)
    }

    init(
        eventIndex: Int,
        timestampUnixMs: Int64?,
        day: String,
        model: String,
        rawModel: String?,
        turnID: String?,
        input: Int,
        cached: Int,
        output: Int,
        reasoning: Int?,
        knownCostNanos: Int64? = nil,
        unpricedTokens: Int? = nil,
        pricingModel: String? = nil,
        pricingMode: String? = nil,
        dedupKey: Data)
    {
        self.eventIndex = eventIndex
        self.timestampUnixMs = timestampUnixMs
        self.day = day
        self.model = model
        self.rawModel = rawModel
        self.turnID = turnID
        self.input = input
        self.cached = cached
        self.output = output
        self.reasoning = reasoning
        self.knownCostNanos = knownCostNanos
        self.unpricedTokens = unpricedTokens
        self.pricingModel = pricingModel
        self.pricingMode = pricingMode
        self.dedupKey = dedupKey
    }

    var usageRow: CostUsageScanner.CodexUsageRow {
        CostUsageScanner.CodexUsageRow(
            day: self.day,
            model: self.model,
            rawModel: self.rawModel,
            turnID: self.turnID,
            eventIndex: self.eventIndex,
            timestampUnixMs: self.timestampUnixMs,
            input: self.input,
            cached: self.cached,
            output: self.output,
            reasoning: self.reasoning,
            knownCostNanos: self.knownCostNanos,
            unpricedTokens: self.unpricedTokens,
            pricingModel: self.pricingModel,
            pricingMode: self.pricingMode)
    }
}

/// Source identity copied into a row generation. Fields that can change the meaning of an
/// already-persisted row require a new generation; ordinary source growth updates only the
/// byte cursor, anchor, completeness, and ctime.
struct CostUsageCodexUsageRowSource: Equatable {
    let path: String
    let fileId: String
    let indexedBytes: Int64
    let anchor: CostUsageCodexTokenIndexAnchor
    let isComplete: Bool
    let changeUnixNs: Int64?
    let sessionId: String?
    let forkedFromId: String?
    let forkDependencyKey: String?
    let producerKey: String
    let timeZoneIdentifier: String
}

/// Compact JSON-published cursor for one generation. SQLite may be ahead after a crash, so every
/// read is bounded by both `nextUsageRowIndex` and this prefix digest rather than by SQLite's
/// current generation cursor.
struct CostUsageCodexUsageRowSidecarState: Codable, Equatable {
    var formatVersion: Int = 1
    var generation: String
    var rowCount: Int
    var nextUsageRowIndex: Int
    var prefixDigest: String
    var coverageSinceKey: String
    var coverageUntilKey: String
    var ownershipKey: String?
    var pricingKey: String
    var priorityMetadataKey: String
}

struct CostUsageCodexUsageRowReference: Equatable {
    let source: CostUsageCodexUsageRowSource
    let state: CostUsageCodexUsageRowSidecarState
}

/// Previously imported prefix trusted by a downstream consumer. A suffix read verifies this
/// boundary against the immutable row digest chain before materializing any later rows.
struct CostUsageCodexUsageRowPrefixBoundary: Equatable {
    let generation: String
    let rowCount: Int
    let prefixDigest: String
}

enum CostUsageCodexUsageRowsLookup<Value> {
    case ready(Value)
    case needsRebuild
    case temporarilyUnavailable
}

enum CostUsageCodexUsageRowFailureDisposition: Equatable {
    case needsRebuild
    case retryLater
}

enum CostUsageCodexUsageRowRecoveryResult: Equatable {
    case notStructural
    case alreadyReset
    case quarantined(URL)
}

struct CostUsageCodexUsageRowGarbageCollectionResult: Equatable {
    let deletedGenerationCount: Int
    let deletedRowCount: Int
}

// MVCC store for complete, effective Codex usage rows. Rebuilds, ownership changes, and pricing
// metadata changes create a fresh generation, so a SQLite-first commit never destroys rows
// referenced by the previously published JSON cache. Ordinary appends stay in one generation
// and write only the new suffix.
// swiftlint:disable:next type_body_length
struct CostUsageCodexUsageRowStore: Sendable {
    private static let schemaVersion: Int32 = 2
    private static let stateFormatVersion = 1
    static let garbageCollectionMinimumInterval: TimeInterval = 60 * 60

    struct MaintenanceMetrics: Equatable {
        let fullHealthScanCount: Int
        let garbageCollectionSweepCount: Int
    }

    struct RowReadMetrics: Equatable {
        let decodedRowCount: Int
    }

    final class RowReadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var decodedRowCount = 0

        func snapshot() -> RowReadMetrics {
            self.lock.lock()
            defer { self.lock.unlock() }
            return RowReadMetrics(decodedRowCount: self.decodedRowCount)
        }

        fileprivate func recordDecodedRow() {
            self.lock.lock()
            self.decodedRowCount += 1
            self.lock.unlock()
        }
    }

    final class MaintenanceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var fullHealthScanCount = 0
        private var garbageCollectionSweepCount = 0

        func snapshot() -> MaintenanceMetrics {
            self.lock.lock()
            defer { self.lock.unlock() }
            return MaintenanceMetrics(
                fullHealthScanCount: self.fullHealthScanCount,
                garbageCollectionSweepCount: self.garbageCollectionSweepCount)
        }

        fileprivate func recordFullHealthScan() {
            self.lock.lock()
            self.fullHealthScanCount += 1
            self.lock.unlock()
        }

        fileprivate func recordGarbageCollectionSweep() {
            self.lock.lock()
            self.garbageCollectionSweepCount += 1
            self.lock.unlock()
        }
    }

    /// Refreshes are serialized by the cross-process Codex refresh lease. This process-local memo
    /// survives the short-lived store value created for each Finish Now pass and keeps full-table
    /// maintenance out of that pass loop. File identity, rather than mtime or size, deliberately
    /// stays stable across our own WAL-backed writes while forcing a fresh check after replacement.
    private final class MaintenanceMemo: @unchecked Sendable {
        private struct GarbageCollectionStamp {
            let fileID: String
            let attemptedAt: Date
        }

        private let lock = NSLock()
        private var healthCheckedFileIDByPath: [String: String] = [:]
        private var garbageCollectionByPath: [String: GarbageCollectionStamp] = [:]

        func needsFullHealthScan(path: String, fileID: String) -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.healthCheckedFileIDByPath[path] != fileID
        }

        func markFullHealthScanComplete(path: String, fileID: String) {
            self.lock.lock()
            self.healthCheckedFileIDByPath[path] = fileID
            self.lock.unlock()
        }

        func needsGarbageCollection(
            path: String,
            fileID: String,
            now: Date,
            minimumInterval: TimeInterval) -> Bool
        {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let stamp = self.garbageCollectionByPath[path], stamp.fileID == fileID else {
                return true
            }
            let elapsed = now.timeIntervalSince(stamp.attemptedAt)
            // A backwards clock jump must not suppress maintenance indefinitely.
            return elapsed < 0 || elapsed >= minimumInterval
        }

        func recordGarbageCollectionAttemptIfDue(
            path: String,
            fileID: String,
            now: Date,
            minimumInterval: TimeInterval) -> Bool
        {
            self.lock.lock()
            defer { self.lock.unlock() }
            if let stamp = self.garbageCollectionByPath[path], stamp.fileID == fileID {
                let elapsed = now.timeIntervalSince(stamp.attemptedAt)
                guard elapsed < 0 || elapsed >= minimumInterval else { return false }
            }
            self.garbageCollectionByPath[path] = GarbageCollectionStamp(
                fileID: fileID,
                attemptedAt: now)
            return true
        }

        func markGarbageCollectionAttempt(path: String, fileID: String, now: Date) {
            self.lock.lock()
            self.garbageCollectionByPath[path] = GarbageCollectionStamp(
                fileID: fileID,
                attemptedAt: now)
            self.lock.unlock()
        }

        func invalidate(path: String) {
            self.lock.lock()
            self.healthCheckedFileIDByPath.removeValue(forKey: path)
            self.garbageCollectionByPath.removeValue(forKey: path)
            self.lock.unlock()
        }
    }

    private static let maintenanceMemo = MaintenanceMemo()
    private let cacheRoot: URL?
    private let maintenanceRecorder: MaintenanceRecorder?
    private let rowReadRecorder: RowReadRecorder?

    init(
        cacheRoot: URL? = nil,
        maintenanceRecorder: MaintenanceRecorder? = nil,
        rowReadRecorder: RowReadRecorder? = nil)
    {
        self.cacheRoot = cacheRoot
        self.maintenanceRecorder = maintenanceRecorder
        self.rowReadRecorder = rowReadRecorder
    }

    var isAvailable: Bool {
        #if canImport(SQLite3) || canImport(CSQLite3)
        true
        #else
        false
        #endif
    }

    static func sourcePath(for fileURL: URL) -> String {
        fileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func failureDisposition(for error: Error) -> CostUsageCodexUsageRowFailureDisposition {
        guard let error = error as? StoreError else { return .retryLater }
        switch error {
        case .invalidInput, .prefixMismatch:
            return .needsRebuild
        case let .incompatibleSchema(version):
            return version > Self.schemaVersion ? .retryLater : .needsRebuild
        case .sourceAdvanced, .unavailable:
            return .retryLater
        case let .sqlite(code):
            #if canImport(SQLite3) || canImport(CSQLite3)
            switch code & 0xFF {
            case SQLITE_ERROR,
                 SQLITE_INTERNAL,
                 SQLITE_CORRUPT,
                 SQLITE_NOTADB,
                 SQLITE_SCHEMA,
                 SQLITE_CONSTRAINT,
                 SQLITE_MISMATCH,
                 SQLITE_FORMAT:
                return .needsRebuild
            default:
                return .retryLater
            }
            #else
            _ = code
            return .retryLater
            #endif
        }
    }

    /// Validates the shared database before a refresh starts publishing new references. The caller
    /// owns the refresh lease, so an older schema can be migrated before any other writer observes
    /// it. Every owned refresh still opens the database and checks its schema. The full-table quick
    /// check is process-memoized for the current database file identity, so a Finish Now catch-up
    /// loop does not rescan an ever-growing row store after every bounded JSONL slice. Structural
    /// failures invalidate the memo and force the next owned refresh through the full check and
    /// recovery.
    func validateDatabaseHealth(requireExistingDatabase: Bool) throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let url = self.databaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.maintenanceMemo.invalidate(path: url.path)
            if requireExistingDatabase { throw StoreError.prefixMismatch }
            return
        }
        let fileIDBeforeOpen = self.databaseFileID(url)
        var db: OpaquePointer? = try self.open(readOnly: true)
        if try Self.userVersion(db) == 1 {
            sqlite3_close(db)
            db = nil
            let migrationDB = try self.open(readOnly: false)
            do {
                try Self.ensureSchema(migrationDB)
                sqlite3_close(migrationDB)
            } catch {
                sqlite3_close(migrationDB)
                throw error
            }
            Self.maintenanceMemo.invalidate(path: url.path)
            db = try self.open(readOnly: true)
        }
        defer {
            if let db { sqlite3_close(db) }
        }
        do {
            try Self.beginRead(db)
            try Self.requireCurrentSchema(db)
            let fileIDAfterOpen = self.databaseFileID(url)
            let fileID = fileIDBeforeOpen == fileIDAfterOpen ? fileIDAfterOpen : nil
            let needsFullHealthScan = fileID.map {
                Self.maintenanceMemo.needsFullHealthScan(path: url.path, fileID: $0)
            } ?? true
            if needsFullHealthScan {
                self.maintenanceRecorder?.recordFullHealthScan()
                let statement = try Self.prepare(db, "PRAGMA quick_check(1)")
                defer { sqlite3_finalize(statement) }
                let result = sqlite3_step(statement)
                guard result == SQLITE_ROW else {
                    throw Self.sqliteError(db, fallbackCode: result)
                }
                guard Self.columnString(statement, at: 0) == "ok" else {
                    throw StoreError.sqlite(code: SQLITE_CORRUPT)
                }
            }
            try Self.commit(db)
            if needsFullHealthScan,
               let fileID,
               self.databaseFileID(url) == fileID
            {
                Self.maintenanceMemo.markFullHealthScanComplete(path: url.path, fileID: fileID)
            }
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            Self.rollback(db)
            self.recordDatabaseFailure(error)
            throw error
        }
        #else
        _ = requireExistingDatabase
        throw StoreError.unavailable
        #endif
    }

    /// Creates an immutable replacement generation. Reusing an identical caller-supplied
    /// generation is idempotent; a mismatched reuse fails closed.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    func createGeneration(
        source: CostUsageCodexUsageRowSource,
        records: [CostUsageCodexUsageRowRecord],
        nextUsageRowIndex: Int,
        coverageSinceKey: String,
        coverageUntilKey: String,
        ownershipKey: String? = nil,
        pricingKey: String,
        priorityMetadataKey: String,
        generation: String = UUID().uuidString) throws -> CostUsageCodexUsageRowReference
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let state = try Self.makeState(
            generation: generation,
            records: records,
            startingDigest: Self.emptyPrefixDigest,
            startingRowCount: 0,
            nextUsageRowIndex: nextUsageRowIndex,
            coverageSinceKey: coverageSinceKey,
            coverageUntilKey: coverageUntilKey,
            ownershipKey: ownershipKey,
            pricingKey: pricingKey,
            priorityMetadataKey: priorityMetadataKey)
        let reference = CostUsageCodexUsageRowReference(source: source, state: state)
        try Self.validate(reference: reference)
        try Self.validate(
            records: records,
            startingAt: 0,
            through: nextUsageRowIndex)
        try Self.validateSource(reference, requireCompleteEOF: source.isComplete)

        let db = try self.open(readOnly: false)
        defer { sqlite3_close(db) }
        do {
            try Self.ensureSchema(db)
            try Self.begin(db)
            if let existing = try Self.storedGeneration(id: generation, db: db) {
                guard existing == reference else { throw StoreError.prefixMismatch }
                try Self.requireMatchingRows(
                    records,
                    generation: generation,
                    startingRowOrdinal: 0,
                    startingDigest: Self.emptyPrefixDigest,
                    db: db)
            } else {
                try Self.insertGeneration(reference, db: db)
                let finalDigest = try Self.insertRows(
                    records,
                    generation: generation,
                    startingRowOrdinal: 0,
                    startingDigest: Self.emptyPrefixDigest,
                    db: db)
                guard finalDigest == state.prefixDigest else { throw StoreError.prefixMismatch }
            }
            // SQLite commits before JSON publication. Clearing retirement here may retain an
            // unpublished retry candidate longer, but prevents a successfully republished
            // generation from carrying an old retirement deadline into the next GC sweep.
            try Self.retainGenerationForPublication(generation, db: db)
            try Self.commit(db)
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            Self.rollback(db)
            self.recordDatabaseFailure(error)
            throw error
        }

        try Self.validateSource(reference, requireCompleteEOF: source.isComplete)
        return reference
        #else
        _ = source
        _ = records
        _ = nextUsageRowIndex
        _ = coverageSinceKey
        _ = coverageUntilKey
        _ = ownershipKey
        _ = pricingKey
        _ = priorityMetadataKey
        _ = generation
        throw StoreError.unavailable
        #endif
    }

    /// Appends only `records`. If SQLite committed one or more unpublished appends, the store
    /// validates the JSON-published prefix, rewinds only that suffix, and replays this append.
    @discardableResult
    func append(
        expected: CostUsageCodexUsageRowReference,
        updatedSource: CostUsageCodexUsageRowSource,
        records: [CostUsageCodexUsageRowRecord],
        nextUsageRowIndex: Int) throws -> CostUsageCodexUsageRowReference
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        try Self.validate(reference: expected)
        try Self.validateAppendSource(expected: expected.source, updated: updatedSource)
        guard expected.state.rowCount <= Int.max - records.count else {
            throw StoreError.invalidInput
        }
        try Self.validate(
            records: records,
            startingAt: expected.state.nextUsageRowIndex,
            through: nextUsageRowIndex)
        let updatedState = try Self.makeState(
            generation: expected.state.generation,
            records: records,
            startingDigest: expected.state.prefixDigest,
            startingRowCount: expected.state.rowCount,
            nextUsageRowIndex: nextUsageRowIndex,
            coverageSinceKey: expected.state.coverageSinceKey,
            coverageUntilKey: expected.state.coverageUntilKey,
            ownershipKey: expected.state.ownershipKey,
            pricingKey: expected.state.pricingKey,
            priorityMetadataKey: expected.state.priorityMetadataKey)
        let updated = CostUsageCodexUsageRowReference(source: updatedSource, state: updatedState)
        try Self.validate(reference: updated)
        try Self.validateSource(expected, requireCompleteEOF: false)
        try Self.validateSource(updated, requireCompleteEOF: updatedSource.isComplete)

        let db = try self.open(readOnly: false)
        defer { sqlite3_close(db) }
        do {
            try Self.ensureSchema(db)
            try Self.begin(db)
            guard var current = try Self.storedGeneration(
                id: expected.state.generation,
                db: db)
            else { throw StoreError.prefixMismatch }

            if current == updated {
                guard try Self.publishedPrefixIsAvailable(
                    current: current,
                    reference: expected,
                    db: db)
                else { throw StoreError.prefixMismatch }
                try Self.requireMatchingRows(
                    records,
                    generation: expected.state.generation,
                    startingRowOrdinal: expected.state.rowCount,
                    startingDigest: expected.state.prefixDigest,
                    db: db)
            } else {
                if current != expected {
                    guard try Self.crashAheadIsConsistent(
                        current: current,
                        expected: expected,
                        db: db)
                    else { throw StoreError.prefixMismatch }
                    try Self.rewind(current: current, to: expected, db: db)
                    current = expected
                }

                let finalDigest = try Self.insertRows(
                    records,
                    generation: expected.state.generation,
                    startingRowOrdinal: current.state.rowCount,
                    startingDigest: current.state.prefixDigest,
                    db: db)
                guard finalDigest == updated.state.prefixDigest else {
                    throw StoreError.prefixMismatch
                }
                try Self.updateGeneration(updated, db: db)
            }
            try Self.retainGenerationForPublication(expected.state.generation, db: db)
            try Self.commit(db)
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            Self.rollback(db)
            self.recordDatabaseFailure(error)
            throw error
        }

        try Self.validateSource(updated, requireCompleteEOF: updatedSource.isComplete)
        return updated
        #else
        _ = expected
        _ = updatedSource
        _ = records
        _ = nextUsageRowIndex
        throw StoreError.unavailable
        #endif
    }

    /// Loads exactly the prefix referenced by JSON. A later SQLite cursor in the same generation
    /// is ignored after the published prefix boundary and digest are validated.
    func load(
        _ reference: CostUsageCodexUsageRowReference) ->
        CostUsageCodexUsageRowsLookup<[CostUsageCodexUsageRowRecord]>
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        do {
            try Self.validate(reference: reference)
            try Self.validateSource(reference, requireCompleteEOF: false)
            guard FileManager.default.fileExists(atPath: self.databaseURL().path) else {
                return .needsRebuild
            }
            let db = try self.open(readOnly: true)
            defer { sqlite3_close(db) }
            try Self.beginRead(db)
            do {
                try Self.requireCurrentSchema(db)
                guard let current = try Self.storedGeneration(
                    id: reference.state.generation,
                    db: db),
                    try Self.publishedPrefixIsAvailable(
                        current: current,
                        reference: reference,
                        db: db)
                else { throw StoreError.prefixMismatch }
                let records = try Self.loadRows(
                    reference: reference,
                    recorder: self.rowReadRecorder,
                    db: db)
                try Self.validateSource(reference, requireCompleteEOF: false)
                try Self.commit(db)
                return .ready(records)
            } catch {
                let error = Self.capturingSQLiteError(error, db: db)
                Self.rollback(db)
                throw error
            }
        } catch {
            self.recordDatabaseFailure(error)
            return Self.lookupFailure(for: error)
        }
        #else
        _ = reference
        return .temporarilyUnavailable
        #endif
    }

    /// Loads only rows after a prefix already imported by the caller. The boundary digest is a
    /// trust anchor owned by that caller: it is checked against the row at `rowCount - 1`, while
    /// the returned suffix is independently chained through the JSON-published final digest.
    func loadSuffix(
        _ reference: CostUsageCodexUsageRowReference,
        after boundary: CostUsageCodexUsageRowPrefixBoundary) ->
        CostUsageCodexUsageRowsLookup<[CostUsageCodexUsageRowRecord]>
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        do {
            try Self.validate(reference: reference)
            try Self.validate(boundary: boundary, for: reference)
            try Self.validateSource(reference, requireCompleteEOF: false)
            guard FileManager.default.fileExists(atPath: self.databaseURL().path) else {
                return .needsRebuild
            }
            let db = try self.open(readOnly: true)
            defer { sqlite3_close(db) }
            try Self.beginRead(db)
            do {
                try Self.requireCurrentSchema(db)
                guard let current = try Self.storedGeneration(
                    id: reference.state.generation,
                    db: db),
                    try Self.publishedPrefixIsAvailable(
                        current: current,
                        reference: reference,
                        db: db),
                    try Self.prefixBoundaryIsAvailable(
                        boundary,
                        reference: reference,
                        db: db)
                else { throw StoreError.prefixMismatch }
                let records = try Self.loadSuffixRows(
                    reference: reference,
                    after: boundary,
                    recorder: self.rowReadRecorder,
                    db: db)
                try Self.validateSource(reference, requireCompleteEOF: false)
                try Self.commit(db)
                return .ready(records)
            } catch {
                let error = Self.capturingSQLiteError(error, db: db)
                Self.rollback(db)
                throw error
            }
        } catch {
            self.recordDatabaseFailure(error)
            return Self.lookupFailure(for: error)
        }
        #else
        _ = reference
        _ = boundary
        return .temporarilyUnavailable
        #endif
    }

    /// Validates that the exact JSON-published prefix is available without materializing its rows.
    /// The generation lookup and boundary probes are indexed point reads; source validation hashes
    /// only the fixed-size anchor window. Callers that already trust the published content digest
    /// can therefore validate a generation-only republish in O(1) row work.
    func validatePublishedReference(
        _ reference: CostUsageCodexUsageRowReference) -> CostUsageCodexUsageRowsLookup<Void>
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        do {
            try Self.validate(reference: reference)
            try Self.validateSource(reference, requireCompleteEOF: false)
            guard FileManager.default.fileExists(atPath: self.databaseURL().path) else {
                return .needsRebuild
            }
            let db = try self.open(readOnly: true)
            defer { sqlite3_close(db) }
            try Self.beginRead(db)
            do {
                try Self.requireCurrentSchema(db)
                guard let current = try Self.storedGeneration(
                    id: reference.state.generation,
                    db: db),
                    try Self.publishedPrefixIsAvailable(
                        current: current,
                        reference: reference,
                        db: db)
                else { throw StoreError.prefixMismatch }
                try Self.validateSource(reference, requireCompleteEOF: false)
                try Self.commit(db)
                return .ready(())
            } catch {
                let error = Self.capturingSQLiteError(error, db: db)
                Self.rollback(db)
                throw error
            }
        } catch {
            self.recordDatabaseFailure(error)
            return Self.lookupFailure(for: error)
        }
        #else
        _ = reference
        return .temporarilyUnavailable
        #endif
    }

    func contains(_ reference: CostUsageCodexUsageRowReference) -> Bool {
        if case .ready = self.validatePublishedReference(reference) { return true }
        return false
    }

    /// Finds published sources containing any requested turn without materializing their rows.
    func pathsContaining(
        turnIDs: Set<String>,
        references: [CostUsageCodexUsageRowReference]) ->
        CostUsageCodexUsageRowsLookup<Set<String>>
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard !turnIDs.isEmpty, !references.isEmpty else { return .ready([]) }
        do {
            guard FileManager.default.fileExists(atPath: self.databaseURL().path) else {
                return .needsRebuild
            }
            let db = try self.open(readOnly: true)
            defer { sqlite3_close(db) }
            try Self.beginRead(db)
            do {
                try Self.requireCurrentSchema(db)
                var paths: Set<String> = []
                let sql = """
                SELECT 1 FROM rows
                WHERE generation_id = ? AND event_index < ? AND turn_id = ?
                LIMIT 1
                """
                let statement = try Self.prepare(db, sql)
                defer { sqlite3_finalize(statement) }

                for reference in references {
                    try Self.validate(reference: reference)
                    try Self.validateSource(reference, requireCompleteEOF: false)
                    guard let current = try Self.storedGeneration(
                        id: reference.state.generation,
                        db: db),
                        try Self.publishedPrefixIsAvailable(
                            current: current,
                            reference: reference,
                            db: db)
                    else { throw StoreError.prefixMismatch }
                    if reference.state.rowCount == 0 { continue }
                    for turnID in turnIDs {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        Self.bind(reference.state.generation, to: statement, at: 1)
                        guard let nextUsageRowIndex = Self.int64(reference.state.nextUsageRowIndex) else {
                            throw StoreError.invalidInput
                        }
                        sqlite3_bind_int64(statement, 2, nextUsageRowIndex)
                        Self.bind(turnID, to: statement, at: 3)
                        let result = sqlite3_step(statement)
                        if result == SQLITE_ROW {
                            paths.insert(reference.source.path)
                            break
                        }
                        guard result == SQLITE_DONE else {
                            throw Self.sqliteError(db, fallbackCode: result)
                        }
                    }
                }
                try Self.commit(db)
                return .ready(paths)
            } catch {
                let error = Self.capturingSQLiteError(error, db: db)
                Self.rollback(db)
                throw error
            }
        } catch {
            self.recordDatabaseFailure(error)
            return Self.lookupFailure(for: error)
        }
        #else
        _ = turnIDs
        _ = references
        return .temporarilyUnavailable
        #endif
    }

    /// Quarantines the complete live SQLite family after a structural failure. The caller must
    /// hold the Codex refresh lock across this call, removal of every published row-sidecar state,
    /// and the first rebuild publication. Moving the live database aside makes every old JSON
    /// reference fail closed while preserving the damaged artifacts for diagnosis.
    @discardableResult
    func quarantineAndResetDatabaseAfterStructuralFailure(
        _ error: Error,
        fileManager: FileManager = .default) throws -> CostUsageCodexUsageRowRecoveryResult
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard Self.isStructuralFailure(error) else { return .notStructural }
        let url = self.databaseURL()
        Self.maintenanceMemo.invalidate(path: url.path)
        let artifacts = [
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-journal"),
            url,
        ].filter { fileManager.fileExists(atPath: $0.path) }
        guard !artifacts.isEmpty else { return .alreadyReset }

        let quarantineRoot = url.deletingLastPathComponent()
            .appendingPathComponent("quarantine", isDirectory: true)
        let timestamp = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let quarantineURL = quarantineRoot.appendingPathComponent(
            "usage-rows-\(timestamp)-\(UUID().uuidString)",
            isDirectory: true)
        try fileManager.createDirectory(at: quarantineURL, withIntermediateDirectories: true)

        var moved: [(source: URL, destination: URL)] = []
        do {
            // Move the main database last. If an earlier sidecar move fails, rollback can leave
            // the still-live database family intact instead of exposing a half-reset database.
            for source in artifacts {
                let destination = quarantineURL.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
            return .quarantined(quarantineURL)
        } catch {
            for pair in moved.reversed()
                where !fileManager.fileExists(atPath: pair.source.path)
                && fileManager.fileExists(atPath: pair.destination.path)
            {
                try? fileManager.moveItem(at: pair.destination, to: pair.source)
            }
            try? fileManager.removeItem(at: quarantineURL)
            throw error
        }
        #else
        _ = error
        _ = fileManager
        throw StoreError.unavailable
        #endif
    }

    /// Compatibility wrapper for callers that only need a success bit. New refresh-lock owners
    /// should call `quarantineAndResetDatabaseAfterStructuralFailure` and log the quarantine URL.
    @discardableResult
    func resetDatabaseAfterStructuralFailure(
        _ error: Error,
        fileManager: FileManager = .default) -> Bool
    {
        guard let result = try? self.quarantineAndResetDatabaseAfterStructuralFailure(
            error,
            fileManager: fileManager)
        else { return false }
        switch result {
        case .notStructural:
            return false
        case .alreadyReset, .quarantined:
            return true
        }
    }

    /// Lets the refresh owner skip reloading the published JSON generation set until a sweep is
    /// due. `garbageCollect` repeats this check before deleting anything.
    func shouldRunGarbageCollection(now: Date = Date()) -> Bool {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let url = self.databaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.maintenanceMemo.invalidate(path: url.path)
            return false
        }
        guard let fileID = self.databaseFileID(url) else { return true }
        return Self.maintenanceMemo.needsGarbageCollection(
            path: url.path,
            fileID: fileID,
            now: now,
            minimumInterval: Self.garbageCollectionMinimumInterval)
        #else
        _ = now
        return false
        #endif
    }

    /// Applies the process-local maintenance backoff when a due sweep cannot safely start, for
    /// example because the exact JSON-published generation set could not be read. This only delays
    /// deletion of unreferenced generations. A structural store failure instead preserves the
    /// invalidated memo so the replacement database is validated and maintenance is retried.
    @discardableResult
    func recordSkippedGarbageCollectionAttempt(
        now: Date = Date(),
        failure: Error? = nil) -> Bool
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        if let failure, Self.isStructuralFailure(failure) {
            self.recordDatabaseFailure(failure)
            return false
        }
        let url = self.databaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.maintenanceMemo.invalidate(path: url.path)
            return false
        }
        guard let fileID = self.databaseFileID(url) else { return false }
        return Self.maintenanceMemo.recordGarbageCollectionAttemptIfDue(
            path: url.path,
            fileID: fileID,
            now: now,
            minimumInterval: Self.garbageCollectionMinimumInterval)
        #else
        _ = now
        _ = failure
        return false
        #endif
    }

    /// Marks generations absent from the complete JSON-published set as unreferenced, then deletes
    /// only generations that have remained unreferenced for `gracePeriod`. The caller must hold the
    /// refresh lock while collecting the IDs and invoking this method, so publication cannot race
    /// the protected-set snapshot. Starting grace at retirement protects a reader that selected the
    /// previous JSON generation immediately before a concurrent replacement publication.
    @discardableResult
    func garbageCollect(
        publishedGenerationIDs: Set<String>,
        gracePeriod: TimeInterval,
        now: Date = Date()) throws -> CostUsageCodexUsageRowGarbageCollectionResult
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard publishedGenerationIDs.allSatisfy({ !$0.isEmpty }),
              gracePeriod.isFinite,
              gracePeriod >= 0,
              let nowUnixMs = Self.unixMilliseconds(now),
              let cutoffUnixMs = Self.garbageCollectionCutoffUnixMs(
                  now: now,
                  gracePeriod: gracePeriod)
        else { throw StoreError.invalidInput }
        guard FileManager.default.fileExists(atPath: self.databaseURL().path) else {
            Self.maintenanceMemo.invalidate(path: self.databaseURL().path)
            return CostUsageCodexUsageRowGarbageCollectionResult(
                deletedGenerationCount: 0,
                deletedRowCount: 0)
        }

        guard self.shouldRunGarbageCollection(now: now) else {
            // Skipping can only retain extra generations; it never weakens the published-generation
            // protection used by a real sweep.
            return CostUsageCodexUsageRowGarbageCollectionResult(
                deletedGenerationCount: 0,
                deletedRowCount: 0)
        }

        let databaseURL = self.databaseURL()
        let databaseFileID = self.databaseFileID(databaseURL)
        let db = try self.open(readOnly: false)
        defer { sqlite3_close(db) }
        do {
            try Self.ensureSchema(db)
            try Self.begin(db)
            self.maintenanceRecorder?.recordGarbageCollectionSweep()
            try Self.execute(db, """
            CREATE TEMP TABLE protected_usage_row_generations (
                id TEXT PRIMARY KEY
            ) WITHOUT ROWID
            """)
            let insert = try Self.prepare(
                db,
                "INSERT INTO protected_usage_row_generations (id) VALUES (?)")
            defer { sqlite3_finalize(insert) }
            for generation in publishedGenerationIDs.sorted() {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                Self.bind(generation, to: insert, at: 1)
                let result = sqlite3_step(insert)
                guard result == SQLITE_DONE else {
                    throw Self.sqliteError(db, fallbackCode: result)
                }
            }

            try Self.execute(db, """
            UPDATE generations
            SET unreferenced_at_ms = NULL
            WHERE id IN (SELECT id FROM protected_usage_row_generations)
            """)
            let retire = try Self.prepare(
                db,
                """
                UPDATE generations
                SET unreferenced_at_ms = ?
                WHERE unreferenced_at_ms IS NULL
                AND id NOT IN (SELECT id FROM protected_usage_row_generations)
                """)
            defer { sqlite3_finalize(retire) }
            sqlite3_bind_int64(retire, 1, nowUnixMs)
            let retireResult = sqlite3_step(retire)
            guard retireResult == SQLITE_DONE else {
                throw Self.sqliteError(db, fallbackCode: retireResult)
            }

            let eligibleClause = """
            unreferenced_at_ms < ?
            AND id NOT IN (SELECT id FROM protected_usage_row_generations)
            """
            let rowCount = try Self.count(
                db,
                sql: """
                SELECT COUNT(*) FROM rows
                WHERE generation_id IN (
                    SELECT id FROM generations WHERE \(eligibleClause)
                )
                """,
                int64: cutoffUnixMs)
            let delete = try Self.prepare(
                db,
                "DELETE FROM generations WHERE \(eligibleClause)")
            defer { sqlite3_finalize(delete) }
            sqlite3_bind_int64(delete, 1, cutoffUnixMs)
            let deleteResult = sqlite3_step(delete)
            guard deleteResult == SQLITE_DONE else {
                throw Self.sqliteError(db, fallbackCode: deleteResult)
            }
            let generationCount = Int(sqlite3_changes(db))
            try Self.commit(db)
            if let databaseFileID,
               self.databaseFileID(databaseURL) == databaseFileID
            {
                Self.maintenanceMemo.markGarbageCollectionAttempt(
                    path: databaseURL.path,
                    fileID: databaseFileID,
                    now: now)
            }
            return CostUsageCodexUsageRowGarbageCollectionResult(
                deletedGenerationCount: generationCount,
                deletedRowCount: rowCount)
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            Self.rollback(db)
            self.recordDatabaseFailure(error)
            throw error
        }
        #else
        _ = publishedGenerationIDs
        _ = gracePeriod
        _ = now
        throw StoreError.unavailable
        #endif
    }

    func databaseURL() -> URL {
        let root = self.cacheRoot
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("codex-usage-rows-v1.sqlite", isDirectory: false)
    }

    private func databaseFileID(_ url: URL) -> String? {
        CostUsageScanner.codexFileMetadata(fileURL: url).fileId
    }

    /// Rearms full validation after a store operation observes structural SQLite damage. The
    /// scanner calls this for write-path errors caught above the store's transaction boundary.
    func recordDatabaseFailure(_ error: Error) {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard Self.isStructuralFailure(error) else { return }
        Self.maintenanceMemo.invalidate(path: self.databaseURL().path)
        #else
        _ = error
        #endif
    }

    enum StoreError: Error, Equatable {
        case unavailable
        case sqlite(code: Int32)
        case incompatibleSchema(version: Int32)
        case invalidInput
        case prefixMismatch
        case sourceAdvanced
    }
}

#if canImport(SQLite3) || canImport(CSQLite3)
extension CostUsageCodexUsageRowStore {
    private static func isStructuralFailure(_ error: Error) -> Bool {
        guard case let StoreError.sqlite(code) = error else { return false }
        switch code & 0xFF {
        case SQLITE_ERROR,
             SQLITE_INTERNAL,
             SQLITE_CORRUPT,
             SQLITE_NOTADB,
             SQLITE_SCHEMA,
             SQLITE_FORMAT:
            return true
        default:
            return false
        }
    }

    private static func garbageCollectionCutoffUnixMs(
        now: Date,
        gracePeriod: TimeInterval) -> Int64?
    {
        let cutoff = (now.timeIntervalSince1970 - gracePeriod) * 1000
        guard cutoff.isFinite,
              cutoff >= Double(Int64.min),
              cutoff <= Double(Int64.max)
        else { return nil }
        return Int64(cutoff.rounded(.down))
    }

    private static func unixMilliseconds(_ date: Date) -> Int64? {
        let milliseconds = date.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max)
        else { return nil }
        return Int64(milliseconds.rounded(.down))
    }

    private func open(readOnly: Bool) throws -> OpaquePointer {
        let url = self.databaseURL()
        if !readOnly {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let error = Self.sqliteError(db, fallbackCode: result)
            sqlite3_close(db)
            self.recordDatabaseFailure(error)
            throw error
        }
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 1000)
        let foreignKeys = sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        guard foreignKeys == SQLITE_OK else {
            let error = Self.sqliteError(db, fallbackCode: foreignKeys)
            sqlite3_close(db)
            self.recordDatabaseFailure(error)
            throw error
        }
        if !readOnly {
            let journal = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
            guard journal == SQLITE_OK else {
                let error = Self.sqliteError(db, fallbackCode: journal)
                sqlite3_close(db)
                self.recordDatabaseFailure(error)
                throw error
            }
            // JSON publishes only after this SQLite transaction returns. FULL is intentional:
            // the database commit must reach durable storage before a JSON reference to it can
            // survive a power loss. If JSON is lost instead, ordinary SQLite-ahead recovery is safe.
            let synchronous = sqlite3_exec(db, "PRAGMA synchronous = FULL", nil, nil, nil)
            guard synchronous == SQLITE_OK else {
                let error = Self.sqliteError(db, fallbackCode: synchronous)
                sqlite3_close(db)
                self.recordDatabaseFailure(error)
                throw error
            }
        }
        return db
    }

    private static func ensureSchema(_ db: OpaquePointer?) throws {
        try self.begin(db)
        do {
            let current = try Self.userVersion(db)
            switch current {
            case 0:
                try Self.execute(db, """
                CREATE TABLE generations (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    file_id TEXT NOT NULL,
                    indexed_bytes INTEGER NOT NULL CHECK (indexed_bytes > 0),
                    anchor_indexed_bytes INTEGER NOT NULL CHECK (anchor_indexed_bytes > 0),
                    anchor_window_start INTEGER NOT NULL CHECK (anchor_window_start >= 0),
                    anchor_sha256 TEXT NOT NULL,
                    is_complete INTEGER NOT NULL CHECK (is_complete IN (0, 1)),
                    change_unix_ns INTEGER,
                    session_id TEXT,
                    forked_from_id TEXT,
                    fork_dependency_key TEXT,
                    producer_key TEXT NOT NULL,
                    timezone_id TEXT NOT NULL,
                    coverage_since TEXT NOT NULL,
                    coverage_until TEXT NOT NULL,
                    ownership_key TEXT,
                    pricing_key TEXT NOT NULL,
                    priority_metadata_key TEXT NOT NULL,
                    next_usage_row_index INTEGER NOT NULL CHECK (next_usage_row_index >= 0),
                    row_count INTEGER NOT NULL CHECK (row_count >= 0),
                    prefix_digest TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    unreferenced_at_ms INTEGER
                );
                CREATE TABLE rows (
                    generation_id TEXT NOT NULL REFERENCES generations(id) ON DELETE CASCADE,
                    event_index INTEGER NOT NULL CHECK (event_index >= 0),
                    row_ordinal INTEGER NOT NULL CHECK (row_ordinal >= 0),
                    timestamp_ms INTEGER,
                    day TEXT NOT NULL,
                    model TEXT NOT NULL,
                    raw_model TEXT,
                    turn_id TEXT,
                    input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
                    cached_input_tokens INTEGER NOT NULL CHECK (cached_input_tokens >= 0),
                    output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
                    reasoning_tokens INTEGER,
                    known_cost_nanos INTEGER,
                    unpriced_tokens INTEGER,
                    pricing_model TEXT,
                    pricing_mode TEXT,
                    dedup_key BLOB NOT NULL,
                    prefix_digest TEXT NOT NULL,
                    PRIMARY KEY (generation_id, event_index),
                    UNIQUE (generation_id, row_ordinal)
                );
                CREATE INDEX rows_turn ON rows (turn_id, generation_id);
                CREATE INDEX rows_dedup ON rows (dedup_key, generation_id);
                CREATE INDEX rows_day_model ON rows (generation_id, day, model);
                CREATE INDEX generations_unreferenced
                    ON generations (unreferenced_at_ms)
                    WHERE unreferenced_at_ms IS NOT NULL;
                """)
                try Self.execute(db, "PRAGMA user_version = \(Self.schemaVersion)")
            case 1:
                try Self.execute(db, """
                ALTER TABLE generations ADD COLUMN unreferenced_at_ms INTEGER;
                CREATE INDEX generations_unreferenced
                    ON generations (unreferenced_at_ms)
                    WHERE unreferenced_at_ms IS NOT NULL;
                """)
                try Self.execute(db, "PRAGMA user_version = \(Self.schemaVersion)")
            case Self.schemaVersion:
                break
            default:
                throw StoreError.incompatibleSchema(version: current)
            }
            try Self.commit(db)
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            Self.rollback(db)
            throw error
        }
    }

    private static func requireCurrentSchema(_ db: OpaquePointer?) throws {
        let version = try Self.userVersion(db)
        guard version == Self.schemaVersion else {
            throw StoreError.incompatibleSchema(version: version)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func makeState(
        generation: String,
        records: [CostUsageCodexUsageRowRecord],
        startingDigest: String,
        startingRowCount: Int,
        nextUsageRowIndex: Int,
        coverageSinceKey: String,
        coverageUntilKey: String,
        ownershipKey: String?,
        pricingKey: String,
        priorityMetadataKey: String) throws -> CostUsageCodexUsageRowSidecarState
    {
        guard startingRowCount <= Int.max - records.count else { throw StoreError.invalidInput }
        var digest = startingDigest
        for record in records {
            digest = Self.nextDigest(previous: digest, record: record)
        }
        return CostUsageCodexUsageRowSidecarState(
            generation: generation,
            rowCount: startingRowCount + records.count,
            nextUsageRowIndex: nextUsageRowIndex,
            prefixDigest: digest,
            coverageSinceKey: coverageSinceKey,
            coverageUntilKey: coverageUntilKey,
            ownershipKey: ownershipKey,
            pricingKey: pricingKey,
            priorityMetadataKey: priorityMetadataKey)
    }

    private static func validate(reference: CostUsageCodexUsageRowReference) throws {
        let source = reference.source
        let state = reference.state
        guard !source.path.isEmpty,
              !source.fileId.isEmpty,
              source.indexedBytes > 0,
              source.anchor.indexedBytes == source.indexedBytes,
              source.anchor.windowStart >= 0,
              source.anchor.windowStart < source.anchor.indexedBytes,
              !source.anchor.sha256.isEmpty,
              !source.producerKey.isEmpty,
              !source.timeZoneIdentifier.isEmpty,
              state.formatVersion == Self.stateFormatVersion,
              !state.generation.isEmpty,
              state.rowCount >= 0,
              state.nextUsageRowIndex >= 0,
              state.rowCount <= state.nextUsageRowIndex,
              state.prefixDigest.count == 64,
              !state.coverageSinceKey.isEmpty,
              !state.coverageUntilKey.isEmpty,
              state.coverageSinceKey <= state.coverageUntilKey,
              !state.pricingKey.isEmpty,
              !state.priorityMetadataKey.isEmpty
        else { throw StoreError.invalidInput }
    }

    private static func validate(
        boundary: CostUsageCodexUsageRowPrefixBoundary,
        for reference: CostUsageCodexUsageRowReference) throws
    {
        guard !boundary.generation.isEmpty,
              boundary.generation == reference.state.generation,
              boundary.rowCount >= 0,
              boundary.rowCount <= reference.state.rowCount,
              boundary.prefixDigest.count == 64
        else { throw StoreError.invalidInput }
    }

    private static func validate(
        records: [CostUsageCodexUsageRowRecord],
        startingAt lowerBound: Int,
        through upperBound: Int) throws
    {
        guard lowerBound >= 0, upperBound >= lowerBound else { throw StoreError.invalidInput }
        var previousEventIndex: Int?
        for record in records {
            guard record.eventIndex >= lowerBound,
                  record.eventIndex < upperBound,
                  previousEventIndex.map({ record.eventIndex > $0 }) ?? true,
                  !record.day.isEmpty,
                  !record.model.isEmpty,
                  record.input >= 0,
                  record.cached >= 0,
                  record.output >= 0,
                  record.reasoning.map({ $0 >= 0 && $0 <= record.output }) ?? true,
                  record.knownCostNanos.map({ $0 >= 0 }) ?? true,
                  record.unpricedTokens.map({ $0 >= 0 }) ?? true,
                  !record.dedupKey.isEmpty,
                  Self.int64(record.eventIndex) != nil,
                  Self.int64(record.input) != nil,
                  Self.int64(record.cached) != nil,
                  Self.int64(record.output) != nil,
                  record.reasoning.flatMap(Self.int64) != nil || record.reasoning == nil,
                  record.unpricedTokens.flatMap(Self.int64) != nil || record.unpricedTokens == nil
            else { throw StoreError.invalidInput }
            previousEventIndex = record.eventIndex
        }
    }

    private static func validateAppendSource(
        expected: CostUsageCodexUsageRowSource,
        updated: CostUsageCodexUsageRowSource) throws
    {
        guard updated.path == expected.path,
              updated.fileId == expected.fileId,
              updated.indexedBytes >= expected.indexedBytes,
              updated.sessionId == expected.sessionId,
              updated.forkedFromId == expected.forkedFromId,
              updated.forkDependencyKey == expected.forkDependencyKey,
              updated.producerKey == expected.producerKey,
              updated.timeZoneIdentifier == expected.timeZoneIdentifier
        else { throw StoreError.invalidInput }
    }

    private static func validateSource(
        _ reference: CostUsageCodexUsageRowReference,
        requireCompleteEOF: Bool) throws
    {
        let fileURL = URL(fileURLWithPath: reference.source.path)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        guard metadata.fileId == reference.source.fileId,
              metadata.size >= reference.source.indexedBytes,
              CostUsageScanner.codexTokenIndexAnchorMatches(
                  reference.source.anchor,
                  fileURL: fileURL,
                  metadata: metadata)
        else { throw StoreError.prefixMismatch }
        if requireCompleteEOF, metadata.size > reference.source.indexedBytes {
            throw StoreError.sourceAdvanced
        }
    }

    private static func immutableSemanticsMatch(
        _ lhs: CostUsageCodexUsageRowReference,
        _ rhs: CostUsageCodexUsageRowReference) -> Bool
    {
        lhs.state.generation == rhs.state.generation
            && lhs.source.path == rhs.source.path
            && lhs.source.fileId == rhs.source.fileId
            && lhs.source.sessionId == rhs.source.sessionId
            && lhs.source.forkedFromId == rhs.source.forkedFromId
            && lhs.source.forkDependencyKey == rhs.source.forkDependencyKey
            && lhs.source.producerKey == rhs.source.producerKey
            && lhs.source.timeZoneIdentifier == rhs.source.timeZoneIdentifier
            && lhs.state.coverageSinceKey == rhs.state.coverageSinceKey
            && lhs.state.coverageUntilKey == rhs.state.coverageUntilKey
            && lhs.state.ownershipKey == rhs.state.ownershipKey
            && lhs.state.pricingKey == rhs.state.pricingKey
            && lhs.state.priorityMetadataKey == rhs.state.priorityMetadataKey
    }

    private static func crashAheadIsConsistent(
        current: CostUsageCodexUsageRowReference,
        expected: CostUsageCodexUsageRowReference,
        db: OpaquePointer?) throws -> Bool
    {
        guard self.immutableSemanticsMatch(current, expected),
              current.source.indexedBytes >= expected.source.indexedBytes,
              current.state.nextUsageRowIndex >= expected.state.nextUsageRowIndex,
              current.state.rowCount >= expected.state.rowCount,
              try self.publishedPrefixIsAvailable(
                  current: current,
                  reference: expected,
                  db: db),
              (try? self.validateSource(current, requireCompleteEOF: false)) != nil
        else { return false }

        return current.source.indexedBytes > expected.source.indexedBytes
            || current.state.nextUsageRowIndex > expected.state.nextUsageRowIndex
            || current.state.rowCount > expected.state.rowCount
            || current.source.anchor != expected.source.anchor
            || current.source.isComplete != expected.source.isComplete
            || current.source.changeUnixNs != expected.source.changeUnixNs
    }

    private static func publishedPrefixIsAvailable(
        current: CostUsageCodexUsageRowReference,
        reference: CostUsageCodexUsageRowReference,
        db: OpaquePointer?) throws -> Bool
    {
        guard self.immutableSemanticsMatch(current, reference),
              current.source.indexedBytes >= reference.source.indexedBytes,
              current.state.nextUsageRowIndex >= reference.state.nextUsageRowIndex,
              current.state.rowCount >= reference.state.rowCount
        else { return false }

        if reference.state.rowCount == 0 {
            let first = try Self.rowBoundary(
                generation: reference.state.generation,
                rowOrdinal: 0,
                db: db)
            return reference.state.prefixDigest == Self.emptyPrefixDigest
                && (first == nil || first!.eventIndex >= reference.state.nextUsageRowIndex)
        }

        guard let lastPublished = try rowBoundary(
            generation: reference.state.generation,
            rowOrdinal: reference.state.rowCount - 1,
            db: db),
            lastPublished.eventIndex < reference.state.nextUsageRowIndex,
            lastPublished.prefixDigest == reference.state.prefixDigest
        else { return false }

        let firstUnpublished = try Self.rowBoundary(
            generation: reference.state.generation,
            rowOrdinal: reference.state.rowCount,
            db: db)
        return firstUnpublished == nil
            || firstUnpublished!.eventIndex >= reference.state.nextUsageRowIndex
    }

    private static func prefixBoundaryIsAvailable(
        _ boundary: CostUsageCodexUsageRowPrefixBoundary,
        reference: CostUsageCodexUsageRowReference,
        db: OpaquePointer?) throws -> Bool
    {
        if boundary.rowCount == 0 {
            return boundary.prefixDigest == self.emptyPrefixDigest
        }
        guard let lastImported = try rowBoundary(
            generation: boundary.generation,
            rowOrdinal: boundary.rowCount - 1,
            db: db)
        else { return false }
        return lastImported.eventIndex < reference.state.nextUsageRowIndex
            && lastImported.prefixDigest == boundary.prefixDigest
    }

    private static func rewind(
        current: CostUsageCodexUsageRowReference,
        to expected: CostUsageCodexUsageRowReference,
        db: OpaquePointer?) throws
    {
        let statement = try Self.prepare(
            db,
            "DELETE FROM rows WHERE generation_id = ? AND event_index >= ?")
        defer { sqlite3_finalize(statement) }
        Self.bind(expected.state.generation, to: statement, at: 1)
        guard let nextUsageRowIndex = Self.int64(expected.state.nextUsageRowIndex) else {
            throw StoreError.invalidInput
        }
        sqlite3_bind_int64(statement, 2, nextUsageRowIndex)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw Self.sqliteError(db, fallbackCode: result) }
        guard let expectedDeleted = Self.int64(current.state.rowCount - expected.state.rowCount),
              Int64(sqlite3_changes(db)) == expectedDeleted
        else { throw StoreError.prefixMismatch }
        try Self.updateGeneration(expected, db: db)
    }

    private static func insertGeneration(
        _ reference: CostUsageCodexUsageRowReference,
        db: OpaquePointer?) throws
    {
        let sql = """
        INSERT INTO generations (
            id, path, file_id, indexed_bytes, anchor_indexed_bytes, anchor_window_start,
            anchor_sha256, is_complete, change_unix_ns, session_id, forked_from_id,
            fork_dependency_key, producer_key, timezone_id, coverage_since, coverage_until,
            ownership_key, pricing_key, priority_metadata_key, next_usage_row_index, row_count,
            prefix_digest, created_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try Self.bind(reference, to: statement, includeGeneration: true)
        sqlite3_bind_int64(statement, 23, Int64((Date().timeIntervalSince1970 * 1000).rounded()))
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw Self.sqliteError(db, fallbackCode: result) }
    }

    private static func updateGeneration(
        _ reference: CostUsageCodexUsageRowReference,
        db: OpaquePointer?) throws
    {
        let sql = """
        UPDATE generations SET
            path = ?, file_id = ?, indexed_bytes = ?, anchor_indexed_bytes = ?,
            anchor_window_start = ?, anchor_sha256 = ?, is_complete = ?, change_unix_ns = ?,
            session_id = ?, forked_from_id = ?, fork_dependency_key = ?, producer_key = ?,
            timezone_id = ?, coverage_since = ?, coverage_until = ?, ownership_key = ?,
            pricing_key = ?, priority_metadata_key = ?, next_usage_row_index = ?, row_count = ?,
            prefix_digest = ?
        WHERE id = ?
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try Self.bind(reference, to: statement, includeGeneration: false)
        Self.bind(reference.state.generation, to: statement, at: 22)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            if result != SQLITE_DONE { throw Self.sqliteError(db, fallbackCode: result) }
            throw StoreError.prefixMismatch
        }
    }

    private static func retainGenerationForPublication(
        _ generation: String,
        db: OpaquePointer?) throws
    {
        let statement = try Self.prepare(
            db,
            "UPDATE generations SET unreferenced_at_ms = NULL WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        Self.bind(generation, to: statement, at: 1)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw Self.sqliteError(db, fallbackCode: result) }
    }

    private static func bind(
        _ reference: CostUsageCodexUsageRowReference,
        to statement: OpaquePointer?,
        includeGeneration: Bool) throws
    {
        let start: Int32 = includeGeneration ? 2 : 1
        if includeGeneration {
            Self.bind(reference.state.generation, to: statement, at: 1)
        }
        let source = reference.source
        let state = reference.state
        Self.bind(source.path, to: statement, at: start)
        Self.bind(source.fileId, to: statement, at: start + 1)
        sqlite3_bind_int64(statement, start + 2, source.indexedBytes)
        sqlite3_bind_int64(statement, start + 3, source.anchor.indexedBytes)
        sqlite3_bind_int64(statement, start + 4, source.anchor.windowStart)
        Self.bind(source.anchor.sha256, to: statement, at: start + 5)
        sqlite3_bind_int(statement, start + 6, source.isComplete ? 1 : 0)
        Self.bind(source.changeUnixNs, to: statement, at: start + 7)
        Self.bind(source.sessionId, to: statement, at: start + 8)
        Self.bind(source.forkedFromId, to: statement, at: start + 9)
        Self.bind(source.forkDependencyKey, to: statement, at: start + 10)
        Self.bind(source.producerKey, to: statement, at: start + 11)
        Self.bind(source.timeZoneIdentifier, to: statement, at: start + 12)
        Self.bind(state.coverageSinceKey, to: statement, at: start + 13)
        Self.bind(state.coverageUntilKey, to: statement, at: start + 14)
        Self.bind(state.ownershipKey, to: statement, at: start + 15)
        Self.bind(state.pricingKey, to: statement, at: start + 16)
        Self.bind(state.priorityMetadataKey, to: statement, at: start + 17)
        guard let nextUsageRowIndex = Self.int64(state.nextUsageRowIndex),
              let rowCount = Self.int64(state.rowCount)
        else { throw StoreError.invalidInput }
        sqlite3_bind_int64(statement, start + 18, nextUsageRowIndex)
        sqlite3_bind_int64(statement, start + 19, rowCount)
        Self.bind(state.prefixDigest, to: statement, at: start + 20)
    }

    private static func storedGeneration(
        id: String,
        db: OpaquePointer?) throws -> CostUsageCodexUsageRowReference?
    {
        let sql = """
        SELECT path, file_id, indexed_bytes, anchor_indexed_bytes, anchor_window_start,
               anchor_sha256, is_complete, change_unix_ns, session_id, forked_from_id,
               fork_dependency_key, producer_key, timezone_id, coverage_since, coverage_until,
               ownership_key, pricing_key, priority_metadata_key, next_usage_row_index,
               row_count, prefix_digest
        FROM generations WHERE id = ?
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        Self.bind(id, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW,
              let path = Self.columnString(statement, at: 0),
              let fileId = Self.columnString(statement, at: 1),
              let anchorSHA256 = Self.columnString(statement, at: 5),
              [0, 1].contains(sqlite3_column_int(statement, 6)),
              let producerKey = Self.columnString(statement, at: 11),
              let timeZoneIdentifier = Self.columnString(statement, at: 12),
              let coverageSinceKey = Self.columnString(statement, at: 13),
              let coverageUntilKey = Self.columnString(statement, at: 14),
              let pricingKey = Self.columnString(statement, at: 16),
              let priorityMetadataKey = Self.columnString(statement, at: 17),
              let nextUsageRowIndex = Int(exactly: sqlite3_column_int64(statement, 18)),
              let rowCount = Int(exactly: sqlite3_column_int64(statement, 19)),
              let prefixDigest = Self.columnString(statement, at: 20)
        else {
            if result != SQLITE_ROW { throw Self.sqliteError(db, fallbackCode: result) }
            throw StoreError.prefixMismatch
        }
        let reference = CostUsageCodexUsageRowReference(
            source: CostUsageCodexUsageRowSource(
                path: path,
                fileId: fileId,
                indexedBytes: sqlite3_column_int64(statement, 2),
                anchor: CostUsageCodexTokenIndexAnchor(
                    indexedBytes: sqlite3_column_int64(statement, 3),
                    windowStart: sqlite3_column_int64(statement, 4),
                    sha256: anchorSHA256),
                isComplete: sqlite3_column_int(statement, 6) == 1,
                changeUnixNs: Self.columnInt64(statement, at: 7),
                sessionId: Self.columnString(statement, at: 8),
                forkedFromId: Self.columnString(statement, at: 9),
                forkDependencyKey: Self.columnString(statement, at: 10),
                producerKey: producerKey,
                timeZoneIdentifier: timeZoneIdentifier),
            state: CostUsageCodexUsageRowSidecarState(
                generation: id,
                rowCount: rowCount,
                nextUsageRowIndex: nextUsageRowIndex,
                prefixDigest: prefixDigest,
                coverageSinceKey: coverageSinceKey,
                coverageUntilKey: coverageUntilKey,
                ownershipKey: Self.columnString(statement, at: 15),
                pricingKey: pricingKey,
                priorityMetadataKey: priorityMetadataKey))
        try Self.validate(reference: reference)
        return reference
    }

    private static func insertRows(
        _ records: [CostUsageCodexUsageRowRecord],
        generation: String,
        startingRowOrdinal: Int,
        startingDigest: String,
        db: OpaquePointer?) throws -> String
    {
        guard !records.isEmpty else { return startingDigest }
        let sql = """
        INSERT INTO rows (
            generation_id, event_index, row_ordinal, timestamp_ms, day, model, raw_model,
            turn_id, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens,
            known_cost_nanos, unpriced_tokens, pricing_model, pricing_mode, dedup_key,
            prefix_digest
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        var digest = startingDigest
        for (offset, record) in records.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            Self.bind(generation, to: statement, at: 1)
            guard let eventIndex = Self.int64(record.eventIndex),
                  startingRowOrdinal <= Int.max - offset,
                  let rowOrdinal = Self.int64(startingRowOrdinal + offset),
                  let input = Self.int64(record.input),
                  let cached = Self.int64(record.cached),
                  let output = Self.int64(record.output)
            else { throw StoreError.invalidInput }
            sqlite3_bind_int64(statement, 2, eventIndex)
            sqlite3_bind_int64(statement, 3, rowOrdinal)
            Self.bind(record.timestampUnixMs, to: statement, at: 4)
            Self.bind(record.day, to: statement, at: 5)
            Self.bind(record.model, to: statement, at: 6)
            Self.bind(record.rawModel, to: statement, at: 7)
            Self.bind(record.turnID, to: statement, at: 8)
            sqlite3_bind_int64(statement, 9, input)
            sqlite3_bind_int64(statement, 10, cached)
            sqlite3_bind_int64(statement, 11, output)
            Self.bind(record.reasoning.flatMap(Self.int64), to: statement, at: 12)
            Self.bind(record.knownCostNanos, to: statement, at: 13)
            Self.bind(record.unpricedTokens.flatMap(Self.int64), to: statement, at: 14)
            Self.bind(record.pricingModel, to: statement, at: 15)
            Self.bind(record.pricingMode, to: statement, at: 16)
            Self.bind(record.dedupKey, to: statement, at: 17)
            digest = Self.nextDigest(previous: digest, record: record)
            Self.bind(digest, to: statement, at: 18)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else { throw Self.sqliteError(db, fallbackCode: result) }
        }
        return digest
    }

    private static func requireMatchingRows(
        _ records: [CostUsageCodexUsageRowRecord],
        generation: String,
        startingRowOrdinal: Int,
        startingDigest: String,
        db: OpaquePointer?) throws
    {
        let sql = """
        SELECT event_index, timestamp_ms, day, model, raw_model, turn_id, input_tokens,
               cached_input_tokens, output_tokens, reasoning_tokens, known_cost_nanos,
               unpriced_tokens, pricing_model, pricing_mode, dedup_key, prefix_digest
        FROM rows
        WHERE generation_id = ? AND row_ordinal >= ? AND row_ordinal < ?
        ORDER BY row_ordinal
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        Self.bind(generation, to: statement, at: 1)
        guard let lower = Self.int64(startingRowOrdinal),
              startingRowOrdinal <= Int.max - records.count,
              let upper = Self.int64(startingRowOrdinal + records.count)
        else { throw StoreError.invalidInput }
        sqlite3_bind_int64(statement, 2, lower)
        sqlite3_bind_int64(statement, 3, upper)
        var digest = startingDigest
        for expected in records {
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW,
                  let stored = Self.rowRecord(statement),
                  stored.record == expected
            else {
                if result != SQLITE_ROW, result != SQLITE_DONE {
                    throw Self.sqliteError(db, fallbackCode: result)
                }
                throw StoreError.prefixMismatch
            }
            digest = Self.nextDigest(previous: digest, record: expected)
            guard stored.prefixDigest == digest else { throw StoreError.prefixMismatch }
        }
        let trailing = sqlite3_step(statement)
        guard trailing == SQLITE_DONE else {
            if trailing != SQLITE_ROW { throw Self.sqliteError(db, fallbackCode: trailing) }
            throw StoreError.prefixMismatch
        }
    }

    private static func loadRows(
        reference: CostUsageCodexUsageRowReference,
        recorder: RowReadRecorder?,
        db: OpaquePointer?) throws -> [CostUsageCodexUsageRowRecord]
    {
        let sql = """
        SELECT event_index, timestamp_ms, day, model, raw_model, turn_id, input_tokens,
               cached_input_tokens, output_tokens, reasoning_tokens, known_cost_nanos,
               unpriced_tokens, pricing_model, pricing_mode, dedup_key, prefix_digest
        FROM rows
        WHERE generation_id = ? AND event_index < ?
        ORDER BY row_ordinal
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        Self.bind(reference.state.generation, to: statement, at: 1)
        guard let nextUsageRowIndex = Self.int64(reference.state.nextUsageRowIndex) else {
            throw StoreError.invalidInput
        }
        sqlite3_bind_int64(statement, 2, nextUsageRowIndex)

        var records: [CostUsageCodexUsageRowRecord] = []
        records.reserveCapacity(reference.state.rowCount)
        var digest = Self.emptyPrefixDigest
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let stored = Self.rowRecord(statement) else { throw StoreError.prefixMismatch }
            recorder?.recordDecodedRow()
            digest = Self.nextDigest(previous: digest, record: stored.record)
            guard stored.prefixDigest == digest else { throw StoreError.prefixMismatch }
            records.append(stored.record)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE,
              records.count == reference.state.rowCount,
              digest == reference.state.prefixDigest
        else {
            if result != SQLITE_DONE { throw Self.sqliteError(db, fallbackCode: result) }
            throw StoreError.prefixMismatch
        }
        return records
    }

    private static func loadSuffixRows(
        reference: CostUsageCodexUsageRowReference,
        after boundary: CostUsageCodexUsageRowPrefixBoundary,
        recorder: RowReadRecorder?,
        db: OpaquePointer?) throws -> [CostUsageCodexUsageRowRecord]
    {
        let sql = """
        SELECT event_index, timestamp_ms, day, model, raw_model, turn_id, input_tokens,
               cached_input_tokens, output_tokens, reasoning_tokens, known_cost_nanos,
               unpriced_tokens, pricing_model, pricing_mode, dedup_key, prefix_digest
        FROM rows
        WHERE generation_id = ? AND row_ordinal >= ? AND row_ordinal < ?
        ORDER BY row_ordinal
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        Self.bind(reference.state.generation, to: statement, at: 1)
        guard let lower = Self.int64(boundary.rowCount),
              let upper = Self.int64(reference.state.rowCount)
        else { throw StoreError.invalidInput }
        sqlite3_bind_int64(statement, 2, lower)
        sqlite3_bind_int64(statement, 3, upper)

        let expectedCount = reference.state.rowCount - boundary.rowCount
        var records: [CostUsageCodexUsageRowRecord] = []
        records.reserveCapacity(expectedCount)
        var digest = boundary.prefixDigest
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let stored = Self.rowRecord(statement) else { throw StoreError.prefixMismatch }
            recorder?.recordDecodedRow()
            digest = Self.nextDigest(previous: digest, record: stored.record)
            guard stored.prefixDigest == digest else { throw StoreError.prefixMismatch }
            records.append(stored.record)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE,
              records.count == expectedCount,
              digest == reference.state.prefixDigest
        else {
            if result != SQLITE_DONE { throw Self.sqliteError(db, fallbackCode: result) }
            throw StoreError.prefixMismatch
        }
        return records
    }

    private static func rowRecord(
        _ statement: OpaquePointer?) -> (record: CostUsageCodexUsageRowRecord, prefixDigest: String)?
    {
        guard let eventIndex = Int(exactly: sqlite3_column_int64(statement, 0)),
              let day = columnString(statement, at: 2),
              let model = columnString(statement, at: 3),
              let input = Int(exactly: sqlite3_column_int64(statement, 6)),
              let cached = Int(exactly: sqlite3_column_int64(statement, 7)),
              let output = Int(exactly: sqlite3_column_int64(statement, 8)),
              let dedupKey = columnData(statement, at: 14),
              let prefixDigest = columnString(statement, at: 15)
        else { return nil }
        let reasoning = Self.columnInt64(statement, at: 9).flatMap(Int.init(exactly:))
        if sqlite3_column_type(statement, 9) != SQLITE_NULL, reasoning == nil { return nil }
        let unpricedTokens = Self.columnInt64(statement, at: 11).flatMap(Int.init(exactly:))
        if sqlite3_column_type(statement, 11) != SQLITE_NULL, unpricedTokens == nil { return nil }
        return (
            CostUsageCodexUsageRowRecord(
                eventIndex: eventIndex,
                timestampUnixMs: Self.columnInt64(statement, at: 1),
                day: day,
                model: model,
                rawModel: Self.columnString(statement, at: 4),
                turnID: Self.columnString(statement, at: 5),
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning,
                knownCostNanos: Self.columnInt64(statement, at: 10),
                unpricedTokens: unpricedTokens,
                pricingModel: Self.columnString(statement, at: 12),
                pricingMode: Self.columnString(statement, at: 13),
                dedupKey: dedupKey),
            prefixDigest)
    }

    private struct RowBoundary {
        let eventIndex: Int
        let prefixDigest: String
    }

    private static func rowBoundary(
        generation: String,
        rowOrdinal: Int,
        db: OpaquePointer?) throws -> RowBoundary?
    {
        let statement = try Self.prepare(
            db,
            "SELECT event_index, prefix_digest FROM rows WHERE generation_id = ? AND row_ordinal = ?")
        defer { sqlite3_finalize(statement) }
        Self.bind(generation, to: statement, at: 1)
        guard let rowOrdinal = Self.int64(rowOrdinal) else { throw StoreError.invalidInput }
        sqlite3_bind_int64(statement, 2, rowOrdinal)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW,
              let eventIndex = Int(exactly: sqlite3_column_int64(statement, 0)),
              let prefixDigest = Self.columnString(statement, at: 1)
        else {
            if result != SQLITE_ROW { throw Self.sqliteError(db, fallbackCode: result) }
            throw StoreError.prefixMismatch
        }
        return RowBoundary(eventIndex: eventIndex, prefixDigest: prefixDigest)
    }

    private static var emptyPrefixDigest: String {
        sha256Hex(Data())
    }

    private static func nextDigest(
        previous: String,
        record: CostUsageCodexUsageRowRecord) -> String
    {
        var data = Data(previous.utf8)
        Self.append(record.eventIndex, to: &data)
        Self.append(record.timestampUnixMs, to: &data)
        Self.append(record.day, to: &data)
        Self.append(record.model, to: &data)
        Self.append(record.rawModel, to: &data)
        Self.append(record.turnID, to: &data)
        Self.append(record.input, to: &data)
        Self.append(record.cached, to: &data)
        Self.append(record.output, to: &data)
        Self.append(record.reasoning, to: &data)
        Self.append(record.knownCostNanos, to: &data)
        Self.append(record.unpricedTokens, to: &data)
        Self.append(record.pricingModel, to: &data)
        Self.append(record.pricingMode, to: &data)
        Self.append(record.dedupKey, to: &data)
        return Self.sha256Hex(data)
    }

    private static func append(_ value: Int, to data: inout Data) {
        self.append(Int64(value), to: &data)
    }

    private static func append(_ value: Int?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        Self.append(Int64(value), to: &data)
    }

    private static func append(_ value: Int64?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        Self.append(value, to: &data)
    }

    private static func append(_ value: Int64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: String?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        Self.append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: String, to data: inout Data) {
        data.append(1)
        self.append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        self.append(Int64(value.count), to: &data)
        data.append(value)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func begin(_ db: OpaquePointer?) throws {
        try self.execute(db, "BEGIN IMMEDIATE")
    }

    private static func beginRead(_ db: OpaquePointer?) throws {
        try self.execute(db, "BEGIN")
    }

    private static func commit(_ db: OpaquePointer?) throws {
        try self.execute(db, "COMMIT")
    }

    private static func rollback(_ db: OpaquePointer?) {
        try? self.execute(db, "ROLLBACK")
    }

    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw Self.sqliteError(db, fallbackCode: result) }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw Self.sqliteError(db, fallbackCode: result)
        }
        return statement
    }

    private static func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private static func bind(_ value: Int64?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private static func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.sqliteTransient)
        }
    }

    private static func columnString(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private static func columnInt64(_ statement: OpaquePointer?, at index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, index)
    }

    private static func columnData(_ statement: OpaquePointer?, at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static func int64(_ value: Int) -> Int64? {
        Int64(exactly: value)
    }

    private static func userVersion(_ db: OpaquePointer?) throws -> Int32 {
        let statement = try Self.prepare(db, "PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw Self.sqliteError(db, fallbackCode: result == SQLITE_DONE ? SQLITE_ERROR : result)
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func count(
        _ db: OpaquePointer?,
        sql: String,
        int64: Int64) throws -> Int
    {
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, int64)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW,
              let count = Int(exactly: sqlite3_column_int64(statement, 0))
        else {
            if result != SQLITE_ROW { throw Self.sqliteError(db, fallbackCode: result) }
            throw StoreError.prefixMismatch
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.prefixMismatch }
        return count
    }

    private static func sqliteError(
        _ db: OpaquePointer?,
        fallbackCode: Int32) -> StoreError
    {
        let captured = db.map { sqlite3_extended_errcode($0) } ?? fallbackCode
        let code = captured == SQLITE_OK ? fallbackCode : captured
        return .sqlite(code: code == SQLITE_OK ? SQLITE_ERROR : code)
    }

    private static func capturingSQLiteError(_ error: Error, db: OpaquePointer?) -> Error {
        if error is StoreError { return error }
        let code = db.map { sqlite3_extended_errcode($0) } ?? SQLITE_OK
        return code == SQLITE_OK ? error : StoreError.sqlite(code: code)
    }

    private static func lookupFailure<Value>(
        for error: Error) -> CostUsageCodexUsageRowsLookup<Value>
    {
        switch self.failureDisposition(for: error) {
        case .needsRebuild:
            .needsRebuild
        case .retryLater:
            .temporarilyUnavailable
        }
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
#endif
