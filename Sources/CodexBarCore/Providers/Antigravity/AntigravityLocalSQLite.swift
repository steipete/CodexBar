import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

extension AntigravityLocalReader {
    static func readDatabases(_ paths: [URL], budget: Budget) throws -> SourceResult {
        var result = SourceResult()
        for url in paths {
            try budget.check()
            budget.statistics.files += 1
            guard budget.statistics.files <= budget.limits.databases else { throw ScanFailure.exhausted }
            let source = try self.readDatabase(url, budget: budget)
            result.events.append(contentsOf: source.events)
            result.isComplete = result.isComplete && source.isComplete
        }
        return result
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private final class SQLProgress {
        let budget: Budget
        var failure: Error?
        var databaseBytes = 0
        var databaseRows = 0

        var payloadLimit: Int {
            guard self.budget.statistics.rows < self.budget.limits.rows,
                  self.databaseRows < self.budget.limits.rowsPerDatabase else { return 0 }
            return min(
                self.budget.limits.blobBytes,
                self.budget.limits.databaseBytes - self.databaseBytes,
                self.budget.limits.bytes - self.budget.statistics.attemptedBytes)
        }

        init(budget: Budget) {
            self.budget = budget
        }

        func advance() -> Int32 {
            do {
                try self.budget.check()
                return 0
            } catch {
                self.failure = error
                return 1
            }
        }
    }
    #endif

    private static func readDatabase(_ url: URL, budget: Budget) throws -> SourceResult {
        #if canImport(SQLite3) || canImport(CSQLite3)
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        if database != nil { budget.statistics.sqliteHandlesOpened += 1 }
        guard opened == SQLITE_OK, let database else {
            if let database, sqlite3_close(database) == SQLITE_OK { budget.statistics.sqliteHandlesClosed += 1 }
            return SourceResult(isComplete: false)
        }
        defer {
            if sqlite3_close(database) == SQLITE_OK { budget.statistics.sqliteHandlesClosed += 1 }
        }
        let progress = SQLProgress(budget: budget)
        // Also bound SQLite's own intermediate values, before step can materialize a hostile record/view.
        let maximumValueBytes = min(budget.limits.blobBytes, 16 * 1024 * 1024) + 1024
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(min(maximumValueBytes, 64 * 1024)))
        let registered = sqlite3_create_function_v2(
            database,
            "antigravity_payload_limit",
            0,
            SQLITE_UTF8,
            Unmanaged.passUnretained(progress).toOpaque(),
            { context, _, _ in
                guard let context, let pointer = sqlite3_user_data(context) else { return }
                let progress = Unmanaged<SQLProgress>.fromOpaque(pointer).takeUnretainedValue()
                sqlite3_result_int64(context, Int64(progress.payloadLimit))
            },
            nil,
            nil,
            nil)
        guard registered == SQLITE_OK else { return SourceResult(isComplete: false) }
        sqlite3_progress_handler(
            database,
            1000,
            { pointer in
                guard let pointer else { return 1 }
                return Unmanaged<SQLProgress>.fromOpaque(pointer).takeUnretainedValue().advance()
            },
            Unmanaged.passUnretained(progress).toOpaque())
        defer {
            withExtendedLifetime(progress) {
                sqlite3_progress_handler(database, 0, nil, nil)
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            }
        }
        // Ordinary read-only SQLite permits WAL read-mark coordination; it does not promise unchanged SHM bytes.
        guard sqlite3_exec(database, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
            if let failure = progress.failure { throw failure }
            return SourceResult(isComplete: false)
        }
        let supported = try self.hasSupportedSQLiteTable(database, budget: budget)
        if let failure = progress.failure { throw failure }
        guard supported else { return SourceResult(isComplete: false) }
        let sessionTimestampMs = try self.readSessionTimestamp(database, budget: budget)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(maximumValueBytes))
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // length(BLOB) reads its size without loading the payload. The non-deterministic limit is
        // evaluated for each row against the remaining job budget, before selecting any payload.
        // No ORDER BY: a sorter could otherwise materialize multiple payloads ahead of accounting.
        let query = """
        SELECT idx, CASE WHEN typeof(data) = 'blob' THEN length(data) END,
            CASE WHEN typeof(data) = 'blob' AND length(data) <= antigravity_payload_limit() THEN data END
        FROM main.gen_metadata NOT INDEXED LIMIT ?
        """
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        if let failure = progress.failure { throw failure }
        guard prepared == SQLITE_OK, let statement else { return SourceResult(isComplete: false) }
        sqlite3_bind_int64(statement, 1, Int64(min(budget.limits.rowsPerDatabase, 10000) + 1))
        return try self.readRows(
            statement,
            session: url.deletingPathExtension().lastPathComponent,
            sessionTimestampMs: sessionTimestampMs,
            progress: progress)
        #else
        return SourceResult(isComplete: false)
        #endif
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func readRows(
        _ statement: OpaquePointer,
        session: String,
        sessionTimestampMs: Int64?,
        progress: SQLProgress) throws -> SourceResult
    {
        let budget = progress.budget
        var result = SourceResult()
        while true {
            try budget.check()
            let step = sqlite3_step(statement)
            if let failure = progress.failure { throw failure }
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                result.isComplete = false
                break
            }
            let payload = SQLitePayload(statement: statement)
            budget.statistics.materializedPayloadBytes += payload.byteCount
            progress.databaseRows += 1
            try budget.chargeRow()
            // Count every row, even NULL/empty records, and charge rejected bytes before another attempt.
            let count = Int(sqlite3_column_int64(statement, 1))
            let attemptedBytes = max(count, payload.byteCount)
            try budget.chargeBytes(attemptedBytes)
            guard progress.databaseRows <= budget.limits.rowsPerDatabase,
                  attemptedBytes <= budget.limits.databaseBytes - progress.databaseBytes
            else {
                throw ScanFailure.exhausted
            }
            progress.databaseBytes += attemptedBytes
            guard count > 0, count <= budget.limits.blobBytes,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER
            else {
                result.isComplete = false
                continue
            }
            let row = sqlite3_column_int64(statement, 0)
            guard row >= 0 else {
                result.isComplete = false
                continue
            }
            guard let bytes = payload.copy(declaredCount: count, limit: budget.limits.blobBytes) else {
                result.isComplete = false
                continue
            }
            // Validate exactly once while the single SQL snapshot is held; buffer only typed events.
            guard let turn = try AntigravityProtoReader.parseTurn(
                bytes,
                sessionTimestampMs: sessionTimestampMs,
                checkCancellation: budget.check)
            else {
                result.isComplete = false
                continue
            }
            if turn.isConversationAggregate { continue }
            guard let event = Event(session: session, row: row, turn: turn, cacheWrite: 0) else {
                result.isComplete = false
                continue
            }
            result.events.append(event)
        }
        return result
    }

    private static func readSessionTimestamp(
        _ database: OpaquePointer,
        budget: Budget) throws -> Int64?
    {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // This table is absent in older Antigravity databases. Its timestamp is only a
        // session-start fallback for the newer opaque per-turn timestamp layout.
        guard sqlite3_prepare_v2(
            database,
            "SELECT data FROM main.trajectory_metadata_blob LIMIT 1",
            -1,
            &statement,
            nil) == SQLITE_OK,
            let statement
        else {
            return nil
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(statement, 0) == SQLITE_BLOB,
              let pointer = sqlite3_column_blob(statement, 0)
        else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else { return nil }
        try budget.chargeBytes(count)
        let bytes = Array(UnsafeBufferPointer(
            start: pointer.assumingMemoryBound(to: UInt8.self), count: count))
        do {
            return try AntigravityProtoReader.sessionCreatedTimestampMs(bytes, checkCancellation: budget.check)
        } catch AntigravityLocalReader.ScanFailure.invalid {
            return nil
        }
    }
    #endif
}
