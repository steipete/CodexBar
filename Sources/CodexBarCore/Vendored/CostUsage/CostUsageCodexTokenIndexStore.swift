import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct CostUsageCodexTokenIndexRecord: Equatable {
    let timestamp: String
    let timestampUnixSeconds: Double?
    let totals: CostUsageCodexTotals
    let endOffset: Int64
}

struct CostUsageCodexTokenIndexReference: Equatable {
    let path: String
    let fileId: String
    let indexedBytes: Int64
    let eventCount: Int
    let anchor: CostUsageCodexTokenIndexAnchor
    let isComplete: Bool
}

enum CostUsageCodexTokenIndexLookup {
    case ready(CostUsageCodexTotals?)
    /// The JSON-published reference is missing or no longer matches SQLite/source state.
    case needsRebuild
    /// SQLite is temporarily busy or unavailable without evidence that rebuilding will help.
    case temporarilyUnavailable
}

enum CostUsageCodexTokenIndexFailureDisposition: Equatable {
    case needsRebuild
    case retryLater
}

/// Append-only counted token totals kept outside codex-v11.json. The JSON cache is the
/// published cursor. SQLite is committed first, so a crash can leave SQLite ahead but can
/// never publish a JSON cursor whose rows were not committed.
struct CostUsageCodexTokenIndexStore: Sendable {
    private static let schemaVersion = 2
    private let cacheRoot: URL?

    final class AfterCommitHookStore: @unchecked Sendable {
        let hook: (URL) -> Void

        init(hook: @escaping (URL) -> Void) {
            self.hook = hook
        }
    }

    @TaskLocal private static var afterCommitHookStore: AfterCommitHookStore?

    #if canImport(SQLite3) || canImport(CSQLite3)
    private struct TimestampOrdering: Equatable {
        var isMonotonic: Bool
        var lastUnixSeconds: Double?

        static let empty = Self(isMonotonic: true, lastUnixSeconds: nil)

        mutating func append(_ record: CostUsageCodexTokenIndexRecord) {
            if self.isMonotonic {
                guard let timestamp = record.timestampUnixSeconds,
                      self.lastUnixSeconds.map({ timestamp >= $0 }) ?? true
                else {
                    self.isMonotonic = false
                    self.lastUnixSeconds = record.timestampUnixSeconds
                    return
                }
            }
            self.lastUnixSeconds = record.timestampUnixSeconds
        }
    }

    private struct StoredSource {
        let reference: CostUsageCodexTokenIndexReference
        let timestampOrdering: TimestampOrdering
    }
    #endif

    init(cacheRoot: URL? = nil) {
        self.cacheRoot = cacheRoot
    }

    static func withAfterCommitHookForTesting<T>(
        _ hook: @escaping (URL) -> Void,
        operation: () throws -> T) rethrows -> T
    {
        try self.$afterCommitHookStore.withValue(.init(hook: hook)) {
            try operation()
        }
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

    /// Tells append/rebuild callers whether retrying the same published cursor is safe or the
    /// sidecar must be rebuilt. SQLite result codes are captured before rollback so a rollback
    /// cannot turn a structural failure into a generic retry.
    static func failureDisposition(for error: Error) -> CostUsageCodexTokenIndexFailureDisposition {
        guard let error = error as? StoreError else { return .retryLater }
        switch error {
        case .invalidInput, .prefixMismatch, .incompatibleSchema:
            return .needsRebuild
        case .sourceAdvanced:
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
        case .unavailable:
            return .retryLater
        }
    }

    /// Replaces one path's complete persisted prefix. This is used for first import, legacy
    /// migration, and a validated rebuild after the source identity or anchor changed.
    @discardableResult
    func replace(
        reference: CostUsageCodexTokenIndexReference,
        records: [CostUsageCodexTokenIndexRecord]) throws -> CostUsageCodexTokenIndexReference
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        try Self.validate(reference: reference)
        try Self.validate(records: records, after: 0, through: reference.indexedBytes)
        guard records.count == reference.eventCount else { throw StoreError.invalidInput }
        try Self.validateCommittedReference(reference)
        let committedReference = reference

        let db = try self.open(readOnly: false)
        defer { sqlite3_close(db) }
        try Self.ensureSchema(db)
        try Self.begin(db)
        do {
            let sourceID = try Self.sourceID(
                path: reference.path,
                db: db,
                createIfMissing: true)
            try Self.deleteEvents(sourceID: sourceID, startingAt: 0, db: db)
            let ordering = try Self.insert(
                records: records,
                sourceID: sourceID,
                startingAt: 0,
                initialOrdering: .empty,
                db: db)
            try Self.upsert(
                reference: committedReference,
                timestampOrdering: ordering,
                sourceID: sourceID,
                db: db)
            try Self.commit(db)
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            Self.rollback(db)
            throw error
        }

        // A source mutation after the preflight leaves only an unpublished DB-ahead cursor.
        // Report failure so the caller does not publish it in the JSON cache.
        Self.afterCommitHookStore?.hook(URL(fileURLWithPath: committedReference.path))
        try Self.validateCommittedReference(committedReference)
        return committedReference
        #else
        _ = reference
        _ = records
        throw StoreError.unavailable
        #endif
    }

