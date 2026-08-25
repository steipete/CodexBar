import Dispatch
import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

package enum CostUsageStoreExecutorTestControl {
    package static let suppressCurrentContextArgument = "--cost-store-suppress-current-context-for-testing"
    package static let suppressCurrentContextAnswer = CommandLine.arguments.contains(
        Self.suppressCurrentContextArgument)
}

/// Single-writer persistence for Codex cost scanning. The actor owns the only writable
/// connection; Phase 2 can keep its existing scan-queue serialization while independent
/// app and CLI readers use WAL snapshots through separate read-only connections.
actor CostUsageStore {
    private final class StoreSerialExecutor: SerialExecutor, @unchecked Sendable {
        private let queue: DispatchQueue
        private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

        init(label: String) {
            self.queue = DispatchQueue(label: label, qos: .utility)
            self.queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
        }

        func enqueue(_ job: consuming ExecutorJob) {
            let unownedJob = UnownedJob(job)
            let executor = self.asUnownedSerialExecutor()
            self.queue.async {
                unownedJob.runSynchronously(on: executor)
            }
        }

        func checkIsolated() {
            dispatchPrecondition(condition: .onQueue(self.queue))
        }

        /// macOS 26+ runtimes ask this before `checkIsolated()`; the queue-specific token
        /// sees through `DispatchQueue.sync` accurately.
        @available(macOS 26.0, *)
        func isIsolatingCurrentContext() -> Bool? {
            guard !CostUsageStoreExecutorTestControl.suppressCurrentContextAnswer else { return nil }
            return DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self)
        }

        func sync<T>(_ operation: () throws -> T) rethrows -> T {
            try self.queue.sync(execute: operation)
        }
    }

    private final class SQLiteConnection: @unchecked Sendable {
        private(set) var handle: OpaquePointer?

        init(handle: OpaquePointer) {
            self.handle = handle
        }

        func close() {
            guard let handle else { return }
            sqlite3_close_v2(handle)
            self.handle = nil
        }

        deinit {
            self.close()
        }
    }

    static let log = CodexBarLog.logger(LogCategories.tokenCost)
    static let databaseFilename = "cost-usage.sqlite"
    static let baseSchemaVersion = 3
    static let schemaVersion = CostUsageStore.combinedSchemaVersion(
        base: CostUsageStore.baseSchemaVersion,
        parserHash: CodexParserHash.value)
    static let cacheGeneration = "sqlite:\(CostUsageStore.schemaVersion)"
    static let compatiblePredecessorParserHashes: Set<String> = [
        "dd19ffa2dcfa8d47", // Current main before report-window scoping; persisted rows unchanged.
        "8050a4faf4fddb96", // PR base before retained-report persistence; parsed rows unchanged.
        "cfd84d13ad7d4cfa", // 0.55.x scan scheduling and progress bookkeeping; persisted rows unchanged.
        "98da5914d2f6a9cd", // Pushed PR producer before retry signaling; persisted rows unchanged.
        "43609cc56f76a003", // 0.49.3 request-tier pricing; persisted row shape unchanged.
        "b975eb705f905b9a", // 0.49.0-0.49.2 SQLite producer with compatible rows.
        "47144baa8daccf52", // This branch changes only scan scheduling, discovery, and persistence bookkeeping.
        "2d17f4981b78d07f", // Persisted priority-turn cursor; parser and persisted row shape unchanged.
        "3c984b655688593f", // 0.54.x row-ownership evidence fix; parser and persisted row shape unchanged.
        "5f8507161b23757c", // 0.54.2 tokscale parity + priority evidence; persisted row shape unchanged.
    ]
    static let incompatibleRetainedReportPredecessorParserHashes: Set<String> = [
        "dd19ffa2dcfa8d47",
        "2d17f4981b78d07f",
        "8050a4faf4fddb96",
    ]

    /// Test-only crash injection: invoked inside `saveCodexCache`'s transaction after each
    /// persisted file with the running count, so a crash-safety harness can SIGKILL the
    /// process at a deterministic mid-save point. Never set in production.
    nonisolated(unsafe) static var saveCycleCheckpointForTesting: ((Int) -> Void)?
    /// Test-only interleaving point scoped to one database so parallel store fixtures stay isolated.
    nonisolated(unsafe) static var identicalContentPreLockCheckpointForTesting: (
        databaseURL: URL,
        checkpoint: () -> Void)?

    /// Test-only traversal proof for persisted Codex catch-up reconciliation. Never set in production.
    nonisolated(unsafe) static var codexCatchUpReconciliationVisitForTesting: (() -> Void)?

    /// Process-wide serialization keeps every writable store connection on the same queue.
    /// This matches the scan pipeline's single-writer contract without multiplying executor
    /// threads when tests or short-lived readers create several store actors.
    private nonisolated static let sharedExecutor = StoreSerialExecutor(
        label: "com.steipete.codexbar.cost-usage-store")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.sharedExecutor.asUnownedSerialExecutor()
    }

    nonisolated let databaseURL: URL
    private let expectedSchemaVersion: Int32
    private let expectedParserHash: String
    private var connection: SQLiteConnection?
    private(set) var rebuildCount = 0
    /// While a save cycle's enclosing transaction is open, nested `withDatabase` calls join
    /// it instead of opening their own connection scope, and the first failure aborts the
    /// remainder of the cycle so the outer transaction rolls back as a unit.
    private var activeTransactionDatabase: OpaquePointer?
    private var activeTransactionError: Error?

    init(
        cacheRoot: URL? = nil,
        schemaVersion: Int32 = CostUsageStore.schemaVersion,
        parserHash: String = CodexParserHash.value)
    {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        self.databaseURL = root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(Self.databaseFilename, isDirectory: false)
        self.expectedSchemaVersion = schemaVersion
        self.expectedParserHash = parserHash
    }

    static func combinedSchemaVersion(base: Int, parserHash: String) -> Int32 {
        var hash: UInt32 = 2_166_136_261
        for byte in parserHash.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        let combined = (UInt32(truncatingIfNeeded: base) & 0x7F) << 24 | (hash & 0x00FF_FFFF)
        return Int32(combined)
    }
}

