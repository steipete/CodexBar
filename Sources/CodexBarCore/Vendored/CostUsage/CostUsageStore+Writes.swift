import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Files and token deltas

extension CostUsageStore {
    @discardableResult
    func upsertFile(_ file: CostUsageStoreFile) -> Bool {
        self.withDatabase(default: false) { database in
            let state = try JSONEncoder().encode(file.scanState)
            let statement = try Self.prepare(database, """
            INSERT INTO files (
                path, inode, mtime_ms, size, parsed_bytes, anchor_indexed_bytes,
                anchor_window_start, anchor_sha256, scan_state, scan_target_size,
                scan_complete, session_id, coverage_since_day, coverage_until_day, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                inode = excluded.inode,
                mtime_ms = excluded.mtime_ms,
                size = excluded.size,
                parsed_bytes = excluded.parsed_bytes,
                anchor_indexed_bytes = excluded.anchor_indexed_bytes,
                anchor_window_start = excluded.anchor_window_start,
                anchor_sha256 = excluded.anchor_sha256,
                scan_state = excluded.scan_state,
                scan_target_size = excluded.scan_target_size,
                scan_complete = excluded.scan_complete,
                session_id = excluded.session_id,
                coverage_since_day = excluded.coverage_since_day,
                coverage_until_day = excluded.coverage_until_day,
                updated_at_ms = excluded.updated_at_ms
            """)
            defer { sqlite3_finalize(statement) }
            Self.bind(file.path, to: statement, at: 1)
            Self.bind(file.inode, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, file.mtimeUnixMs)
            sqlite3_bind_int64(statement, 4, file.size)
            Self.bind(file.parsedBytes, to: statement, at: 5)
            Self.bind(file.anchor?.indexedBytes, to: statement, at: 6)
            Self.bind(file.anchor?.windowStart, to: statement, at: 7)
            Self.bind(file.anchor?.sha256, to: statement, at: 8)
            Self.bind(state, to: statement, at: 9)
            Self.bind(file.scanState.targetSize, to: statement, at: 10)
            sqlite3_bind_int(statement, 11, file.scanState.isComplete ? 1 : 0)
            Self.bind(file.sessionID, to: statement, at: 12)
            Self.bind(file.coverageSinceDay, to: statement, at: 13)
            Self.bind(file.coverageUntilDay, to: statement, at: 14)
            sqlite3_bind_int64(statement, 15, file.updatedAtUnixMs)
            try Self.stepDone(statement, database: database)
            return true
        }
    }

