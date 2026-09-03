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
        if database != nil {
            budget.statistics.sqliteHandlesOpened += 1
        }
        guard opened == SQLITE_OK, let database else {
            if let database, sqlite3_close(database) == SQLITE_OK {
                budget.statistics.sqliteHandlesClosed += 1
            }
            return SourceResult(isComplete: false)
        }
        defer {
            if sqlite3_close(database) == SQLITE_OK {
                budget.statistics.sqliteHandlesClosed += 1
            }
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
            if let failure = progress.failure {
                throw failure
            }
            return SourceResult(isComplete: false)
        }
        let supported = try self.hasSupportedSQLiteTable(database, budget: budget)
        if let failure = progress.failure {
            throw failure
        }
        guard supported else { return SourceResult(isComplete: false) }
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
        if let failure = progress.failure {
            throw failure
        }
        guard prepared == SQLITE_OK, let activeStatement = statement else { return SourceResult(isComplete: false) }
        sqlite3_bind_int64(activeStatement, 1, Int64(min(budget.limits.rowsPerDatabase, 10000) + 1))
        let session = url.deletingPathExtension().lastPathComponent
        var rows = try self.readRows(activeStatement, session: session, progress: progress)
        if !rows.pendingTimestampRows.isEmpty {
            // Positional recovery is safe only when every generation row participated in the occurrence list.
            // A malformed row can still carry a reused step UUID, so partial primary scans must not realign later rows.
            guard rows.source.isComplete else { return rows.source }
            // Release the gen_metadata cursor before the optional steps pass reuses the same snapshot.
            sqlite3_finalize(activeStatement)
            statement = nil
            let hasSteps = try self.hasSupportedStepsTable(database, budget: budget)
            if let failure = progress.failure {
                throw failure
            }
            if hasSteps {
                var neededStepUUIDCounts: [String: Int] = [:]
                for stepUUID in Set(rows.pendingTimestampRows.map(\.stepUUID)) {
                    neededStepUUIDCounts[stepUUID] = rows.stepOccurrenceRows[stepUUID]?.count ?? 0
                }
                let stepScan = try self.readStepTimestamps(
                    database,
                    neededStepUUIDCounts: neededStepUUIDCounts,
                    progress: progress)
                guard stepScan.isComplete else {
                    rows.source.isComplete = false
                    return rows.source
                }
                let recoveredCount = self.appendRecoveredEvents(
                    to: &rows.source,
                    session: session,
                    pendingRows: rows.pendingTimestampRows,
                    stepTimestamps: stepScan.timestamps,
                    stepOccurrenceRows: rows.stepOccurrenceRows)
                if recoveredCount < rows.pendingTimestampRows.count {
                    rows.source.isComplete = false
                }
            } else {
                rows.source.isComplete = false
            }
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
        var stepOccurrenceRows: [String: [Int64]]
    }

    private struct StepTimestamp {
        let row: Int64
        let timestampMs: Int64?
    }

    private struct StepTimestampScan {
        let timestamps: [String: [Int64]]
        let isComplete: Bool
    }

    private final class StepScanProgress {
        let progress: SQLProgress

        var payloadLimit: Int {
            let budget = self.progress.budget
            guard budget.statistics.rows < budget.limits.rows,
                  self.progress.databaseBytes < budget.limits.databaseBytes,
                  budget.statistics.attemptedBytes < budget.limits.bytes
            else { return 0 }
            return min(
                budget.limits.blobBytes,
                budget.limits.databaseBytes - self.progress.databaseBytes,
                budget.limits.bytes - budget.statistics.attemptedBytes)
        }

        init(progress: SQLProgress) {
            self.progress = progress
        }
    }

    private static func readStepTimestamps(
        _ database: OpaquePointer,
        neededStepUUIDCounts: [String: Int],
        progress: SQLProgress) throws -> StepTimestampScan
    {
        guard !neededStepUUIDCounts.isEmpty else { return StepTimestampScan(timestamps: [:], isComplete: true) }
        let stepProgress = StepScanProgress(progress: progress)
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
        guard registered == SQLITE_OK else { return StepTimestampScan(timestamps: [:], isComplete: false) }
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
        FROM main.steps NOT INDEXED
        """
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        if let failure = progress.failure {
            throw failure
        }
        guard prepared == SQLITE_OK, let statement else {
            return StepTimestampScan(timestamps: [:], isComplete: false)
        }
        var stepTimestamps: [String: [StepTimestamp]] = [:]
        var isComplete = false
        var rowsAreValid = true
        while true {
            try progress.budget.check()
            let step = sqlite3_step(statement)
            if let failure = progress.failure {
                throw failure
            }
            if step == SQLITE_DONE {
                isComplete = true
                break
            }
            guard step == SQLITE_ROW else { break }
            let payload = SQLitePayload(statement: statement)
            progress.budget.statistics.materializedPayloadBytes += payload.byteCount
            // Every secondary row belongs to the job-wide budget; the separate byte ceiling only
            // prevents one database's step metadata from consuming the whole job allocation.
            try progress.budget.chargeRow()
            let count = Int(sqlite3_column_int64(statement, 1))
            let attemptedBytes = max(count, payload.byteCount)
            try progress.budget.chargeBytes(attemptedBytes)
            guard attemptedBytes <= progress.budget.limits.databaseBytes - progress.databaseBytes
            else { break }
            progress.databaseBytes += attemptedBytes
            guard count > 0, count <= progress.budget.limits.blobBytes,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 0) >= 0,
                  let bytes = payload.copy(declaredCount: count, limit: progress.budget.limits.blobBytes)
            else {
                rowsAreValid = false
                continue
            }
            guard let parsed = try AntigravityProtoReader.parseStepMetadata(
                bytes, checkCancellation: progress.budget.check)
            else {
                rowsAreValid = false
                continue
            }
            guard let stepUUID = parsed.stepUUID, !stepUUID.isEmpty else {
                rowsAreValid = false
                continue
            }
            if neededStepUUIDCounts[stepUUID] != nil {
                stepTimestamps[stepUUID, default: []].append(StepTimestamp(
                    row: sqlite3_column_int64(statement, 0),
                    timestampMs: parsed.timestampMs))
            }
        }
        var resolved: [String: [Int64]] = [:]
        for (stepUUID, timestamps) in stepTimestamps {
            guard let neededCount = neededStepUUIDCounts[stepUUID] else { continue }
            let sorted = timestamps.sorted { $0.row < $1.row }
            // The defensive schema does not require idx to be a key. Conflicting duplicate indices
            // cannot be ordered safely, so withhold that UUID instead of publishing a false date.
            guard !zip(sorted, sorted.dropFirst()).contains(where: { pair in pair.0.row == pair.1.row }) else {
                continue
            }
            let orderedTimestamps = sorted.map(\.timestampMs)
            if orderedTimestamps.count == 1, let sharedTimestamp = orderedTimestamps[0] {
                resolved[stepUUID] = Array(repeating: sharedTimestamp, count: neededCount)
                continue
            }
            guard orderedTimestamps.count >= neededCount else { continue }
            let selected = orderedTimestamps.prefix(neededCount)
            guard selected.allSatisfy({ $0 != nil }) else { continue }
            resolved[stepUUID] = selected.compactMap(\.self)
        }
        return StepTimestampScan(timestamps: resolved, isComplete: isComplete && rowsAreValid)
    }

    private static func readRows(
        _ statement: OpaquePointer,
        session: String,
        progress: SQLProgress) throws -> ParsedRows
    {
        let budget = progress.budget
        var result = SourceResult()
        var pendingTimestampRows: [PendingTimestampRow] = []
        var stepOccurrenceRows: [String: [Int64]] = [:]
        while true {
            try budget.check()
            let step = sqlite3_step(statement)
            if let failure = progress.failure {
                throw failure
            }
            if step == SQLITE_DONE {
                break
            }
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
            if let stepUUID = turn.stepUUID {
                stepOccurrenceRows[stepUUID, default: []].append(row)
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
        return ParsedRows(
            source: result,
            pendingTimestampRows: pendingTimestampRows,
            stepOccurrenceRows: stepOccurrenceRows)
    }

    private static func appendRecoveredEvents(
        to source: inout SourceResult,
        session: String,
        pendingRows: [PendingTimestampRow],
        stepTimestamps: [String: [Int64]],
        stepOccurrenceRows: [String: [Int64]]) -> Int
    {
        var occurrenceOffsets: [String: [Int64: Int]] = [:]
        for (stepUUID, rows) in stepOccurrenceRows {
            let sorted = rows.sorted()
            guard Set(sorted).count == sorted.count else { continue }
            occurrenceOffsets[stepUUID] = Dictionary(
                uniqueKeysWithValues: sorted.enumerated().map { ($0.element, $0.offset) })
        }
        var recoveredCount = 0
        for pending in pendingRows.sorted(by: { $0.row < $1.row }) {
            guard let timestamps = stepTimestamps[pending.stepUUID],
                  let offset = occurrenceOffsets[pending.stepUUID]?[pending.row]
            else {
                continue
            }
            guard timestamps.indices.contains(offset) else { continue }
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