extension CostUsageStore {
    /// The shared queue establishes isolation; runtime checks are unreliable for SDK-14 binaries on macOS 15.
    private nonisolated func syncWithStoreIsolation<T: Sendable>(
        _ operation: (isolated CostUsageStore) throws -> T) rethrows -> T
    {
        try Self.sharedExecutor.sync {
            Self.sharedExecutor.checkIsolated()
            typealias Isolated = (isolated CostUsageStore) throws -> T
            typealias Unisolated = (CostUsageStore) throws -> T
            return try withoutActuallyEscaping(operation) { (operation: @escaping Isolated) throws -> T in
                try unsafeBitCast(operation, to: Unisolated.self)(self)
            }
        }
    }

    nonisolated func syncLoadCodexCache(calendar: Calendar) -> CostUsageCache {
        self.syncWithStoreIsolation { store in
            store.loadCodexCache(calendar: calendar)
        }
    }

    nonisolated func syncSaveCodexCache(
        _ cache: CostUsageCache,
        calendar: Calendar,
        requestedScanWindow: (sinceKey: String, untilKey: String),
        reportWindow: (sinceKey: String, untilKey: String)? = nil,
        rowBudget: Int = CostUsageStore.defaultRowBudget,
        fileBudgetBytes: Int64 = CostUsageStore.defaultFileBudgetBytes,
        skipIdenticalContent: Bool = false) -> CostUsageStoreBudgetResult
    {
        self.syncWithStoreIsolation { store in
            store.saveCodexCache(
                cache,
                calendar: calendar,
                requestedScanWindow: requestedScanWindow,
                reportWindow: reportWindow,
                rowBudget: rowBudget,
                fileBudgetBytes: fileBudgetBytes,
                skipIdenticalContent: skipIdenticalContent)
        }
    }
}

// MARK: - Connection lifecycle

extension CostUsageStore {
    enum StoreError: Error {
        case sqlite(Int32)
        case invalidData
        case incompatibleSchema
    }