    /// Appends only newly parsed token events while advancing `indexedBytes` even when the
    /// suffix contains no token event. `expected` is the JSON-published cursor and therefore
    /// controls recovery if a previous SQLite transaction committed just before a crash.
    @discardableResult
    func append(
        expected: CostUsageCodexTokenIndexReference,
        updated: CostUsageCodexTokenIndexReference,
        records: [CostUsageCodexTokenIndexRecord]) throws -> CostUsageCodexTokenIndexReference
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        try Self.validate(reference: expected)
        try Self.validate(reference: updated)
        guard updated.path == expected.path,
              updated.fileId == expected.fileId,
              expected.eventCount <= Int.max - records.count,
              updated.eventCount == expected.eventCount + records.count,
              updated.indexedBytes >= expected.indexedBytes
        else { throw StoreError.invalidInput }
        guard Self.referenceMatchesFile(expected, requireCompleteEOF: false) else {
            throw StoreError.prefixMismatch
        }
        try Self.validateCommittedReference(updated)
        let committedUpdated = updated
        try Self.validate(
            records: records,
            after: expected.indexedBytes,
            through: committedUpdated.indexedBytes)

        let db = try self.open(readOnly: false)
        defer { sqlite3_close(db) }
        try Self.ensureSchema(db)
        try Self.begin(db)
        do {
            let sourceID = try Self.sourceID(
                path: expected.path,
                db: db,
                createIfMissing: false)
            var current = try Self.storedSource(
                path: expected.path,
                sourceID: sourceID,
                db: db)

            if current.reference == committedUpdated {
                // Idempotently adopt a transaction that committed before its JSON cursor was
                // saved, but only if the exact suffix rows agree with this retry.
                try Self.requireMatchingRecords(
                    records,
                    sourceID: sourceID,
                    startingAt: expected.eventCount,
                    db: db)
                try Self.commit(db)
            } else {
                if current.reference != expected {
                    // SQLite can be one or more transactions ahead after JSON save failures.
                    // Validate only the ahead cursor/anchor and first unpublished event; the
                    // transaction cursor plus immutable PK prefix makes a historical scan
                    // redundant. Rewind work is proportional only to the unpublished suffix.
                    guard try Self.crashAheadIsConsistent(
                        current: current.reference,
                        expected: expected,
                        sourceID: sourceID,
                        db: db)
                    else { throw StoreError.prefixMismatch }
                    try Self.deleteEvents(
                        sourceID: sourceID,
                        startingAt: expected.eventCount,
                        db: db)
                    let rewoundOrdering = try Self.timestampOrdering(
                        sourceID: sourceID,
                        eventCount: expected.eventCount,
                        db: db)
                    try Self.upsert(
                        reference: expected,
                        timestampOrdering: rewoundOrdering,
                        sourceID: sourceID,
                        db: db)
                    current = StoredSource(
                        reference: expected,
                        timestampOrdering: rewoundOrdering)
                }
                let updatedOrdering = try Self.insert(
                    records: records,
                    sourceID: sourceID,
                    startingAt: expected.eventCount,
                    initialOrdering: current.timestampOrdering,
                    db: db)
                try Self.upsert(
                    reference: committedUpdated,
                    timestampOrdering: updatedOrdering,
                    sourceID: sourceID,
                    db: db)
                try Self.commit(db)
            }
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            Self.rollback(db)
            throw error
        }

