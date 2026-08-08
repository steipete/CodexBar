import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Typed reads

extension CostUsageStore {
    func fetchFile(path: String) -> CostUsageStoreFile? {
        self.withDatabase(default: nil) { database in
            let statement = try Self.prepare(database, Self.fileSelectSQL + " WHERE path = ?")
            defer { sqlite3_finalize(statement) }
            Self.bind(path, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try Self.decodeFile(statement)
        }
    }

    func fetchTokenSnapshots(path: String) -> [CostUsageStoreTokenSnapshot] {
        self.withDatabase(default: []) { database in
            try Self.readTokenSnapshots(database, path: path)
        }
    }

    func fetchUsageRows(path: String) -> [CostUsageStoreUsageRow] {
        self.withDatabase(default: []) { database in
            try Self.readUsageRows(database, path: path)
        }
    }

    func fetchDayAggregates(sinceDay: String, untilDay: String) -> [CostUsageStoreDayAggregate] {
        guard sinceDay <= untilDay else { return [] }
        return self.withDatabase(default: []) { database in
            try Self.readDayAggregates(database, sinceDay: sinceDay, untilDay: untilDay)
        }
    }

    func fetchFileDayAggregates(path: String) -> [CostUsageStoreDayAggregate] {
        self.withDatabase(default: []) { database in
            try Self.readFileDayAggregates(database, path: path).map(\.aggregate)
        }
    }

    func fetchForkLineage(path: String) -> CostUsageStoreForkLineage? {
        self.withDatabase(default: nil) { database in
            let values = try Self.readForkLineage(database, path: path)
            return values.first
        }
    }

    func fetchBufferedLines(
        path: String,
        kind: CostUsageStoreBufferedLineKind? = nil) -> [CostUsageStoreBufferedLine]
    {
        self.withDatabase(default: []) { database in
            try Self.readBufferedLines(database, path: path, kind: kind)
        }
    }

    func fetchDiscoveryState() -> CostUsageStoreDiscoveryState? {
        self.readSingleton(CostUsageStoreDiscoveryState.self, table: "discovery_state")
    }

    func fetchLookbackState() -> CostUsageStoreLookbackState? {
        self.readSingleton(CostUsageStoreLookbackState.self, table: "lookback_state")
    }

    func fetchMetadata() -> CostUsageStoreMetadata {
        self.readSingleton(CostUsageStoreMetadata.self, table: "scan_metadata") ?? .empty
    }

    func fetchAccumulator(path: String) -> CostUsageStoreAccumulator? {
        self.withDatabase(default: nil) { database in
            try Self.readAccumulators(database, path: path).first
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
                    table: "scan_metadata") ?? .empty
                let aggregates = try Self.readDayAggregates(
                    database,
                    sinceDay: sinceDay,
                    untilDay: untilDay)
                return CostUsageStoreReport(metadata: metadata, aggregates: aggregates)
            }
        }
    }

    func readSnapshot() -> CostUsageStoreSnapshot {
        let empty = CostUsageStoreSnapshot(
            metadata: .empty,
            files: [],
            tokenSnapshots: [],
            usageRows: [],
            fileDayAggregates: [],
            dayAggregates: [],
            forkLineage: [],
            bufferedLines: [],
            discoveryState: nil,
            lookbackState: nil,
            accumulators: [])
        return self.withDatabase(default: empty) { database in
            try Self.inReadTransaction(database) {
                try CostUsageStoreSnapshot(
                    metadata: Self.readSingleton(
                        CostUsageStoreMetadata.self,
                        database: database,
                        table: "scan_metadata") ?? .empty,
                    files: Self.readFiles(database),
                    tokenSnapshots: Self.readTokenSnapshots(database, path: nil),
                    usageRows: Self.readUsageRows(database, path: nil),
                    fileDayAggregates: Self.readFileDayAggregates(database, path: nil),
                    dayAggregates: Self.readDayAggregates(database, sinceDay: nil, untilDay: nil),
                    forkLineage: Self.readForkLineage(database, path: nil),
                    bufferedLines: Self.readBufferedLines(database, path: nil, kind: nil),
                    discoveryState: Self.readSingleton(
                        CostUsageStoreDiscoveryState.self,
                        database: database,
                        table: "discovery_state"),
                    lookbackState: Self.readSingleton(
                        CostUsageStoreLookbackState.self,
                        database: database,
                        table: "lookback_state"),
                    accumulators: Self.readAccumulators(database, path: nil))
            }
        }
    }

    func configuration() -> CostUsageStoreConfiguration? {
        self.withDatabase(default: nil) { database in
            try CostUsageStoreConfiguration(
                journalMode: Self.scalarText(database, "PRAGMA journal_mode") ?? "",
                busyTimeoutMilliseconds: Int(Self.scalarInt(database, "PRAGMA busy_timeout")),
                foreignKeysEnabled: Self.scalarInt(database, "PRAGMA foreign_keys") == 1,
                autoVacuumMode: Int(Self.scalarInt(database, "PRAGMA auto_vacuum")),
                userVersion: Int(Self.scalarInt(database, "PRAGMA user_version")))
        }
    }

    private func readSingleton<Value: Decodable>(_ type: Value.Type, table: String) -> Value? {
        self.withDatabase(default: nil) { database in
            try Self.readSingleton(type, database: database, table: table)
        }
    }
}