    func withDatabase<T>(default fallback: T, _ operation: (OpaquePointer) throws -> T) -> T {
        if let database = self.activeTransactionDatabase {
            // A failed statement may have aborted the enclosing transaction; running the
            // remaining writes would commit them individually in autocommit mode, which is
            // exactly the partial-save state the transaction exists to prevent. Skip them.
            guard self.activeTransactionError == nil else { return fallback }
            do {
                return try operation(database)
            } catch {
                self.activeTransactionError = error
                return fallback
            }
        }
        do {
            let database = try self.ensureDatabase()
            return try operation(database)
        } catch {
            guard Self.shouldRebuild(after: error) else {
                self.recoverConnectionAfterFailure()
                Self.log.warning("cost-usage store operation failed; keeping database: \(error)")
                return fallback
            }
            self.rebuildDatabase(reason: "operation failed: \(error)")
            do {
                let database = try self.ensureDatabase()
                return try operation(database)
            } catch {
                if Self.shouldRebuild(after: error) {
                    self.rebuildDatabase(reason: "retry failed: \(error)")
                } else {
                    self.recoverConnectionAfterFailure()
                    Self.log.warning("cost-usage store retry failed; keeping database: \(error)")
                }
                return fallback
            }
        }
    }

    /// Opens the save cycle's all-or-nothing transaction: a single BEGIN IMMEDIATE spanning
    /// every store call made until `endSaveTransaction()`. Nested `withDatabase` calls join
    /// the open transaction and the first inner failure aborts the cycle, so a crash or
    /// error midway leaves the previous on-disk state fully intact — matching the old JSON
    /// path's atomic single-file replace. Callers must stop the save when this returns false.
    @discardableResult
    func beginSaveTransaction() -> Bool {
        self.withDatabase(default: false) { database in
            try Self.execute(database, "BEGIN IMMEDIATE")
            self.activeTransactionDatabase = database
            return true
        }
    }

    /// Commits the open save transaction, or rolls it back when a nested write failed. The
    /// stored failure is rethrown through `withDatabase` so the usual rebuild-vs-preserve
    /// classification still applies to it.
    @discardableResult
    func endSaveTransaction() -> Bool {
        guard self.activeTransactionDatabase != nil else { return false }
        let failure = self.activeTransactionError
        self.activeTransactionDatabase = nil
        self.activeTransactionError = nil
        return self.withDatabase(default: false) { database in
            if let failure {
                try? Self.execute(database, "ROLLBACK")
                throw failure
            }
            try Self.execute(database, "COMMIT")
            return true
        }
    }

    @discardableResult
    func rollbackSaveTransaction() -> Bool {
        guard self.activeTransactionDatabase != nil else { return false }
        self.activeTransactionDatabase = nil
        self.activeTransactionError = nil
        return self.withDatabase(default: false) { database in
            try Self.execute(database, "ROLLBACK")
            return true
        }
    }

    /// Destroying the database is only the right recovery for corruption or schema drift.
    /// Transient and data-shape failures (lock contention from a second process, disk full,
    /// out of memory, a constraint violation from bad input) must not delete user history:
    /// the old JSON path kept the previous artifact on a failed write, and so do we.
    static func shouldRebuild(after error: Error) -> Bool {
        guard case let StoreError.sqlite(code) = error else { return true }
        switch code & 0xFF {
        case SQLITE_PERM, SQLITE_BUSY, SQLITE_LOCKED, SQLITE_NOMEM, SQLITE_READONLY,
             SQLITE_INTERRUPT, SQLITE_IOERR, SQLITE_FULL, SQLITE_TOOBIG, SQLITE_CONSTRAINT,
             SQLITE_MISUSE, SQLITE_AUTH, SQLITE_RANGE:
            return false
        default:
            return true
        }
    }