        Self.afterCommitHookStore?.hook(URL(fileURLWithPath: committedUpdated.path))
        try Self.validateCommittedReference(committedUpdated)
        return committedUpdated
        #else
        _ = expected
        _ = updated
        _ = records
        throw StoreError.unavailable
        #endif
    }

    func contains(_ reference: CostUsageCodexTokenIndexReference) -> Bool {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard (try? Self.validate(reference: reference)) != nil,
              Self.referenceMatchesFile(reference, requireCompleteEOF: false)
        else { return false }
        guard let db = try? self.open(readOnly: true) else { return false }
        defer { sqlite3_close(db) }
        var transactionStarted = false
        do {
            try Self.beginRead(db)
            transactionStarted = true
            let version = try Self.userVersion(db)
            guard version == Self.schemaVersion else {
                throw StoreError.incompatibleSchema(version: version)
            }
            let sourceID = try Self.sourceID(
                path: reference.path,
                db: db,
                createIfMissing: false)
            let stored = try Self.storedSource(
                path: reference.path,
                sourceID: sourceID,
                db: db)
            guard stored.reference == reference,
                  Self.referenceMatchesFile(reference, requireCompleteEOF: false)
            else { throw StoreError.prefixMismatch }
            try Self.commit(db)
            transactionStarted = false
            return true
        } catch {
            _ = Self.capturingSQLiteError(error, db: db)
            if transactionStarted { Self.rollback(db) }
            return false
        }
        #else
        _ = reference
        return false
        #endif
    }

    /// Returns the counted state after the last qualifying event in file order. This matches
    /// the inline resolver even when timestamps are equal, out of order, or partly malformed.
    func inheritedTotals(
        reference: CostUsageCodexTokenIndexReference,
        cutoffTimestamp: String,
        cutoffUnixSeconds: Double?) -> CostUsageCodexTokenIndexLookup
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard reference.isComplete,
              (try? Self.validate(reference: reference)) != nil
        else { return .needsRebuild }
        do {
            try Self.validateCommittedReference(reference)
        } catch {
            return Self.lookupFailure(for: error)
        }
        guard FileManager.default.fileExists(atPath: self.databaseURL().path) else {
            return .needsRebuild
        }
        let db: OpaquePointer
        do {
            db = try self.open(readOnly: true)
        } catch {
            return Self.lookupFailure(for: error)
        }
        defer { sqlite3_close(db) }
        var transactionStarted = false
        do {
            try Self.beginRead(db)
            transactionStarted = true
            let version = try Self.userVersion(db)
            guard version == Self.schemaVersion else {
                throw StoreError.incompatibleSchema(version: version)
            }
            let sourceID = try Self.sourceID(
                path: reference.path,
                db: db,
                createIfMissing: false)
            let stored = try Self.storedSource(
                path: reference.path,
                sourceID: sourceID,
                db: db)
            guard stored.reference == reference else { throw StoreError.prefixMismatch }

            let candidates: [(eventIndex: Int, totals: CostUsageCodexTotals)] = if let cutoffUnixSeconds,
                                                                                   cutoffUnixSeconds.isFinite
            {
                if stored.timestampOrdering.isMonotonic {
                    try [Self.monotonicNumericCandidate(
                        sourceID: sourceID,
                        eventCount: reference.eventCount,
                        cutoffUnixSeconds: cutoffUnixSeconds,
                        db: db)].compactMap(\.self)
                } else {
                    try [
                        Self.eventOrderNumericCandidate(
                            sourceID: sourceID,
                            eventCount: reference.eventCount,
                            cutoffUnixSeconds: cutoffUnixSeconds,
                            db: db),
                        Self.lexicalCandidate(
                            sourceID: sourceID,
                            eventCount: reference.eventCount,
                            cutoffTimestamp: cutoffTimestamp,
                            invalidTimestampsOnly: true,
                            db: db),
                    ].compactMap(\.self)
                }
            } else {
                try [
                    Self.lexicalCandidate(
                        sourceID: sourceID,
                        eventCount: reference.eventCount,
                        cutoffTimestamp: cutoffTimestamp,
                        invalidTimestampsOnly: false,
                        db: db),
                ].compactMap(\.self)
            }
            let result = candidates.max(by: { $0.eventIndex < $1.eventIndex })?.totals
            try Self.validateCommittedReference(reference)
            try Self.commit(db)
            transactionStarted = false
            return .ready(result)
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            if transactionStarted { Self.rollback(db) }
            return Self.lookupFailure(for: error)
        }
        #else
        _ = reference
        _ = cutoffTimestamp
        _ = cutoffUnixSeconds
        return .temporarilyUnavailable
        #endif
    }

    func removeEntries(excluding paths: Set<String>) {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard let db = try? self.open(readOnly: false) else { return }
        defer { sqlite3_close(db) }
        var transactionStarted = false
        do {
            try Self.ensureSchema(db)
            try Self.begin(db)
            transactionStarted = true
            let statement = try Self.prepare(db, "SELECT id, path FROM sources")
            var staleIDs: [Int64] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let path = Self.columnString(statement, at: 1), !paths.contains(path) else {
                    stepResult = sqlite3_step(statement)
                    continue
                }
                staleIDs.append(sqlite3_column_int64(statement, 0))
                stepResult = sqlite3_step(statement)
            }
            let stepError = stepResult == SQLITE_DONE
                ? nil
                : Self.sqliteError(db, fallbackCode: stepResult)
            sqlite3_finalize(statement)
            if let stepError { throw stepError }
            for sourceID in staleIDs {
                try Self.deleteSource(sourceID: sourceID, db: db)
            }
            try Self.commit(db)
            transactionStarted = false
        } catch {
            _ = Self.capturingSQLiteError(error, db: db)
            if transactionStarted { Self.rollback(db) }
        }
        #else
        _ = paths
        #endif
    }

    /// Removes only this rebuildable cache database after SQLite proves that its current bytes or
    /// schema are structurally unusable. A future schema is deliberately preserved so an older
    /// CodexBar process cannot destroy a newer process's index.
    @discardableResult
    func resetDatabaseAfterStructuralFailure(
        _ error: Error,
        fileManager: FileManager = .default) -> Bool
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard case let StoreError.sqlite(code) = error else { return false }
        switch code & 0xFF {
        case SQLITE_ERROR,
             SQLITE_INTERNAL,
             SQLITE_CORRUPT,
             SQLITE_NOTADB,
             SQLITE_SCHEMA,
             SQLITE_FORMAT:
            break
        default:
            return false
        }

        let databaseURL = self.databaseURL()
        let artifacts = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        do {
            for artifact in artifacts where fileManager.fileExists(atPath: artifact.path) {
                try fileManager.removeItem(at: artifact)
            }
            return true
        } catch {
            return false
        }
        #else
        _ = error
        _ = fileManager
        return false
        #endif
    }

    func databaseURL() -> URL {
        let root = self.cacheRoot
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("codex-token-index-v2.sqlite", isDirectory: false)
    }

    enum StoreError: Error, Equatable {
        case unavailable
        case sqlite(code: Int32)
        case incompatibleSchema(version: Int32)
        case invalidInput
        case prefixMismatch
        /// The indexed prefix is intact, but a complete-EOF write raced with a pure append.
        case sourceAdvanced
    }
}