// MARK: - Read implementations

extension CostUsageStore {
    private static let fileSelectSQL = """
    SELECT path, inode, mtime_ms, size, parsed_bytes, anchor_indexed_bytes,
           anchor_window_start, anchor_sha256, scan_state, scan_target_size,
           scan_complete, session_id, coverage_since_day, coverage_until_day, updated_at_ms
    FROM files
    """

    static func readFiles(_ database: OpaquePointer) throws -> [CostUsageStoreFile] {
        let statement = try self.prepare(database, self.fileSelectSQL + " ORDER BY path")
        defer { sqlite3_finalize(statement) }
        var values: [CostUsageStoreFile] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try values.append(self.decodeFile(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }

    static func decodeFile(_ statement: OpaquePointer) throws -> CostUsageStoreFile {
        guard let path = self.columnText(statement, at: 0),
              let stateData = self.columnData(statement, at: 8)
        else { throw StoreError.invalidData }
        var state = try JSONDecoder().decode(CostUsageStoreScanState.self, from: stateData)
        state.targetSize = self.columnInt64(statement, at: 9)
        state.isComplete = sqlite3_column_int(statement, 10) == 1
        let anchor: CostUsageStoreValidationAnchor? = if let sha = self.columnText(statement, at: 7),
                                                         let indexedBytes = self.columnInt64(statement, at: 5),
                                                         let windowStart = self.columnInt64(statement, at: 6)
        {
            .init(indexedBytes: indexedBytes, windowStart: windowStart, sha256: sha)
        } else {
            nil
        }
        return CostUsageStoreFile(
            path: path,
            inode: self.columnInt64(statement, at: 1),
            mtimeUnixMs: sqlite3_column_int64(statement, 2),
            size: sqlite3_column_int64(statement, 3),
            parsedBytes: self.columnInt64(statement, at: 4),
            anchor: anchor,
            scanState: state,
            sessionID: self.columnText(statement, at: 11),
            coverageSinceDay: self.columnText(statement, at: 12),
            coverageUntilDay: self.columnText(statement, at: 13),
            updatedAtUnixMs: sqlite3_column_int64(statement, 14))
    }

    static func readTokenSnapshots(
        _ database: OpaquePointer,
        path: String?) throws -> [CostUsageStoreTokenSnapshot]
    {
        var sql = """
        SELECT f.path, t.event_index, t.timestamp, t.timestamp_ms, t.day,
               t.last_input, t.last_cached, t.last_output, t.last_reasoning,
               t.total_input, t.total_cached, t.total_output, t.total_reasoning, t.end_offset
        FROM token_snapshots t JOIN files f ON f.id = t.file_id
        """
        if path != nil {
            sql += " WHERE f.path = ?"
        }
        sql += " ORDER BY f.path, t.event_index"
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        if let path {
            self.bind(path, to: statement, at: 1)
        }
        var values: [CostUsageStoreTokenSnapshot] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0),
                  let eventIndex = Int(exactly: sqlite3_column_int64(statement, 1)),
                  let timestamp = self.columnText(statement, at: 2)
            else { throw StoreError.invalidData }
            values.append(CostUsageStoreTokenSnapshot(
                path: path,
                eventIndex: eventIndex,
                timestamp: timestamp,
                timestampUnixMs: self.columnInt64(statement, at: 3),
                day: self.columnText(statement, at: 4),
                last: self.decodeTotals(statement, startingAt: 5),
                total: self.decodeTotals(statement, startingAt: 9),
                endOffset: self.columnInt64(statement, at: 13)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }

    static func readUsageRows(
        _ database: OpaquePointer,
        path: String?) throws -> [CostUsageStoreUsageRow]
    {
        var sql = """
        SELECT f.path, r.row_index, r.payload
        FROM usage_rows r JOIN files f ON f.id = r.file_id
        """
        if path != nil {
            sql += " WHERE f.path = ?"
        }
        sql += " ORDER BY f.path, r.row_index"
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        if let path {
            self.bind(path, to: statement, at: 1)
        }
        var values: [CostUsageStoreUsageRow] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0),
                  let rowIndex = Int(exactly: sqlite3_column_int64(statement, 1)),
                  let payload = self.columnData(statement, at: 2)
            else { throw StoreError.invalidData }
            values.append(CostUsageStoreUsageRow(path: path, rowIndex: rowIndex, payload: payload))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }

    static func readDayAggregates(
        _ database: OpaquePointer,
        sinceDay: String?,
        untilDay: String?) throws -> [CostUsageStoreDayAggregate]
    {
        var sql = """
        SELECT day, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens,
               request_count, authoritative_cost_nanos,
               standard_input_tokens, standard_cached_tokens, standard_output_tokens,
               priority_input_tokens, priority_cached_tokens, priority_output_tokens,
               standard_tokens, priority_tokens
        FROM day_aggregates
        """
        if sinceDay != nil, untilDay != nil {
            sql += " WHERE day >= ? AND day <= ?"
        }
        sql += " ORDER BY day, model"
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        if let sinceDay, let untilDay {
            self.bind(sinceDay, to: statement, at: 1)
            self.bind(untilDay, to: statement, at: 2)
        }
        var values: [CostUsageStoreDayAggregate] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let day = self.columnText(statement, at: 0),
                  let model = self.columnText(statement, at: 1)
            else { throw StoreError.invalidData }
            values.append(CostUsageStoreDayAggregate(
                day: day,
                model: model,
                inputTokens: sqlite3_column_int64(statement, 2),
                cachedTokens: sqlite3_column_int64(statement, 3),
                outputTokens: sqlite3_column_int64(statement, 4),
                reasoningTokens: sqlite3_column_int64(statement, 5),
                requestCount: sqlite3_column_int64(statement, 6),
                authoritativeCostNanos: sqlite3_column_int64(statement, 7),
                standardInputTokens: sqlite3_column_int64(statement, 8),
                standardCachedTokens: sqlite3_column_int64(statement, 9),
                standardOutputTokens: sqlite3_column_int64(statement, 10),
                priorityInputTokens: sqlite3_column_int64(statement, 11),
                priorityCachedTokens: sqlite3_column_int64(statement, 12),
                priorityOutputTokens: sqlite3_column_int64(statement, 13),
                standardTokens: sqlite3_column_int64(statement, 14),
                priorityTokens: sqlite3_column_int64(statement, 15)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }

    static func readFileDayAggregates(
        _ database: OpaquePointer,
        path: String?) throws -> [CostUsageStoreFileDayAggregate]
    {
        var sql = """
        SELECT f.path, a.day, a.model, a.input_tokens, a.cached_tokens, a.output_tokens,
               a.reasoning_tokens, a.request_count, a.authoritative_cost_nanos,
               a.standard_input_tokens, a.standard_cached_tokens, a.standard_output_tokens,
               a.priority_input_tokens, a.priority_cached_tokens, a.priority_output_tokens,
               a.standard_tokens, a.priority_tokens
        FROM file_day_aggregates a JOIN files f ON f.id = a.file_id
        """
        if path != nil {
            sql += " WHERE f.path = ?"
        }
        sql += " ORDER BY f.path, a.day, a.model"
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        if let path {
            self.bind(path, to: statement, at: 1)
        }
        var values: [CostUsageStoreFileDayAggregate] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0),
                  let day = self.columnText(statement, at: 1),
                  let model = self.columnText(statement, at: 2)
            else { throw StoreError.invalidData }
            values.append(CostUsageStoreFileDayAggregate(
                path: path,
                aggregate: CostUsageStoreDayAggregate(
                    day: day,
                    model: model,
                    inputTokens: sqlite3_column_int64(statement, 3),
                    cachedTokens: sqlite3_column_int64(statement, 4),
                    outputTokens: sqlite3_column_int64(statement, 5),
                    reasoningTokens: sqlite3_column_int64(statement, 6),
                    requestCount: sqlite3_column_int64(statement, 7),
                    authoritativeCostNanos: sqlite3_column_int64(statement, 8),
                    standardInputTokens: sqlite3_column_int64(statement, 9),
                    standardCachedTokens: sqlite3_column_int64(statement, 10),
                    standardOutputTokens: sqlite3_column_int64(statement, 11),
                    priorityInputTokens: sqlite3_column_int64(statement, 12),
                    priorityCachedTokens: sqlite3_column_int64(statement, 13),
                    priorityOutputTokens: sqlite3_column_int64(statement, 14),
                    standardTokens: sqlite3_column_int64(statement, 15),
                    priorityTokens: sqlite3_column_int64(statement, 16))))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }
}

extension CostUsageStore {
    static func readForkLineage(
        _ database: OpaquePointer,
        path: String?) throws -> [CostUsageStoreForkLineage]
    {
        var sql = """
        SELECT f.path, l.session_id, l.forked_from_id, l.fork_timestamp,
               l.dependency_key, l.subagent_state, l.accounting_state
        FROM fork_lineage l JOIN files f ON f.id = l.file_id
        """
        if path != nil {
            sql += " WHERE f.path = ?"
        }
        sql += " ORDER BY f.path"
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        if let path {
            self.bind(path, to: statement, at: 1)
        }
        var values: [CostUsageStoreForkLineage] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0) else { throw StoreError.invalidData }
            values.append(CostUsageStoreForkLineage(
                path: path,
                sessionID: self.columnText(statement, at: 1),
                forkedFromID: self.columnText(statement, at: 2),
                forkTimestamp: self.columnText(statement, at: 3),
                dependencyKey: self.columnText(statement, at: 4),
                subagentState: self.columnData(statement, at: 5),
                accountingState: self.columnData(statement, at: 6)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }

    static func readBufferedLines(
        _ database: OpaquePointer,
        path: String?,
        kind: CostUsageStoreBufferedLineKind?) throws -> [CostUsageStoreBufferedLine]
    {
        var sql = """
        SELECT f.path, b.kind, b.line_index, b.ordinal, b.end_offset, b.payload
        FROM buffered_lines b JOIN files f ON f.id = b.file_id
        """
        var clauses: [String] = []
        if path != nil {
            clauses.append("f.path = ?")
        }
        if kind != nil {
            clauses.append("b.kind = ?")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY f.path, b.kind, b.line_index"
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let path {
            self.bind(path, to: statement, at: index)
            index += 1
        }
        if let kind {
            self.bind(kind.rawValue, to: statement, at: index)
        }
        var values: [CostUsageStoreBufferedLine] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0),
                  let rawKind = self.columnText(statement, at: 1),
                  let kind = CostUsageStoreBufferedLineKind(rawValue: rawKind),
                  let lineIndex = Int(exactly: sqlite3_column_int64(statement, 2)),
                  let payload = self.columnData(statement, at: 5)
            else { throw StoreError.invalidData }
            values.append(CostUsageStoreBufferedLine(
                path: path,
                kind: kind,
                lineIndex: lineIndex,
                ordinal: self.columnInt64(statement, at: 3).flatMap(Int.init(exactly:)),
                endOffset: self.columnInt64(statement, at: 4),
                payload: payload))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }

    static func readAccumulators(
        _ database: OpaquePointer,
        path: String?) throws -> [CostUsageStoreAccumulator]
    {
        var sql = """
        SELECT f.path, a.event_count, a.next_usage_row_index,
               a.counted_input, a.counted_cached, a.counted_output, a.counted_reasoning,
               a.baseline_input, a.baseline_cached, a.baseline_output, a.baseline_reasoning,
               a.watermark_input, a.watermark_cached, a.watermark_output, a.watermark_reasoning,
               a.saw_divergent, a.saw_interleaved, a.seen_raw_totals, a.updated_at_ms
        FROM accumulators a JOIN files f ON f.id = a.file_id
        """
        if path != nil {
            sql += " WHERE f.path = ?"
        }
        sql += " ORDER BY f.path"
        let statement = try self.prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        if let path {
            self.bind(path, to: statement, at: 1)
        }
        var values: [CostUsageStoreAccumulator] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0),
                  let eventCount = Int(exactly: sqlite3_column_int64(statement, 1)),
                  let seenData = self.columnData(statement, at: 17)
            else { throw StoreError.invalidData }
            let seen = try JSONDecoder().decode([CostUsageStoreTotals].self, from: seenData)
            values.append(CostUsageStoreAccumulator(
                path: path,
                eventCount: eventCount,
                nextUsageRowIndex: self.columnInt64(statement, at: 2).flatMap(Int.init(exactly:)),
                countedTotals: self.decodeTotals(statement, startingAt: 3),
                rawTotalsBaseline: self.decodeTotals(statement, startingAt: 7),
                rawTotalsWatermark: self.decodeTotals(statement, startingAt: 11),
                sawDivergentTotals: sqlite3_column_int(statement, 15) == 1,
                sawInterleavedTotals: sqlite3_column_int(statement, 16) == 1,
                seenRawTotals: seen,
                updatedAtUnixMs: sqlite3_column_int64(statement, 18)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }
}

// MARK: - Read helpers

extension CostUsageStore {
    static func readSingleton<Value: Decodable>(
        _ type: Value.Type,
        database: OpaquePointer,
        table: String) throws -> Value?
    {
        let statement = try self.prepare(database, "SELECT payload FROM \(table) WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW, let payload = self.columnData(statement, at: 0) else {
            throw StoreError.sqlite(result)
        }
        return try JSONDecoder().decode(type, from: payload)
    }

    static func decodeTotals(_ statement: OpaquePointer, startingAt index: Int32) -> CostUsageStoreTotals? {
        guard let input = self.columnInt64(statement, at: index),
              let cached = self.columnInt64(statement, at: index + 1),
              let output = self.columnInt64(statement, at: index + 2)
        else { return nil }
        return CostUsageStoreTotals(
            input: input,
            cached: cached,
            output: output,
            reasoning: self.columnInt64(statement, at: index + 3))
    }

    static func inReadTransaction<T>(_ database: OpaquePointer, _ operation: () throws -> T) throws -> T {
        try self.execute(database, "BEGIN")
        do {
            let value = try operation()
            try self.execute(database, "COMMIT")
            return value
        } catch {
            try? self.execute(database, "ROLLBACK")
            throw error
        }
    }
}