    /// After a preserved (non-rebuild) failure the connection may still hold an open
    /// transaction if ROLLBACK itself failed. Roll back, or drop the connection so the
    /// next access reopens the intact file.
    private func recoverConnectionAfterFailure() {
        guard let handle = self.connection?.handle else { return }
        if sqlite3_get_autocommit(handle) == 0,
           sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) != SQLITE_OK
        {
            self.connection?.close()
            self.connection = nil
        }
    }

    func ensureDatabase() throws -> OpaquePointer {
        if let database = self.connection?.handle {
            return database
        }
        do {
            let opened = try self.openDatabase()
            self.connection = SQLiteConnection(handle: opened)
            return opened
        } catch {
            guard Self.shouldRebuild(after: error) else { throw error }
            self.rebuildDatabase(reason: "open failed: \(error)")
            guard let database = self.connection?.handle else { throw error }
            return database
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        let directory = self.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: self.databaseURL.path)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(self.databaseURL.path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw StoreError.sqlite(result)
        }
        do {
            try Self.configure(opened)
            if existed {
                try self.validateExistingDatabase(opened)
            } else {
                try Self.execute(opened, "PRAGMA auto_vacuum=INCREMENTAL")
                try Self.execute(opened, "VACUUM")
                try self.createSchema(opened)
            }
            return opened
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
    }

    private func validateExistingDatabase(_ database: OpaquePointer) throws {
        let state: (storedHash: String, isCurrent: Bool, canAdoptPredecessor: Bool)
        try Self.execute(database, "BEGIN")
        do {
            state = try self.databaseCompatibilityState(database)
            guard state.isCurrent || state.canAdoptPredecessor else {
                throw StoreError.incompatibleSchema
            }
            try Self.validateDatabaseIntegrity(database)
            try Self.execute(database, "COMMIT")
        } catch {
            try? Self.execute(database, "ROLLBACK")
            throw error
        }
        if state.isCurrent {
            return
        }

        try Self.execute(database, "BEGIN IMMEDIATE")
        do {
            // Another process may have adopted the predecessor while this connection waited
            // for the writer lock. Re-read the compatibility state before changing metadata.
            let lockedState = try self.databaseCompatibilityState(database)
            guard lockedState.isCurrent || lockedState.canAdoptPredecessor else {
                throw StoreError.incompatibleSchema
            }
            try Self.validateDatabaseIntegrity(database)
            if lockedState.canAdoptPredecessor {
                try self.adoptCompatiblePredecessor(database, storedHash: lockedState.storedHash)
            }
            try Self.execute(database, "COMMIT")
        } catch {
            try? Self.execute(database, "ROLLBACK")
            throw error
        }
    }

    private func databaseCompatibilityState(_ database: OpaquePointer) throws -> (
        storedHash: String,
        isCurrent: Bool,
        canAdoptPredecessor: Bool)
    {
        let actualVersion = try Self.scalarInt(database, "PRAGMA user_version")
        guard let storedHash = try Self.scalarText(
            database,
            "SELECT value FROM meta WHERE key = 'parser_hash'")
        else { throw StoreError.incompatibleSchema }
        let isCurrent = actualVersion == Int64(self.expectedSchemaVersion)
            && storedHash == self.expectedParserHash
        let predecessorVersion = Self.combinedSchemaVersion(
            base: Self.baseSchemaVersion,
            parserHash: storedHash)
        let canAdoptPredecessor = self.expectedParserHash == CodexParserHash.value
            && self.expectedSchemaVersion == Self.schemaVersion
            && Self.compatiblePredecessorParserHashes.contains(storedHash)
            && actualVersion == Int64(predecessorVersion)
        return (storedHash, isCurrent, canAdoptPredecessor)
    }

    private static func validateDatabaseIntegrity(_ database: OpaquePointer) throws {
        guard try self.scalarText(database, "PRAGMA quick_check") == "ok" else {
            throw StoreError.invalidData
        }
        guard try self.scalarInt(database, "PRAGMA auto_vacuum") == 2 else {
            throw StoreError.incompatibleSchema
        }
    }

    private func adoptCompatiblePredecessor(_ database: OpaquePointer, storedHash: String) throws {
        if Self.incompatibleRetainedReportPredecessorParserHashes.contains(storedHash),
           var metadata = try Self.readSingleton(
               CostUsageStoreMetadata.self,
               database: database,
               table: "scan_metadata")
        {
            metadata.previousReportPayload = nil
            let payload = try JSONEncoder().encode(metadata)
            let metadataStatement = try Self.prepare(
                database,
                "UPDATE scan_metadata SET payload = ? WHERE id = 1")
            defer { sqlite3_finalize(metadataStatement) }
            Self.bind(payload, to: metadataStatement, at: 1)
            try Self.stepDone(metadataStatement, database: database)
            guard sqlite3_changes(database) == 1 else { throw StoreError.incompatibleSchema }
        }
        let statement = try Self.prepare(database, "UPDATE meta SET value = ? WHERE key = 'parser_hash'")
        defer { sqlite3_finalize(statement) }
        Self.bind(self.expectedParserHash, to: statement, at: 1)
        try Self.stepDone(statement, database: database)
        guard sqlite3_changes(database) == 1 else { throw StoreError.incompatibleSchema }
        try Self.execute(database, "PRAGMA user_version = \(self.expectedSchemaVersion)")
    }

    private func createSchema(_ database: OpaquePointer) throws {
        try Self.execute(database, Self.schemaSQL)
        try Self.execute(database, "PRAGMA user_version = \(self.expectedSchemaVersion)")
        let statement = try Self.prepare(database, "INSERT INTO meta(key, value) VALUES ('parser_hash', ?)")
        defer { sqlite3_finalize(statement) }
        Self.bind(self.expectedParserHash, to: statement, at: 1)
        try Self.stepDone(statement, database: database)
    }

    private func rebuildDatabase(reason: String) {
        self.connection?.close()
        self.connection = nil
        for suffix in ["", "-wal", "-shm"] {
            let path = self.databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        self.rebuildCount += 1
        Self.log.warning("cost-usage store rebuilt (count \(self.rebuildCount)): \(reason)")
        if let database = try? self.openDatabase() {
            self.connection = SQLiteConnection(handle: database)
        }
    }

    /// The Codex JSON cache is derived data, so the SQLite cutover deliberately rebuilds
    /// from session files instead of importing an old monolithic snapshot. Keep the legacy
    /// filename knowledge confined to this one cleanup boundary.
    func removeLegacyCodexArtifactIfPresent() -> Bool {
        let directory = self.databaseURL.deletingLastPathComponent()
        let legacyFilename = "codex-v11.json"
        let legacyURL = directory.appendingPathComponent(legacyFilename)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return false }

        let temporaryNames = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil))?.filter { url in
            let name = url.lastPathComponent
            return name == legacyFilename
                || name.hasPrefix(".\(legacyFilename).")
                || name.hasPrefix("\(legacyFilename).")
                || name.hasPrefix("\(legacyFilename)-")
        } ?? [legacyURL]
        for url in temporaryNames {
            try? FileManager.default.removeItem(at: url)
        }
        self.rebuildDatabase(reason: "legacy Codex JSON artifact removed")
        return true
    }
}