#if canImport(SQLite3) || canImport(CSQLite3)
extension CostUsageCodexTokenIndexStore {
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
        let openResult = sqlite3_open_v2(url.path, &db, flags, nil)
        guard openResult == SQLITE_OK, let db else {
            let error = Self.sqliteError(db, fallbackCode: openResult)
            sqlite3_close(db)
            throw error
        }
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 1000)
        let foreignKeysResult = sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        guard foreignKeysResult == SQLITE_OK else {
            let error = Self.sqliteError(db, fallbackCode: foreignKeysResult)
            sqlite3_close(db)
            throw error
        }
        if !readOnly {
            let journalResult = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
            guard journalResult == SQLITE_OK else {
                let error = Self.sqliteError(db, fallbackCode: journalResult)
                sqlite3_close(db)
                throw error
            }
            let synchronousResult = sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
            guard synchronousResult == SQLITE_OK else {
                let error = Self.sqliteError(db, fallbackCode: synchronousResult)
                sqlite3_close(db)
                throw error
            }
        }
        return db
    }

    private static func ensureSchema(_ db: OpaquePointer?) throws {
        // Serialize the version read with initialization. Reading before BEGIN IMMEDIATE lets
        // two fresh writers both act on a stale version-0 observation.
        try self.begin(db)
        do {
            let current = try Self.userVersion(db)
            guard current == 0 || current == Self.schemaVersion else {
                throw StoreError.incompatibleSchema(version: current)
            }
            if current == 0 {
                try Self.execute(db, """
                CREATE TABLE IF NOT EXISTS sources (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    file_id TEXT NOT NULL,
                    indexed_bytes INTEGER NOT NULL CHECK (indexed_bytes >= 0),
                    event_count INTEGER NOT NULL CHECK (event_count >= 0),
                    anchor_indexed_bytes INTEGER NOT NULL CHECK (anchor_indexed_bytes >= 0),
                    anchor_window_start INTEGER NOT NULL CHECK (anchor_window_start >= 0),
                    anchor_sha256 TEXT NOT NULL,
                    is_complete INTEGER NOT NULL CHECK (is_complete IN (0, 1)),
                    timestamps_monotonic INTEGER NOT NULL CHECK (timestamps_monotonic IN (0, 1)),
                    last_timestamp_unix_seconds REAL
                );
                CREATE TABLE IF NOT EXISTS events (
                    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    event_index INTEGER NOT NULL CHECK (event_index >= 0),
                    timestamp TEXT NOT NULL,
                    timestamp_unix_seconds REAL,
                    timestamp_prefix_monotonic INTEGER NOT NULL
                        CHECK (timestamp_prefix_monotonic IN (0, 1)),
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_tokens INTEGER,
                    end_offset INTEGER NOT NULL CHECK (end_offset > 0),
                    PRIMARY KEY (source_id, event_index),
                    UNIQUE (source_id, end_offset)
                );
                CREATE INDEX IF NOT EXISTS events_numeric_timestamp
                    ON events (source_id, timestamp_unix_seconds, event_index);
                CREATE INDEX IF NOT EXISTS events_lexical_timestamp
                    ON events (source_id, timestamp, event_index);
                """)
                try Self.execute(db, "PRAGMA user_version = \(Self.schemaVersion)")
            }
            try Self.commit(db)
        } catch {
            let error = Self.capturingSQLiteError(error, db: db)
            Self.rollback(db)
            throw error
        }
    }

    private static func validate(reference: CostUsageCodexTokenIndexReference) throws {
        guard !reference.path.isEmpty,
              !reference.fileId.isEmpty,
              reference.indexedBytes > 0,
              reference.eventCount >= 0,
              reference.anchor.indexedBytes == reference.indexedBytes,
              reference.anchor.windowStart >= 0,
              reference.anchor.windowStart < reference.anchor.indexedBytes,
              !reference.anchor.sha256.isEmpty
        else { throw StoreError.invalidInput }
    }

    private static func validate(
        records: [CostUsageCodexTokenIndexRecord],
        after lowerBound: Int64,
        through upperBound: Int64) throws
    {
        guard lowerBound >= 0, upperBound >= lowerBound else { throw StoreError.invalidInput }
        var previousOffset = lowerBound
        for record in records {
            guard record.endOffset > previousOffset,
                  record.endOffset <= upperBound,
                  record.timestampUnixSeconds?.isFinite != false,
                  Self.int64(record.totals.input) != nil,
                  Self.int64(record.totals.cached) != nil,
                  Self.int64(record.totals.output) != nil,
                  record.totals.reasoning.flatMap(Self.int64) != nil
                  || record.totals.reasoning == nil
            else { throw StoreError.invalidInput }
            previousOffset = record.endOffset
        }
    }

    private static func referenceMatchesFile(
        _ reference: CostUsageCodexTokenIndexReference,
        requireCompleteEOF: Bool) -> Bool
    {
        let fileURL = URL(fileURLWithPath: reference.path)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        guard metadata.fileId == reference.fileId,
              metadata.size >= reference.indexedBytes,
              !requireCompleteEOF || metadata.size == reference.indexedBytes
        else { return false }
        return CostUsageScanner.codexTokenIndexAnchorMatches(
            reference.anchor,
            fileURL: fileURL,
            metadata: metadata)
    }

    /// An incomplete reference is append-stable. A complete reference that became a prefix only
    /// after commit is intentionally left SQLite-ahead and retried from the older JSON cursor.
    private static func validateCommittedReference(
        _ reference: CostUsageCodexTokenIndexReference) throws
    {
        let fileURL = URL(fileURLWithPath: reference.path)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        guard metadata.fileId == reference.fileId,
              metadata.size >= reference.indexedBytes,
              CostUsageScanner.codexTokenIndexAnchorMatches(
                  reference.anchor,
                  fileURL: fileURL,
                  metadata: metadata)
        else { throw StoreError.prefixMismatch }
        if reference.isComplete, metadata.size > reference.indexedBytes {
            throw StoreError.sourceAdvanced
        }
    }

    private static func sourceID(
        path: String,
        db: OpaquePointer?,
        createIfMissing: Bool) throws -> Int64
    {
        let select = try Self.prepare(db, "SELECT id FROM sources WHERE path = ?")
        Self.bind(path, to: select, at: 1)
        let result = sqlite3_step(select)
        if result == SQLITE_ROW {
            let sourceID = sqlite3_column_int64(select, 0)
            sqlite3_finalize(select)
            return sourceID
        }
        let selectError = result == SQLITE_DONE
            ? nil
            : Self.sqliteError(db, fallbackCode: result)
        sqlite3_finalize(select)
        if let selectError { throw selectError }
        guard createIfMissing else { throw StoreError.prefixMismatch }

        let sql = """
        INSERT INTO sources (
            path, file_id, indexed_bytes, event_count, anchor_indexed_bytes,
            anchor_window_start, anchor_sha256, is_complete,
            timestamps_monotonic, last_timestamp_unix_seconds
        ) VALUES (?, '', 0, 0, 0, 0, '', 0, 1, NULL)
        """
        let insert = try Self.prepare(db, sql)
        defer { sqlite3_finalize(insert) }
        Self.bind(path, to: insert, at: 1)
        let insertResult = sqlite3_step(insert)
        guard insertResult == SQLITE_DONE else {
            throw Self.sqliteError(db, fallbackCode: insertResult)
        }
        return sqlite3_last_insert_rowid(db)
    }

    private static func storedSource(
        path: String,
        sourceID: Int64,
        db: OpaquePointer?) throws -> StoredSource
    {
        let sql = """
        SELECT file_id, indexed_bytes, event_count, anchor_indexed_bytes,
               anchor_window_start, anchor_sha256, is_complete,
               timestamps_monotonic, last_timestamp_unix_seconds
        FROM sources
        WHERE id = ? AND path = ?
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        Self.bind(path, to: statement, at: 2)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result != SQLITE_DONE { throw Self.sqliteError(db, fallbackCode: result) }
            throw StoreError.prefixMismatch
        }
        guard let fileID = Self.columnString(statement, at: 0),
              let eventCount = Int(exactly: sqlite3_column_int64(statement, 2)),
              let anchorSHA256 = Self.columnString(statement, at: 5),
              [0, 1].contains(sqlite3_column_int(statement, 7))
        else { throw StoreError.prefixMismatch }

        let reference = CostUsageCodexTokenIndexReference(
            path: path,
            fileId: fileID,
            indexedBytes: sqlite3_column_int64(statement, 1),
            eventCount: eventCount,
            anchor: CostUsageCodexTokenIndexAnchor(
                indexedBytes: sqlite3_column_int64(statement, 3),
                windowStart: sqlite3_column_int64(statement, 4),
                sha256: anchorSHA256),
            isComplete: sqlite3_column_int(statement, 6) == 1)
        try Self.validate(reference: reference)
        let ordering = TimestampOrdering(
            isMonotonic: sqlite3_column_int(statement, 7) == 1,
            lastUnixSeconds: Self.columnDouble(statement, at: 8))
        guard ordering.lastUnixSeconds?.isFinite != false,
              try ordering == (Self.timestampOrdering(
                  sourceID: sourceID,
                  eventCount: reference.eventCount,
                  db: db))
        else { throw StoreError.prefixMismatch }
        return StoredSource(reference: reference, timestampOrdering: ordering)
    }

    private static func upsert(
        reference: CostUsageCodexTokenIndexReference,
        timestampOrdering: TimestampOrdering,
        sourceID: Int64,
        db: OpaquePointer?) throws
    {
        let sql = """
        UPDATE sources SET
            path = ?,
            file_id = ?,
            indexed_bytes = ?,
            event_count = ?,
            anchor_indexed_bytes = ?,
            anchor_window_start = ?,
            anchor_sha256 = ?,
            is_complete = ?,
            timestamps_monotonic = ?,
            last_timestamp_unix_seconds = ?
        WHERE id = ?
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        Self.bind(reference.path, to: statement, at: 1)
        Self.bind(reference.fileId, to: statement, at: 2)
        sqlite3_bind_int64(statement, 3, reference.indexedBytes)
        guard let eventCount = Self.int64(reference.eventCount) else { throw StoreError.invalidInput }
        sqlite3_bind_int64(statement, 4, eventCount)
        sqlite3_bind_int64(statement, 5, reference.anchor.indexedBytes)
        sqlite3_bind_int64(statement, 6, reference.anchor.windowStart)
        Self.bind(reference.anchor.sha256, to: statement, at: 7)
        sqlite3_bind_int(statement, 8, reference.isComplete ? 1 : 0)
        sqlite3_bind_int(statement, 9, timestampOrdering.isMonotonic ? 1 : 0)
        Self.bind(timestampOrdering.lastUnixSeconds, to: statement, at: 10)
        sqlite3_bind_int64(statement, 11, sourceID)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE,
              sqlite3_changes(db) == 1
        else {
            if result != SQLITE_DONE { throw Self.sqliteError(db, fallbackCode: result) }
            throw StoreError.prefixMismatch
        }
    }

    private static func insert(
        records: [CostUsageCodexTokenIndexRecord],
        sourceID: Int64,
        startingAt firstEventIndex: Int,
        initialOrdering: TimestampOrdering,
        db: OpaquePointer?) throws -> TimestampOrdering
    {
        guard !records.isEmpty else { return initialOrdering }
        let sql = """
        INSERT INTO events (
            source_id, event_index, timestamp, timestamp_unix_seconds,
            timestamp_prefix_monotonic, input_tokens, cached_input_tokens,
            output_tokens, reasoning_tokens, end_offset
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }

        var ordering = initialOrdering
        for (offset, record) in records.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, sourceID)
            guard firstEventIndex <= Int.max - offset,
                  let eventIndex = Self.int64(firstEventIndex + offset),
                  let input = Self.int64(record.totals.input),
                  let cached = Self.int64(record.totals.cached),
                  let output = Self.int64(record.totals.output)
            else { throw StoreError.invalidInput }
            sqlite3_bind_int64(statement, 2, eventIndex)
            Self.bind(record.timestamp, to: statement, at: 3)
            Self.bind(record.timestampUnixSeconds, to: statement, at: 4)
            ordering.append(record)
            sqlite3_bind_int(statement, 5, ordering.isMonotonic ? 1 : 0)
            sqlite3_bind_int64(statement, 6, input)
            sqlite3_bind_int64(statement, 7, cached)
            sqlite3_bind_int64(statement, 8, output)
            Self.bind(record.totals.reasoning, to: statement, at: 9)
            sqlite3_bind_int64(statement, 10, record.endOffset)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw Self.sqliteError(db, fallbackCode: result)
            }
        }
        return ordering
    }

    private static func timestampOrdering(
        sourceID: Int64,
        eventCount: Int,
        db: OpaquePointer?) throws -> TimestampOrdering
    {
        guard eventCount >= 0 else { throw StoreError.invalidInput }
        guard eventCount > 0 else { return .empty }
        guard let eventIndex = int64(eventCount - 1) else { throw StoreError.invalidInput }
        let sql = """
        SELECT timestamp_unix_seconds, timestamp_prefix_monotonic
        FROM events
        WHERE source_id = ? AND event_index = ?
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        sqlite3_bind_int64(statement, 2, eventIndex)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW,
              [0, 1].contains(sqlite3_column_int(statement, 1))
        else {
            if result != SQLITE_ROW, result != SQLITE_DONE {
                throw Self.sqliteError(db, fallbackCode: result)
            }
            throw StoreError.prefixMismatch
        }
        let ordering = TimestampOrdering(
            isMonotonic: sqlite3_column_int(statement, 1) == 1,
            lastUnixSeconds: Self.columnDouble(statement, at: 0))
        guard ordering.lastUnixSeconds?.isFinite != false,
              !ordering.isMonotonic || ordering.lastUnixSeconds != nil
        else { throw StoreError.prefixMismatch }
        return ordering
    }

    private static func deleteEvents(
        sourceID: Int64,
        startingAt eventIndex: Int,
        db: OpaquePointer?) throws
    {
        guard let eventIndex = int64(eventIndex) else { throw StoreError.invalidInput }
        let statement = try Self.prepare(
            db,
            "DELETE FROM events WHERE source_id = ? AND event_index >= ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        sqlite3_bind_int64(statement, 2, eventIndex)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw Self.sqliteError(db, fallbackCode: result)
        }
    }

    private static func deleteSource(sourceID: Int64, db: OpaquePointer?) throws {
        let statement = try Self.prepare(db, "DELETE FROM sources WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw Self.sqliteError(db, fallbackCode: result)
        }
    }

    private static func crashAheadIsConsistent(
        current: CostUsageCodexTokenIndexReference,
        expected: CostUsageCodexTokenIndexReference,
        sourceID: Int64,
        db: OpaquePointer?) throws -> Bool
    {
        guard current.fileId == expected.fileId,
              current.indexedBytes >= expected.indexedBytes,
              current.eventCount >= expected.eventCount,
              self.referenceMatchesFile(current, requireCompleteEOF: false)
        else { return false }

        let cursorAdvanced = current.indexedBytes > expected.indexedBytes
            || current.eventCount > expected.eventCount
        let metadataOnlyAdvance = current.indexedBytes == expected.indexedBytes
            && current.eventCount == expected.eventCount
            && current.anchor == expected.anchor
            && current.isComplete != expected.isComplete
        guard cursorAdvanced || metadataOnlyAdvance else { return false }

        if current.eventCount > expected.eventCount {
            guard let firstUnpublishedIndex = Self.int64(expected.eventCount),
                  let firstUnpublishedOffset = try Self.eventEndOffset(
                      sourceID: sourceID,
                      eventIndex: firstUnpublishedIndex,
                      db: db),
                  firstUnpublishedOffset > expected.indexedBytes,
                  firstUnpublishedOffset <= current.indexedBytes
            else { return false }
        }
        return true
    }

    private static func eventEndOffset(
        sourceID: Int64,
        eventIndex: Int64,
        db: OpaquePointer?) throws -> Int64?
    {
        let sql = "SELECT end_offset FROM events WHERE source_id = ? AND event_index = ?"
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        sqlite3_bind_int64(statement, 2, eventIndex)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return sqlite3_column_int64(statement, 0) }
        guard result == SQLITE_DONE else {
            throw Self.sqliteError(db, fallbackCode: result)
        }
        return nil
    }

    private static func requireMatchingRecords(
        _ records: [CostUsageCodexTokenIndexRecord],
        sourceID: Int64,
        startingAt firstEventIndex: Int,
        db: OpaquePointer?) throws
    {
        guard !records.isEmpty else { return }
        guard firstEventIndex <= Int.max - records.count,
              let lowerBound = int64(firstEventIndex),
              let upperBound = int64(firstEventIndex + records.count)
        else { throw StoreError.invalidInput }
        let sql = """
        SELECT event_index, timestamp, timestamp_unix_seconds, input_tokens,
               cached_input_tokens, output_tokens, reasoning_tokens, end_offset
        FROM events
        WHERE source_id = ? AND event_index >= ? AND event_index < ?
        ORDER BY event_index
        """
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        sqlite3_bind_int64(statement, 2, lowerBound)
        sqlite3_bind_int64(statement, 3, upperBound)

        for (offset, expected) in records.enumerated() {
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW,
                  sqlite3_column_int64(statement, 0) == lowerBound + Int64(offset),
                  Self.record(statement, startingAt: 1) == expected
            else {
                if result != SQLITE_ROW, result != SQLITE_DONE {
                    throw Self.sqliteError(db, fallbackCode: result)
                }
                throw StoreError.prefixMismatch
            }
        }
        let trailingResult = sqlite3_step(statement)
        guard trailingResult == SQLITE_DONE else {
            if trailingResult != SQLITE_ROW {
                throw Self.sqliteError(db, fallbackCode: trailingResult)
            }
            throw StoreError.prefixMismatch
        }
    }

    static let monotonicNumericCandidateSQL = """
    SELECT event_index, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens
    FROM events
    WHERE source_id = ? AND event_index < ? AND timestamp_unix_seconds <= ?
    ORDER BY timestamp_unix_seconds DESC, event_index DESC
    LIMIT 1
    """

    private static func monotonicNumericCandidate(
        sourceID: Int64,
        eventCount: Int,
        cutoffUnixSeconds: Double,
        db: OpaquePointer?) throws -> (eventIndex: Int, totals: CostUsageCodexTotals)?
    {
        guard let eventCount = int64(eventCount) else { throw StoreError.invalidInput }
        let statement = try Self.prepare(db, Self.monotonicNumericCandidateSQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        sqlite3_bind_int64(statement, 2, eventCount)
        sqlite3_bind_double(statement, 3, cutoffUnixSeconds)
        return try Self.candidate(statement, db: db)
    }

    private static func eventOrderNumericCandidate(
        sourceID: Int64,
        eventCount: Int,
        cutoffUnixSeconds: Double,
        db: OpaquePointer?) throws -> (eventIndex: Int, totals: CostUsageCodexTotals)?
    {
        let sql = """
        SELECT event_index, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens
        FROM events
        WHERE source_id = ? AND event_index < ? AND timestamp_unix_seconds <= ?
        ORDER BY event_index DESC
        LIMIT 1
        """
        guard let eventCount = Self.int64(eventCount) else { throw StoreError.invalidInput }
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        sqlite3_bind_int64(statement, 2, eventCount)
        sqlite3_bind_double(statement, 3, cutoffUnixSeconds)
        return try Self.candidate(statement, db: db)
    }

    private static func lexicalCandidate(
        sourceID: Int64,
        eventCount: Int,
        cutoffTimestamp: String,
        invalidTimestampsOnly: Bool,
        db: OpaquePointer?) throws -> (eventIndex: Int, totals: CostUsageCodexTotals)?
    {
        let invalidClause = invalidTimestampsOnly ? "AND timestamp_unix_seconds IS NULL" : ""
        let sql = """
        SELECT event_index, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens
        FROM events
        WHERE source_id = ? AND event_index < ? AND timestamp <= ? \(invalidClause)
        ORDER BY event_index DESC
        LIMIT 1
        """
        guard let eventCount = Self.int64(eventCount) else { throw StoreError.invalidInput }
        let statement = try Self.prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sourceID)
        sqlite3_bind_int64(statement, 2, eventCount)
        Self.bind(cutoffTimestamp, to: statement, at: 3)
        return try Self.candidate(statement, db: db)
    }

    private static func candidate(
        _ statement: OpaquePointer?,
        db: OpaquePointer?) throws -> (eventIndex: Int, totals: CostUsageCodexTotals)?
    {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw Self.sqliteError(db, fallbackCode: result)
        }
        guard let eventIndex = Int(exactly: sqlite3_column_int64(statement, 0)),
              let input = Int(exactly: sqlite3_column_int64(statement, 1)),
              let cached = Int(exactly: sqlite3_column_int64(statement, 2)),
              let output = Int(exactly: sqlite3_column_int64(statement, 3))
        else { throw StoreError.prefixMismatch }
        let reasoning = Self.columnInt64(statement, at: 4).flatMap(Int.init(exactly:))
        if sqlite3_column_type(statement, 4) != SQLITE_NULL, reasoning == nil {
            throw StoreError.prefixMismatch
        }
        return (
            eventIndex,
            CostUsageCodexTotals(
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning))
    }

    private static func record(
        _ statement: OpaquePointer?,
        startingAt start: Int32) -> CostUsageCodexTokenIndexRecord?
    {
        guard let timestamp = columnString(statement, at: start),
              let input = Int(exactly: sqlite3_column_int64(statement, start + 2)),
              let cached = Int(exactly: sqlite3_column_int64(statement, start + 3)),
              let output = Int(exactly: sqlite3_column_int64(statement, start + 4))
        else { return nil }
        let reasoning = Self.columnInt64(statement, at: start + 5).flatMap(Int.init(exactly:))
        if sqlite3_column_type(statement, start + 5) != SQLITE_NULL, reasoning == nil { return nil }
        return CostUsageCodexTokenIndexRecord(
            timestamp: timestamp,
            timestampUnixSeconds: Self.columnDouble(statement, at: start + 1),
            totals: CostUsageCodexTotals(
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning),
            endOffset: sqlite3_column_int64(statement, start + 6))
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
        guard result == SQLITE_OK else {
            throw Self.sqliteError(db, fallbackCode: result)
        }
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

    private static func bind(_ value: Double?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private static func bind(_ value: Int?, to statement: OpaquePointer?, at index: Int32) {
        guard let value, let value = int64(value) else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
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

    private static func columnDouble(_ statement: OpaquePointer?, at index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, index)
    }

    private static func int64(_ value: Int) -> Int64? {
        Int64(exactly: value)
    }

    private static func userVersion(_ db: OpaquePointer?) throws -> Int32 {
        let statement = try Self.prepare(db, "PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw Self.sqliteError(
                db,
                fallbackCode: result == SQLITE_DONE ? SQLITE_ERROR : result)
        }
        return sqlite3_column_int(statement, 0)
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

    private static func lookupFailure(for error: Error) -> CostUsageCodexTokenIndexLookup {
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
