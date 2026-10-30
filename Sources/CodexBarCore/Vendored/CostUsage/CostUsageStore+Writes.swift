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
            try Self.upsertFileIn(database, file: file, home: self.home)
            return true
        }
    }

    /// The `upsertFile` statement against an open database, for use inside an enclosing
    /// transaction (the adapter's atomic pass). Throws on bind/step failures.
    static func upsertFileIn(
        _ database: OpaquePointer,
        file: CostUsageStoreFile,
        home: String) throws
    {
        let state = try JSONEncoder().encode(file.scanState)
        let statement = try Self.prepare(database, """
        INSERT INTO files (
            path, inode, mtime_ms, size, parsed_bytes, anchor_indexed_bytes,
            anchor_window_start, anchor_sha256, scan_state, scan_target_size,
            scan_complete, session_id, coverage_since_day, coverage_until_day, updated_at_ms, home
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        WHERE files.home = excluded.home
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
        Self.bind(home, to: statement, at: 16)
        try Self.stepDone(statement, database: database)
        guard sqlite3_changes(database) > 0 else { throw StoreError.sqlite(SQLITE_CONSTRAINT) }
    }

    @discardableResult
    func appendTokenSnapshots(_ snapshots: [CostUsageStoreTokenSnapshot]) -> Bool {
        guard !snapshots.isEmpty else { return true }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                try Self.insertTokenSnapshots(database, snapshots: snapshots, home: self.home)
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
                DELETE FROM token_snapshots WHERE file_id = (SELECT id FROM files WHERE path = ? AND home = ?)
                """)
                defer { sqlite3_finalize(delete) }
                Self.bind(path, to: delete, at: 1)
                Self.bind(self.home, to: delete, at: 2)
                try Self.stepDone(delete, database: database)
                try Self.insertTokenSnapshots(database, snapshots: snapshots, home: self.home)
            }
            return true
        }
    }

    @discardableResult
    func replaceUsageRows(path: String, rows: [CostUsageStoreUsageRow]) -> Bool {
        guard rows.allSatisfy({ $0.path == path }) else { return false }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                try Self.replaceUsageRows(database, path: path, rows: rows, home: self.home)
            }
            return true
        }
    }

    @discardableResult
    func appendUsageRows(_ rows: [CostUsageStoreUsageRow]) -> Bool {
        guard !rows.isEmpty else { return true }
        return self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                try Self.insertUsageRows(database, rows: rows, home: self.home)
            }
            return true
        }
    }

    static func insertFileDayAggregates(
        _ database: OpaquePointer,
        path: String,
        aggregates: [CostUsageStoreDayAggregate]) throws
    {
        let insert = try Self.prepare(database, """
        INSERT INTO file_day_aggregates (
            file_id, day, model, input_tokens, cached_tokens, output_tokens,
            reasoning_tokens, request_count, authoritative_cost_nanos,
            standard_input_tokens, standard_cached_tokens, standard_output_tokens,
            priority_input_tokens, priority_cached_tokens, priority_output_tokens,
            standard_tokens, priority_tokens
        ) VALUES ((SELECT id FROM files WHERE path = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_id, day, model) DO UPDATE SET
            input_tokens = excluded.input_tokens,
            cached_tokens = excluded.cached_tokens,
            output_tokens = excluded.output_tokens,
            reasoning_tokens = excluded.reasoning_tokens,
            request_count = excluded.request_count,
            authoritative_cost_nanos = excluded.authoritative_cost_nanos,
            standard_input_tokens = excluded.standard_input_tokens,
            standard_cached_tokens = excluded.standard_cached_tokens,
            standard_output_tokens = excluded.standard_output_tokens,
            priority_input_tokens = excluded.priority_input_tokens,
            priority_cached_tokens = excluded.priority_cached_tokens,
            priority_output_tokens = excluded.priority_output_tokens,
            standard_tokens = excluded.standard_tokens,
            priority_tokens = excluded.priority_tokens
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

    /// Checkpoint and contribution replacements share the store's transaction and baseline.
    func applyOpenCodeLocalHistoryPass(
        file: CostUsageStoreFile,
        expectedBaselineResumePayload: Data?,
        turns: [Int64: OpenCodeLocalHistoryAdapter.Turn],
        deletions: Set<Int64>) -> Bool
    {
        guard file.belongsToOpenCodeLocalHistory else { return false }
        struct StaleBaseline: Error {}
        return self.withDatabase(default: false) { database in
            do {
                try Self.inTransaction(database) {
                    try Task.checkCancellation()
                    let stored = try Self.readFile(database, path: file.path)
                    guard stored?.scanState.resumePayload == expectedBaselineResumePayload,
                          stored == nil || stored?.belongsToOpenCodeLocalHistory == true
                    else { throw StaleBaseline() }
                    let identities = Set(turns.keys).union(deletions)
                    let previous = try Self.readUsagePayloads(database, path: file.path, rowIndices: Array(identities))
                    var rows: [CostUsageStoreUsageRow] = []
                    var removed: [Int64] = []
                    var deltas: [CostUsageStoreDayAggregate] = []
                    for identity in identities {
                        try Task.checkCancellation()
                        let old = previous[identity].flatMap {
                            try? JSONDecoder().decode(OpenCodeLocalHistoryAdapter.Turn.self, from: $0)
                        }
                        let new = deletions.contains(identity) ? nil : turns[identity]
                        guard old != new else { continue }
                        if let old { deltas.append(Self.negatedAggregate(old.aggregate)) }
                        if let new {
                            deltas.append(new.aggregate)
                            let payload = try JSONEncoder().encode(new)
                            guard payload.count <= OpenCodeLocalHistoryAdapter.maximumMetadataBytes else {
                                throw StoreError.invalidData
                            }
                            rows.append(.init(path: file.path, rowIndex: Int(identity), payload: payload))
                        } else {
                            removed.append(identity)
                        }
                    }
                    try Self.upsertFileIn(database, file: file, home: self.home)
                    try Self.deleteUsageRowsByIndices(database, path: file.path, rowIndices: removed)
                    try Self.insertUsageRows(database, rows: rows, home: self.home)
                    try Self.mergeDayAggregatesIn(database, deltas: deltas, path: file.path, home: self.home)
                    try Self.mergeDayAggregatesIn(database, deltas: deltas, home: self.home)
                }
                return true
            } catch is StaleBaseline {
                return false
            } catch is CancellationError {
                return false
            }
        }
    }

    static func negatedAggregate(
        _ aggregate: CostUsageStoreDayAggregate) -> CostUsageStoreDayAggregate
    {
        CostUsageStoreDayAggregate(
            day: aggregate.day,
            model: aggregate.model,
            inputTokens: -aggregate.inputTokens,
            cachedTokens: -aggregate.cachedTokens,
            outputTokens: -aggregate.outputTokens,
            reasoningTokens: -aggregate.reasoningTokens,
            requestCount: -aggregate.requestCount,
            authoritativeCostNanos: -aggregate.authoritativeCostNanos,
            standardInputTokens: -aggregate.standardInputTokens,
            standardCachedTokens: -aggregate.standardCachedTokens,
            standardOutputTokens: -aggregate.standardOutputTokens,
            priorityInputTokens: -aggregate.priorityInputTokens,
            priorityCachedTokens: -aggregate.priorityCachedTokens,
            priorityOutputTokens: -aggregate.priorityOutputTokens,
            standardTokens: -aggregate.standardTokens,
            priorityTokens: -aggregate.priorityTokens)
    }

    static func deleteUsageRowsByIndices(
        _ database: OpaquePointer,
        path: String,
        rowIndices: [Int64]) throws
    {
        guard !rowIndices.isEmpty else { return }
        let placeholders = rowIndices.map { _ in "?" }.joined(separator: ",")
        let statement = try Self.prepare(database, """
        DELETE FROM usage_rows
        WHERE file_id = (SELECT id FROM files WHERE path = ?) AND row_index IN (\(placeholders))
        """)
        defer { sqlite3_finalize(statement) }
        Self.bind(path, to: statement, at: 1)
        for (index, value) in rowIndices.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 2), Int64(value))
        }
        try Self.stepDone(statement, database: database)
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
                WHERE file_id = (SELECT id FROM files WHERE path = ? AND home = ?)
                """)
                defer { sqlite3_finalize(delete) }
                Self.bind(path, to: delete, at: 1)
                Self.bind(self.home, to: delete, at: 2)
                try Self.stepDone(delete, database: database)

                let insert = try Self.prepare(database, """
                INSERT INTO file_day_aggregates (
                    file_id, day, model, input_tokens, cached_tokens, output_tokens,
                    reasoning_tokens, request_count, authoritative_cost_nanos,
                    standard_input_tokens, standard_cached_tokens, standard_output_tokens,
                    priority_input_tokens, priority_cached_tokens, priority_output_tokens,
                    standard_tokens, priority_tokens
                ) VALUES ((SELECT id FROM files WHERE path = ? AND home = ?),
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
                defer { sqlite3_finalize(insert) }
                for aggregate in aggregates {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    Self.bind(path, to: insert, at: 1)
                    Self.bind(self.home, to: insert, at: 2)
                    Self.bind(aggregate.day, to: insert, at: 3)
                    Self.bind(aggregate.model, to: insert, at: 4)
                    Self.bindAggregateValues(aggregate, to: insert, startingAt: 5)
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
                try Self.mergeDayAggregatesIn(database, deltas: deltas, home: self.home)
            }
            return true
        }
    }

    static func mergeDayAggregatesIn(
        _ database: OpaquePointer,
        deltas: [CostUsageStoreDayAggregate],
        path: String? = nil,
        home: String) throws
    {
        guard !deltas.isEmpty else { return }
        let columns = [
            "input_tokens", "cached_tokens", "output_tokens", "reasoning_tokens", "request_count",
            "authoritative_cost_nanos", "standard_input_tokens", "standard_cached_tokens", "standard_output_tokens",
            "priority_input_tokens", "priority_cached_tokens", "priority_output_tokens", "standard_tokens",
            "priority_tokens",
        ]
        let table = path == nil ? "day_aggregates" : "file_day_aggregates"
        let keys = (path == nil ? ["home"] : ["file_id"]) + ["day", "model"]
        let values = (path == nil ? ["?"] : ["(SELECT id FROM files WHERE path = ? AND home = ?)"])
            + Array(repeating: "?", count: 2 + columns.count)
        let updates = columns.map { "\($0) = \($0) + excluded.\($0)" }.joined(separator: ", ")
        let statement = try Self.prepare(database, """
        INSERT INTO \(table) (\((keys + columns).joined(separator: ", ")))
        VALUES (\(values.joined(separator: ", ")))
        ON CONFLICT(\(keys.joined(separator: ", "))) DO UPDATE SET \(updates)
        """)
        defer { sqlite3_finalize(statement) }
        let filePredicate = path == nil
            ? "home = ? AND "
            : "file_id = (SELECT id FROM files WHERE path = ? AND home = ?) AND "
        let removeEmpty = try Self.prepare(database, """
        DELETE FROM \(table) WHERE \(filePredicate)day = ? AND model = ?
        AND \(columns.map { "\($0) = 0" }.joined(separator: " AND "))
        """)
        defer { sqlite3_finalize(removeEmpty) }
        for delta in deltas {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_reset(removeEmpty)
            sqlite3_clear_bindings(removeEmpty)
            let start: Int32 = path == nil ? 2 : 3
            for target in [statement, removeEmpty] {
                if let path { Self.bind(path, to: target, at: 1) }
                Self.bind(home, to: target, at: path == nil ? 1 : 2)
                Self.bind(delta.day, to: target, at: start)
                Self.bind(delta.model, to: target, at: start + 1)
            }
            Self.bindAggregateValues(delta, to: statement, startingAt: start + 2)
            try Self.stepDone(statement, database: database)
            try Self.stepDone(removeEmpty, database: database)
        }
    }

    @discardableResult
    func replaceDayAggregates(_ aggregates: [CostUsageStoreDayAggregate]) -> Bool {
        self.withDatabase(default: false) { database in
            try Self.inTransaction(database) {
                try Self.deleteHomeRows(database, table: "day_aggregates", home: self.home)
                try Self.insertDayAggregates(database, aggregates: aggregates, home: self.home)
            }
            return true
        }
    }
}

// MARK: - Lineage, buffers, discovery, and accumulators

extension CostUsageStore {
    static func insertTokenSnapshots(
        _ database: OpaquePointer,
        snapshots: [CostUsageStoreTokenSnapshot],
        home: String) throws
    {
        let statement = try self.prepare(database, """
        INSERT INTO token_snapshots (
            file_id, event_index, timestamp, timestamp_ms, day,
            last_input, last_cached, last_output, last_reasoning,
            total_input, total_cached, total_output, total_reasoning, end_offset
        ) VALUES ((SELECT id FROM files WHERE path = ? AND home = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            self.bind(home, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, Int64(snapshot.eventIndex))
            self.bind(snapshot.timestamp, to: statement, at: 4)
            self.bind(snapshot.timestampUnixMs, to: statement, at: 5)
            self.bind(snapshot.day, to: statement, at: 6)
            self.bindTotals(snapshot.last, to: statement, startingAt: 7)
            self.bindTotals(snapshot.total, to: statement, startingAt: 11)
            self.bind(snapshot.endOffset, to: statement, at: 15)
            try self.stepDone(statement, database: database)
        }
    }

    static func insertDayAggregates(
        _ database: OpaquePointer,
        aggregates: [CostUsageStoreDayAggregate],
        home: String) throws
    {
        let statement = try self.prepare(database, """
        INSERT INTO day_aggregates (
            day, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens,
            request_count, authoritative_cost_nanos,
            standard_input_tokens, standard_cached_tokens, standard_output_tokens,
            priority_input_tokens, priority_cached_tokens, priority_output_tokens,
            standard_tokens, priority_tokens, home
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        for aggregate in aggregates {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            self.bind(aggregate.day, to: statement, at: 1)
            self.bind(aggregate.model, to: statement, at: 2)
            self.bindAggregateValues(aggregate, to: statement, startingAt: 3)
            self.bind(home, to: statement, at: 17)
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
            ) VALUES ((SELECT id FROM files WHERE path = ? AND home = ?), ?, ?, ?, ?, ?, ?)
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
            Self.bind(self.home, to: statement, at: 2)
            Self.bind(lineage.sessionID, to: statement, at: 3)
            Self.bind(lineage.forkedFromID, to: statement, at: 4)
            Self.bind(lineage.forkTimestamp, to: statement, at: 5)
            Self.bind(lineage.dependencyKey, to: statement, at: 6)
            Self.bind(lineage.subagentState, to: statement, at: 7)
            Self.bind(lineage.accountingState, to: statement, at: 8)
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
                WHERE file_id = (SELECT id FROM files WHERE path = ? AND home = ?) AND kind = ?
                """)
                Self.bind(path, to: delete, at: 1)
                Self.bind(self.home, to: delete, at: 2)
                Self.bind(kind.rawValue, to: delete, at: 3)
                defer { sqlite3_finalize(delete) }
                try Self.stepDone(delete, database: database)

                let insert = try Self.prepare(database, """
                INSERT INTO buffered_lines (file_id, kind, line_index, ordinal, end_offset, payload)
                VALUES ((SELECT id FROM files WHERE path = ? AND home = ?), ?, ?, ?, ?, ?)
                """)
                defer { sqlite3_finalize(insert) }
                for line in lines {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    Self.bind(line.path, to: insert, at: 1)
                    Self.bind(self.home, to: insert, at: 2)
                    Self.bind(line.kind.rawValue, to: insert, at: 3)
                    sqlite3_bind_int64(insert, 4, Int64(line.lineIndex))
                    Self.bind(line.ordinal, to: insert, at: 5)
                    Self.bind(line.endOffset, to: insert, at: 6)
                    Self.bind(line.payload, to: insert, at: 7)
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
            ) VALUES ((SELECT id FROM files WHERE path = ? AND home = ?),
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            Self.bind(self.home, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, Int64(accumulator.eventCount))
            Self.bind(accumulator.nextUsageRowIndex, to: statement, at: 4)
            Self.bindTotals(accumulator.countedTotals, to: statement, startingAt: 5)
            Self.bindTotals(accumulator.rawTotalsBaseline, to: statement, startingAt: 9)
            Self.bindTotals(accumulator.rawTotalsWatermark, to: statement, startingAt: 13)
            sqlite3_bind_int(statement, 17, accumulator.sawDivergentTotals ? 1 : 0)
            sqlite3_bind_int(statement, 18, accumulator.sawInterleavedTotals ? 1 : 0)
            Self.bind(seen, to: statement, at: 19)
            sqlite3_bind_int64(statement, 20, accumulator.updatedAtUnixMs)
            try Self.stepDone(statement, database: database)
            return true
        }
    }

    private func setSingleton(_ value: (some Encodable)?, table: String) -> Bool {
        self.withDatabase(default: false) { database in
            if let value {
                try Self.writeSingleton(value, database: database, table: table, home: self.home)
            } else {
                try Self.deleteHomeRows(database, table: table, home: self.home)
            }
            return true
        }
    }
}

// MARK: - Write helpers

enum CostUsagePersistenceAction: Equatable {
    case reuse
    case append(startingAt: Int)
    case replace

    func materialize<Source, Persisted>(
        _ source: [Source],
        transform: (Int, Source) -> Persisted?) -> [Persisted]
    {
        let start: Int
        switch self {
        case .reuse:
            return []
        case let .append(startingAt):
            start = startingAt
        case .replace:
            start = 0
        }
        return source.enumerated().dropFirst(start).compactMap { transform($0.offset, $0.element) }
    }
}

enum CostUsagePersistencePlanner {
    static func action<Element: Equatable>(
        canReuse: Bool,
        appendSafe: Bool,
        persistedCount: Int,
        baseline: [Element],
        source: [Element]) -> CostUsagePersistenceAction
    {
        guard canReuse, baseline.count == persistedCount else { return .replace }
        if baseline == source {
            return .reuse
        }
        if appendSafe, source.starts(with: baseline) {
            return .append(startingAt: persistedCount)
        }
        return .replace
    }
}

extension CostUsageStore {
    static func replaceUsageRows(
        _ database: OpaquePointer,
        path: String,
        rows: [CostUsageStoreUsageRow],
        home: String) throws
    {
        let delete = try self.prepare(database, """
        DELETE FROM usage_rows WHERE file_id = (SELECT id FROM files WHERE path = ? AND home = ?)
        """)
        defer { sqlite3_finalize(delete) }
        self.bind(path, to: delete, at: 1)
        self.bind(home, to: delete, at: 2)
        try self.stepDone(delete, database: database)
        try self.insertUsageRows(database, rows: rows, home: home)
    }

    static func insertUsageRows(_ database: OpaquePointer, rows: [CostUsageStoreUsageRow], home: String) throws {
        let statement = try self.prepare(database, """
        INSERT INTO usage_rows (file_id, row_index, payload)
        VALUES ((SELECT id FROM files WHERE path = ? AND home = ?), ?, ?)
        ON CONFLICT(file_id, row_index) DO UPDATE SET payload = excluded.payload
        """)
        defer { sqlite3_finalize(statement) }
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            self.bind(row.path, to: statement, at: 1)
            self.bind(home, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, Int64(row.rowIndex))
            self.bind(row.payload, to: statement, at: 4)
            try self.stepDone(statement, database: database)
        }
    }

    static func deleteHomeRows(_ database: OpaquePointer, table: String, home: String) throws {
        let statement = try self.prepare(database, "DELETE FROM \(table) WHERE home = ?")
        defer { sqlite3_finalize(statement) }
        self.bind(home, to: statement, at: 1)
        try self.stepDone(statement, database: database)
    }

    static func inTransaction<T>(_ database: OpaquePointer, _ operation: () throws -> T) throws -> T {
        // Flatten when a transaction is already open (the save cycle's outer BEGIN
        // IMMEDIATE): SQLite has no nested transactions, and the outer scope owns
        // commit/rollback for every write made inside it.
        guard sqlite3_get_autocommit(database) != 0 else {
            return try operation()
        }
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