// MARK: - Schema

extension CostUsageStore {
    private static let schemaSQL = """
    CREATE TABLE meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );
    CREATE TABLE scan_metadata (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        payload BLOB NOT NULL
    );
    CREATE TABLE files (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        inode INTEGER,
        mtime_ms INTEGER NOT NULL,
        size INTEGER NOT NULL,
        parsed_bytes INTEGER,
        anchor_indexed_bytes INTEGER,
        anchor_window_start INTEGER,
        anchor_sha256 TEXT,
        scan_state BLOB NOT NULL,
        scan_target_size INTEGER,
        scan_complete INTEGER NOT NULL,
        session_id TEXT,
        coverage_since_day TEXT,
        coverage_until_day TEXT,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE INDEX files_path_idx ON files(path);
    CREATE INDEX files_session_idx ON files(session_id);
    CREATE INDEX files_coverage_idx ON files(coverage_since_day, coverage_until_day);
    CREATE INDEX files_updated_idx ON files(updated_at_ms);
    CREATE TABLE token_snapshots (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        event_index INTEGER NOT NULL,
        timestamp TEXT NOT NULL,
        timestamp_ms INTEGER,
        day TEXT,
        last_input INTEGER,
        last_cached INTEGER,
        last_output INTEGER,
        last_reasoning INTEGER,
        total_input INTEGER,
        total_cached INTEGER,
        total_output INTEGER,
        total_reasoning INTEGER,
        end_offset INTEGER,
        PRIMARY KEY(file_id, event_index)
    );
    CREATE INDEX token_snapshots_day_idx ON token_snapshots(day);
    CREATE INDEX token_snapshots_timestamp_idx ON token_snapshots(file_id, timestamp_ms, event_index);
    CREATE TABLE usage_rows (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        row_index INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(file_id, row_index)
    );
    CREATE INDEX usage_rows_file_idx ON usage_rows(file_id, row_index);
    CREATE TABLE file_day_aggregates (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        day TEXT NOT NULL,
        model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        cached_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        reasoning_tokens INTEGER NOT NULL,
        request_count INTEGER NOT NULL,
        authoritative_cost_nanos INTEGER NOT NULL,
        standard_input_tokens INTEGER NOT NULL,
        standard_cached_tokens INTEGER NOT NULL,
        standard_output_tokens INTEGER NOT NULL,
        priority_input_tokens INTEGER NOT NULL,
        priority_cached_tokens INTEGER NOT NULL,
        priority_output_tokens INTEGER NOT NULL,
        standard_tokens INTEGER NOT NULL,
        priority_tokens INTEGER NOT NULL,
        PRIMARY KEY(file_id, day, model)
    );
    CREATE INDEX file_day_aggregates_day_idx ON file_day_aggregates(day);
    CREATE INDEX file_day_aggregates_model_day_idx ON file_day_aggregates(model, day);
    CREATE TABLE day_aggregates (
        day TEXT NOT NULL,
        model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        cached_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        reasoning_tokens INTEGER NOT NULL,
        request_count INTEGER NOT NULL,
        authoritative_cost_nanos INTEGER NOT NULL,
        standard_input_tokens INTEGER NOT NULL,
        standard_cached_tokens INTEGER NOT NULL,
        standard_output_tokens INTEGER NOT NULL,
        priority_input_tokens INTEGER NOT NULL,
        priority_cached_tokens INTEGER NOT NULL,
        priority_output_tokens INTEGER NOT NULL,
        standard_tokens INTEGER NOT NULL,
        priority_tokens INTEGER NOT NULL,
        PRIMARY KEY(day, model)
    );
    CREATE INDEX day_aggregates_day_idx ON day_aggregates(day);
    CREATE INDEX day_aggregates_model_idx ON day_aggregates(model);
    CREATE INDEX day_aggregates_model_day_idx ON day_aggregates(model, day);
    CREATE TABLE fork_lineage (
        file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
        session_id TEXT,
        forked_from_id TEXT,
        fork_timestamp TEXT,
        dependency_key TEXT,
        subagent_state BLOB,
        accounting_state BLOB
    );
    CREATE INDEX fork_lineage_parent_idx ON fork_lineage(forked_from_id);
    CREATE TABLE buffered_lines (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        line_index INTEGER NOT NULL,
        ordinal INTEGER,
        end_offset INTEGER,
        payload BLOB NOT NULL,
        PRIMARY KEY(file_id, kind, line_index)
    );
    CREATE INDEX buffered_lines_file_idx ON buffered_lines(file_id, kind, line_index);
    CREATE TABLE discovery_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        payload BLOB NOT NULL
    );
    CREATE TABLE lookback_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        payload BLOB NOT NULL
    );
    CREATE TABLE accumulators (
        file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
        event_count INTEGER NOT NULL,
        next_usage_row_index INTEGER,
        counted_input INTEGER,
        counted_cached INTEGER,
        counted_output INTEGER,
        counted_reasoning INTEGER,
        baseline_input INTEGER,
        baseline_cached INTEGER,
        baseline_output INTEGER,
        baseline_reasoning INTEGER,
        watermark_input INTEGER,
        watermark_cached INTEGER,
        watermark_output INTEGER,
        watermark_reasoning INTEGER,
        saw_divergent INTEGER NOT NULL,
        saw_interleaved INTEGER NOT NULL,
        seen_raw_totals BLOB NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE INDEX accumulators_updated_idx ON accumulators(updated_at_ms);
    """
}