    @discardableResult
    func appendTokenSnapshots(_ snapshots: [CostUsageStoreTokenSnapshot]) -> Bool {
        guard !snapshots.isEmpty else { return true }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                let statement = try Self.prepare(database, """
                INSERT INTO token_snapshots (
                    file_id, event_index, timestamp, timestamp_ms, day,
                    last_input, last_cached, last_output, last_reasoning,
                    total_input, total_cached, total_output, total_reasoning, end_offset
                ) VALUES ((SELECT id FROM files WHERE path = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_id, event_index) DO UPDATE SET
                    timestamp = excluded.timestamp,
                    timestamp_ms = excluded.timestamp_ms,
                    day = excluded.day,
                    last_input = excluded.last_input,
                    last_cached = excluded.last_cached,
                    last_output = excluded.last_output,
                    last_reasoning = excluded.last_reasoning,
                    total_input = excluded.total_input,
                    total_cached = excluded.total_cached,
                    total_output = excluded.total_output,
                    total_reasoning = excluded.total_reasoning,
                    end_offset = excluded.end_offset
                """)
                defer { sqlite3_finalize(statement) }
                for snapshot in snapshots {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    Self.bind(snapshot.path, to: statement, at: 1)
                    sqlite3_bind_int64(statement, 2, Int64(snapshot.eventIndex))
                    Self.bind(snapshot.timestamp, to: statement, at: 3)
                    Self.bind(snapshot.timestampUnixMs, to: statement, at: 4)
                    Self.bind(snapshot.day, to: statement, at: 5)
                    Self.bindTotals(snapshot.last, to: statement, startingAt: 6)
                    Self.bindTotals(snapshot.total, to: statement, startingAt: 10)
                    Self.bind(snapshot.endOffset, to: statement, at: 14)
                    try Self.stepDone(statement, database: database)
                }
            }
            return true
        }
    }

    @discardableResult
    func replaceTokenSnapshots(path: String, snapshots: [CostUsageStoreTokenSnapshot]) -> Bool {
        guard snapshots.allSatisfy({ $0.path == path }) else { return false }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                let delete = try Self.prepare(database, """
                DELETE FROM token_snapshots WHERE file_id = (SELECT id FROM files WHERE path = ?)
                """)
                defer { sqlite3_finalize(delete) }
                Self.bind(path, to: delete, at: 1)
                try Self.stepDone(delete, database: database)
                try Self.insertTokenSnapshots(database, snapshots: snapshots)
            }
            return true
        }
    }

    @discardableResult
    func replaceUsageRows(path: String, rows: [CostUsageStoreUsageRow]) -> Bool {
        guard rows.allSatisfy({ $0.path == path }) else { return false }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                try Self.replaceUsageRows(database, path: path, rows: rows)
            }
            return true
        }
    }

    @discardableResult
    func appendUsageRows(_ rows: [CostUsageStoreUsageRow]) -> Bool {
        guard !rows.isEmpty else { return true }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                try Self.insertUsageRows(database, rows: rows)
            }
            return true
        }
    }

    @discardableResult
    func replaceFileDayAggregates(
        path: String,
        aggregates: [CostUsageStoreDayAggregate]) -> Bool
    {
        self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                let delete = try Self.prepare(database, """
                DELETE FROM file_day_aggregates
                WHERE file_id = (SELECT id FROM files WHERE path = ?)
                """)
                defer { sqlite3_finalize(delete) }
                Self.bind(path, to: delete, at: 1)
                try Self.stepDone(delete, database: database)

                let insert = try Self.prepare(database, """
                INSERT INTO file_day_aggregates (
                    file_id, day, model, input_tokens, cached_tokens, output_tokens,
                    reasoning_tokens, request_count, authoritative_cost_nanos,
                    standard_input_tokens, standard_cached_tokens, standard_output_tokens,
                    priority_input_tokens, priority_cached_tokens, priority_output_tokens,
                    standard_tokens, priority_tokens
                ) VALUES ((SELECT id FROM files WHERE path = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
                defer { sqlite3_finalize(insert) }
                for aggregate in aggregates {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    Self.bind(path, to: insert, at: 1)
                    Self.bind(aggregate.day, to: insert, at: 2)
                    Self.bind(aggregate.model, to: insert, at: 3)
                    Self.bindAggregateValues(aggregate, to: insert, startingAt: 4)
                    try Self.stepDone(insert, database: database)
                }
            }
            return true
        }
    }

    @discardableResult
    func mergeDayAggregates(_ deltas: [CostUsageStoreDayAggregate]) -> Bool {
        guard !deltas.isEmpty else { return true }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                let statement = try Self.prepare(database, """
                INSERT INTO day_aggregates (
                    day, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens,
                    request_count, authoritative_cost_nanos,
                    standard_input_tokens, standard_cached_tokens, standard_output_tokens,
                    priority_input_tokens, priority_cached_tokens, priority_output_tokens,
                    standard_tokens, priority_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day, model) DO UPDATE SET
                    input_tokens = input_tokens + excluded.input_tokens,
                    cached_tokens = cached_tokens + excluded.cached_tokens,
                    output_tokens = output_tokens + excluded.output_tokens,
                    reasoning_tokens = reasoning_tokens + excluded.reasoning_tokens,
                    request_count = request_count + excluded.request_count,
                    authoritative_cost_nanos = authoritative_cost_nanos + excluded.authoritative_cost_nanos,
                    standard_input_tokens = standard_input_tokens + excluded.standard_input_tokens,
                    standard_cached_tokens = standard_cached_tokens + excluded.standard_cached_tokens,
                    standard_output_tokens = standard_output_tokens + excluded.standard_output_tokens,
                    priority_input_tokens = priority_input_tokens + excluded.priority_input_tokens,
                    priority_cached_tokens = priority_cached_tokens + excluded.priority_cached_tokens,
                    priority_output_tokens = priority_output_tokens + excluded.priority_output_tokens,
                    standard_tokens = standard_tokens + excluded.standard_tokens,
                    priority_tokens = priority_tokens + excluded.priority_tokens
                """)
                defer { sqlite3_finalize(statement) }
                for delta in deltas {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    Self.bind(delta.day, to: statement, at: 1)
                    Self.bind(delta.model, to: statement, at: 2)
                    Self.bindAggregateValues(delta, to: statement, startingAt: 3)
                    try Self.stepDone(statement, database: database)
                }
            }
            return true
        }
    }

    @discardableResult
    func replaceDayAggregates(_ aggregates: [CostUsageStoreDayAggregate]) -> Bool {
        self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                try Self.execute(database, "DELETE FROM day_aggregates")
                try Self.insertDayAggregates(database, aggregates: aggregates)
            }
            return true
        }
    }
}

// MARK: - Lineage, buffers, discovery, and accumulators

extension CostUsageStore {
    static func insertTokenSnapshots(
        _ database: OpaquePointer,
        snapshots: [CostUsageStoreTokenSnapshot]) throws
    {
        let statement = try self.prepare(database, """
        INSERT INTO token_snapshots (
            file_id, event_index, timestamp, timestamp_ms, day,
            last_input, last_cached, last_output, last_reasoning,
            total_input, total_cached, total_output, total_reasoning, end_offset
        ) VALUES ((SELECT id FROM files WHERE path = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_id, event_index) DO UPDATE SET
            timestamp = excluded.timestamp, timestamp_ms = excluded.timestamp_ms, day = excluded.day,
            last_input = excluded.last_input, last_cached = excluded.last_cached,
            last_output = excluded.last_output, last_reasoning = excluded.last_reasoning,
            total_input = excluded.total_input, total_cached = excluded.total_cached,
            total_output = excluded.total_output, total_reasoning = excluded.total_reasoning,
            end_offset = excluded.end_offset
        """)
        defer { sqlite3_finalize(statement) }
        for snapshot in snapshots {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            self.bind(snapshot.path, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, Int64(snapshot.eventIndex))
            self.bind(snapshot.timestamp, to: statement, at: 3)
            self.bind(snapshot.timestampUnixMs, to: statement, at: 4)
            self.bind(snapshot.day, to: statement, at: 5)
            self.bindTotals(snapshot.last, to: statement, startingAt: 6)
            self.bindTotals(snapshot.total, to: statement, startingAt: 10)
            self.bind(snapshot.endOffset, to: statement, at: 14)
            try self.stepDone(statement, database: database)
        }
    }

    static func insertDayAggregates(
        _ database: OpaquePointer,
        aggregates: [CostUsageStoreDayAggregate]) throws
    {
        let statement = try self.prepare(database, """
        INSERT INTO day_aggregates (
            day, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens,
            request_count, authoritative_cost_nanos,
            standard_input_tokens, standard_cached_tokens, standard_output_tokens,
            priority_input_tokens, priority_cached_tokens, priority_output_tokens,
            standard_tokens, priority_tokens
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        for aggregate in aggregates {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            self.bind(aggregate.day, to: statement, at: 1)
            self.bind(aggregate.model, to: statement, at: 2)
            self.bindAggregateValues(aggregate, to: statement, startingAt: 3)
            try self.stepDone(statement, database: database)
        }
    }

    @discardableResult
    func upsertForkLineage(_ lineage: CostUsageStoreForkLineage) -> Bool {
        self.withDatabase(default: false) { database in
            let statement = try Self.prepare(database, """
            INSERT INTO fork_lineage (
                file_id, session_id, forked_from_id, fork_timestamp, dependency_key,
                subagent_state, accounting_state
            ) VALUES ((SELECT id FROM files WHERE path = ?), ?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_id) DO UPDATE SET
                session_id = excluded.session_id,
                forked_from_id = excluded.forked_from_id,
                fork_timestamp = excluded.fork_timestamp,
                dependency_key = excluded.dependency_key,
                subagent_state = excluded.subagent_state,
                accounting_state = excluded.accounting_state
            """)
            defer { sqlite3_finalize(statement) }
            Self.bind(lineage.path, to: statement, at: 1)
            Self.bind(lineage.sessionID, to: statement, at: 2)
            Self.bind(lineage.forkedFromID, to: statement, at: 3)
            Self.bind(lineage.forkTimestamp, to: statement, at: 4)
            Self.bind(lineage.dependencyKey, to: statement, at: 5)
            Self.bind(lineage.subagentState, to: statement, at: 6)
            Self.bind(lineage.accountingState, to: statement, at: 7)
            try Self.stepDone(statement, database: database)
            return true
        }
    }

    @discardableResult
    func replaceBufferedLines(
        path: String,
        kind: CostUsageStoreBufferedLineKind,
        lines: [CostUsageStoreBufferedLine]) -> Bool
    {
        guard lines.allSatisfy({ $0.path == path && $0.kind == kind }) else { return false }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                let delete = try Self.prepare(database, """
                DELETE FROM buffered_lines
                WHERE file_id = (SELECT id FROM files WHERE path = ?) AND kind = ?
                """)
                Self.bind(path, to: delete, at: 1)
                Self.bind(kind.rawValue, to: delete, at: 2)
                defer { sqlite3_finalize(delete) }
                try Self.stepDone(delete, database: database)

                let insert = try Self.prepare(database, """
                INSERT INTO buffered_lines (file_id, kind, line_index, ordinal, end_offset, payload)
                VALUES ((SELECT id FROM files WHERE path = ?), ?, ?, ?, ?, ?)
                """)
                defer { sqlite3_finalize(insert) }
                for line in lines {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    Self.bind(line.path, to: insert, at: 1)
                    Self.bind(line.kind.rawValue, to: insert, at: 2)
                    sqlite3_bind_int64(insert, 3, Int64(line.lineIndex))
                    Self.bind(line.ordinal, to: insert, at: 4)
                    Self.bind(line.endOffset, to: insert, at: 5)
                    Self.bind(line.payload, to: insert, at: 6)
                    try Self.stepDone(insert, database: database)
                }
            }
            return true
        }
    }

    @discardableResult
    func setDiscoveryState(_ state: CostUsageStoreDiscoveryState?) -> Bool {
        self.setSingleton(state, table: "discovery_state")
    }

    @discardableResult
    func setLookbackState(_ state: CostUsageStoreLookbackState?) -> Bool {
        self.setSingleton(state, table: "lookback_state")
    }

    @discardableResult
    func setMetadata(_ metadata: CostUsageStoreMetadata) -> Bool {
        self.setSingleton(metadata, table: "scan_metadata")
    }

    @discardableResult
    func upsertAccumulator(_ accumulator: CostUsageStoreAccumulator) -> Bool {
        self.withDatabase(default: false) { database in
            let seen = try JSONEncoder().encode(accumulator.seenRawTotals)
            let statement = try Self.prepare(database, """
            INSERT INTO accumulators (
                file_id, event_count, next_usage_row_index,
                counted_input, counted_cached, counted_output, counted_reasoning,
                baseline_input, baseline_cached, baseline_output, baseline_reasoning,
                watermark_input, watermark_cached, watermark_output, watermark_reasoning,
                saw_divergent, saw_interleaved, seen_raw_totals, updated_at_ms
            ) VALUES ((SELECT id FROM files WHERE path = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_id) DO UPDATE SET
                event_count = excluded.event_count,
                next_usage_row_index = excluded.next_usage_row_index,
                counted_input = excluded.counted_input,
                counted_cached = excluded.counted_cached,
                counted_output = excluded.counted_output,
                counted_reasoning = excluded.counted_reasoning,
                baseline_input = excluded.baseline_input,
                baseline_cached = excluded.baseline_cached,
                baseline_output = excluded.baseline_output,
                baseline_reasoning = excluded.baseline_reasoning,
                watermark_input = excluded.watermark_input,
                watermark_cached = excluded.watermark_cached,
                watermark_output = excluded.watermark_output,
                watermark_reasoning = excluded.watermark_reasoning,
                saw_divergent = excluded.saw_divergent,
                saw_interleaved = excluded.saw_interleaved,
                seen_raw_totals = excluded.seen_raw_totals,
                updated_at_ms = excluded.updated_at_ms
            """)
            defer { sqlite3_finalize(statement) }
            Self.bind(accumulator.path, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, Int64(accumulator.eventCount))
            Self.bind(accumulator.nextUsageRowIndex, to: statement, at: 3)
            Self.bindTotals(accumulator.countedTotals, to: statement, startingAt: 4)
            Self.bindTotals(accumulator.rawTotalsBaseline, to: statement, startingAt: 8)
            Self.bindTotals(accumulator.rawTotalsWatermark, to: statement, startingAt: 12)
            sqlite3_bind_int(statement, 16, accumulator.sawDivergentTotals ? 1 : 0)
            sqlite3_bind_int(statement, 17, accumulator.sawInterleavedTotals ? 1 : 0)
            Self.bind(seen, to: statement, at: 18)
            sqlite3_bind_int64(statement, 19, accumulator.updatedAtUnixMs)
            try Self.stepDone(statement, database: database)
            return true
        }
    }

    private func setSingleton(_ value: (some Encodable)?, table: String) -> Bool {
        self.withDatabase(default: false) { database in
            if let value {
                let payload = try JSONEncoder().encode(value)
                let statement = try Self.prepare(database, """
                INSERT INTO \(table)(id, payload) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """)
                defer { sqlite3_finalize(statement) }
                Self.bind(payload, to: statement, at: 1)
                try Self.stepDone(statement, database: database)
            } else {
                try Self.execute(database, "DELETE FROM \(table) WHERE id = 1")
            }
            return true
        }
    }
}

