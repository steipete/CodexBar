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
        let tables = try self.supportedSQLiteTables(database, budget: budget)
        if let failure = progress.failure { throw failure }
        guard tables.hasGenMetadata else { return SourceResult(isComplete: false) }
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
        guard prepared == SQLITE_OK, let activeStatement = statement else { return SourceResult(isComplete: false) }
        sqlite3_bind_int64(activeStatement, 1, Int64(min(budget.limits.rowsPerDatabase, 10000) + 1))
        let session = url.deletingPathExtension().lastPathComponent
        var rows = try self.readRows(activeStatement, session: session, progress: progress)
        if tables.hasSteps, !rows.pendingTimestampRows.isEmpty {
            // Release the gen_metadata cursor before the optional steps pass reuses the same snapshot.
            sqlite3_finalize(activeStatement)
            statement = nil
            let neededStepUUIDs = Set(rows.pendingTimestampRows.map(\.stepUUID))
            let stepTimestamps = try self.readStepTimestamps(
                database,
                neededStepUUIDs: neededStepUUIDs,
                progress: progress)
            let recoveredCount = self.appendRecoveredEvents(
                to: &rows.source,
                session: session,
                pendingRows: rows.pendingTimestampRows,
                stepTimestamps: stepTimestamps)
            if recoveredCount < rows.pendingTimestampRows.count {
                rows.source.isComplete = false
            }
        } else if !rows.pendingTimestampRows.isEmpty {
            rows.source.isComplete = false
        }
        return rows.source
        #else
        return SourceResult(isComplete: false)
        #endif
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private struct PendingTimestampRow {
        let row: Int64
        let stepUUID: String
        let turn: AntigravityProtoReader.ParsedTurn
    }

    private struct ParsedRows {
        var source: SourceResult
        var pendingTimestampRows: [PendingTimestampRow]
    }

    private final class StepScanProgress {
        let budget: Budget
        let rowLimit: Int
        let byteLimit: Int
        var rows = 0
        var bytes = 0

        var payloadLimit: Int {
            guard self.rows < self.rowLimit else { return 0 }
            return min(
                self.budget.limits.blobBytes,
                self.byteLimit - self.bytes,
                self.budget.limits.bytes - self.budget.statistics.attemptedBytes)
        }

        init(budget: Budget, neededStepUUIDCount: Int) {
            self.budget = budget
            self.rowLimit = min(budget.limits.rowsPerDatabase, max(neededStepUUIDCount * 32, 256), 10000)
            self.byteLimit = min(
                budget.limits.databaseBytes,
                max(budget.limits.blobBytes, neededStepUUIDCount * 64 * 1024))
        }
    }

    private static func readStepTimestamps(
        _ database: OpaquePointer,
        neededStepUUIDs: Set<String>,
        progress: SQLProgress) throws -> [String: [Int64]]
    {
        guard !neededStepUUIDs.isEmpty else { return [:] }
        let stepProgress = StepScanProgress(budget: progress.budget, neededStepUUIDCount: neededStepUUIDs.count)
        let registered = sqlite3_create_function_v2(
            database,
            "antigravity_step_payload_limit",
            0,
            SQLITE_UTF8,
            Unmanaged.passUnretained(stepProgress).toOpaque(),
            { context, _, _ in
                guard let context, let pointer = sqlite3_user_data(context) else { return }
                let progress = Unmanaged<StepScanProgress>.fromOpaque(pointer).takeUnretainedValue()
                sqlite3_result_int64(context, Int64(progress.payloadLimit))
            },
            nil,
            nil,
            nil)
        guard registered == SQLITE_OK else { return [:] }
        var statement: OpaquePointer?
        defer {
            withExtendedLifetime(stepProgress) {
                sqlite3_finalize(statement)
                sqlite3_create_function_v2(
                    database,
                    "antigravity_step_payload_limit",
                    0,
                    SQLITE_UTF8,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil)
            }
        }
        let query = """
        SELECT idx, CASE WHEN typeof(metadata) = 'blob' THEN length(metadata) END,
            CASE WHEN typeof(metadata) = 'blob'
                AND length(metadata) <= antigravity_step_payload_limit() THEN metadata END
        FROM main.steps NOT INDEXED WHERE metadata IS NOT NULL LIMIT ?
        """
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        if let failure = progress.failure { throw failure }
        guard prepared == SQLITE_OK, let statement else { return [:] }
        sqlite3_bind_int64(statement, 1, Int64(stepProgress.rowLimit + 1))
        var stepTimestamps: [String: [Int64]] = [:]
        while true {
            try progress.budget.check()
            let step = sqlite3_step(statement)
            if let failure = progress.failure { throw failure }
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { break }
            let payload = SQLitePayload(statement: statement)
            progress.budget.statistics.materializedPayloadBytes += payload.byteCount
            stepProgress.rows += 1
            // The optional pass keeps its own per-database ceilings, but every row it touches still
            // belongs to the job-wide budget: charge it before the step limits get a chance to stop.
            try progress.budget.chargeRow()
            let count = Int(sqlite3_column_int64(statement, 1))
            let attemptedBytes = max(count, payload.byteCount)
            try progress.budget.chargeBytes(attemptedBytes)
            guard stepProgress.rows <= stepProgress.rowLimit,
                  attemptedBytes <= stepProgress.byteLimit - stepProgress.bytes
            else { break }
            stepProgress.bytes += attemptedBytes
            guard count > 0, count <= progress.budget.limits.blobBytes,
                  let bytes = payload.copy(declaredCount: count, limit: progress.budget.limits.blobBytes)
            else { continue }
            if let (stepUUID, timestampMs) = try AntigravityProtoReader.parseStepMetadata(
                bytes, checkCancellation: progress.budget.check),
                let stepUUID, neededStepUUIDs.contains(stepUUID), let timestampMs
            {
                stepTimestamps[stepUUID, default: []].append(timestampMs)
                if stepTimestamps.values.reduce(0, { $0 + $1.count }) >= stepProgress.rowLimit {
                    break
                }
            }
        }
        return stepTimestamps
    }

    private static func readRows(
        _ statement: OpaquePointer,
        session: String,
        progress: SQLProgress) throws -> ParsedRows
    {
        let budget = progress.budget
        var result = SourceResult()
        var pendingTimestampRows: [PendingTimestampRow] = []
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
            guard let turn = try AntigravityProtoReader.parseTurn(bytes, checkCancellation: budget.check) else {
                result.isComplete = false
                continue
            }
            if turn.timestampMs == nil, let stepUUID = turn.stepUUID {
                pendingTimestampRows.append(PendingTimestampRow(row: row, stepUUID: stepUUID, turn: turn))
                continue
            }
            guard let event = Event(session: session, row: row, turn: turn, cacheWrite: 0) else {
                result.isComplete = false
                continue
            }
            result.events.append(event)
        }
        return ParsedRows(source: result, pendingTimestampRows: pendingTimestampRows)
    }

    private static func appendRecoveredEvents(
        to source: inout SourceResult,
        session: String,
        pendingRows: [PendingTimestampRow],
        stepTimestamps: [String: [Int64]]) -> Int
    {
        var offsets: [String: Int] = [:]
        var recoveredCount = 0
        for pending in pendingRows {
            let offset = offsets[pending.stepUUID, default: 0]
            guard let timestamps = stepTimestamps[pending.stepUUID],
                  timestamps.indices.contains(offset)
            else { continue }
            offsets[pending.stepUUID] = offset + 1
            var turn = pending.turn
            turn.timestampMs = timestamps[offset]
            if let event = Event(session: session, row: pending.row, turn: turn, cacheWrite: 0) {
                source.events.append(event)
                recoveredCount += 1
            }
        }
        return recoveredCount
    }
    #endif
}