// MARK: - SQLite primitives

extension CostUsageStore {
    static func configure(_ database: OpaquePointer) throws {
        guard sqlite3_busy_timeout(database, 5000) == SQLITE_OK else {
            throw self.sqliteError(database)
        }
        try self.execute(database, "PRAGMA foreign_keys=ON")
        try self.execute(database, "PRAGMA journal_mode=WAL")
    }

    static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        if let message {
            sqlite3_free(message)
        }
        guard result == SQLITE_OK else { throw StoreError.sqlite(result) }
    }

    static func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw StoreError.sqlite(result) }
        return statement
    }

    static func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
    }

    static func scalarInt(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw StoreError.sqlite(result) }
        return sqlite3_column_int64(statement, 0)
    }

    static func scalarText(_ database: OpaquePointer, _ sql: String) throws -> String? {
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw StoreError.sqlite(result) }
        return self.columnText(statement, at: 0)
    }

    static func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, self.transientDestructor)
    }

    static func bind(_ value: Int64?, to statement: OpaquePointer, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    static func bind(_ value: Int?, to statement: OpaquePointer, at index: Int32) {
        self.bind(value.map(Int64.init), to: statement, at: index)
    }

    static func bind(_ value: Data?, to statement: OpaquePointer, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), self.transientDestructor)
        }
    }

    static func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    static func columnInt64(_ statement: OpaquePointer, at index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    static func columnData(_ statement: OpaquePointer, at index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else {
            return sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Data()
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    static func sqliteError(_ database: OpaquePointer) -> StoreError {
        StoreError.sqlite(sqlite3_extended_errcode(database))
    }

    static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