// MARK: - Write helpers

extension CostUsageStore {
    static func replaceUsageRows(
        _ database: OpaquePointer,
        path: String,
        rows: [CostUsageStoreUsageRow]) throws
    {
        let delete = try self.prepare(database, """
        DELETE FROM usage_rows WHERE file_id = (SELECT id FROM files WHERE path = ?)
        """)
        defer { sqlite3_finalize(delete) }
        self.bind(path, to: delete, at: 1)
        try self.stepDone(delete, database: database)
        try self.insertUsageRows(database, rows: rows)
    }

    static func insertUsageRows(_ database: OpaquePointer, rows: [CostUsageStoreUsageRow]) throws {
        let statement = try self.prepare(database, """
        INSERT INTO usage_rows (file_id, row_index, payload)
        VALUES ((SELECT id FROM files WHERE path = ?), ?, ?)
        ON CONFLICT(file_id, row_index) DO UPDATE SET payload = excluded.payload
        """)
        defer { sqlite3_finalize(statement) }
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            self.bind(row.path, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, Int64(row.rowIndex))
            self.bind(row.payload, to: statement, at: 3)
            try self.stepDone(statement, database: database)
        }
    }

    static func inTransaction<T>(_ database: OpaquePointer, _ operation: () throws -> T) throws -> T {
        try self.execute(database, "BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try self.execute(database, "COMMIT")
            return value
        } catch {
            try? self.execute(database, "ROLLBACK")
            throw error
        }
    }

    static func bindTotals(
        _ totals: CostUsageStoreTotals?,
        to statement: OpaquePointer,
        startingAt index: Int32)
    {
        self.bind(totals?.input, to: statement, at: index)
        self.bind(totals?.cached, to: statement, at: index + 1)
        self.bind(totals?.output, to: statement, at: index + 2)
        self.bind(totals?.reasoning, to: statement, at: index + 3)
    }

    static func bindAggregateValues(
        _ aggregate: CostUsageStoreDayAggregate,
        to statement: OpaquePointer,
        startingAt index: Int32)
    {
        let values = [
            aggregate.inputTokens,
            aggregate.cachedTokens,
            aggregate.outputTokens,
            aggregate.reasoningTokens,
            aggregate.requestCount,
            aggregate.authoritativeCostNanos,
            aggregate.standardInputTokens,
            aggregate.standardCachedTokens,
            aggregate.standardOutputTokens,
            aggregate.priorityInputTokens,
            aggregate.priorityCachedTokens,
            aggregate.priorityOutputTokens,
            aggregate.standardTokens,
            aggregate.priorityTokens,
        ]
        for (offset, value) in values.enumerated() {
            sqlite3_bind_int64(statement, index + Int32(offset), value)
        }
    }
}
