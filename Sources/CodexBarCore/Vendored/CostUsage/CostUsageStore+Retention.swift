import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Retention

extension CostUsageStore {
    @discardableResult
    func retainDayWindow(sinceDay: String, untilDay: String) -> CostUsageStoreRetentionResult {
        guard sinceDay <= untilDay else {
            return CostUsageStoreRetentionResult(
                deletedFiles: 0,
                deletedTokenSnapshots: 0,
                deletedFileDayAggregates: 0,
                deletedDayAggregates: 0)
        }
        let fallback = CostUsageStoreRetentionResult(
            deletedFiles: 0,
            deletedTokenSnapshots: 0,
            deletedFileDayAggregates: 0,
            deletedDayAggregates: 0)
        return self.withDatabase(default: fallback) { database in
            try Self.prune(database, sinceDay: sinceDay, untilDay: untilDay)
        }
    }

    @discardableResult
    func deleteFile(path: String) -> Bool {
        self.withDatabase(default: false) { database in
            let statement = try Self.prepare(database, "DELETE FROM files WHERE path = ?")
            defer { sqlite3_finalize(statement) }
            Self.bind(path, to: statement, at: 1)
            try Self.stepDone(statement, database: database)
            return sqlite3_changes(database) > 0
        }
    }

    private static func prune(
        _ database: OpaquePointer,
        sinceDay: String,
        untilDay: String) throws -> CostUsageStoreRetentionResult
    {
        try self.inTransaction(database) {
            let beforeFiles = try self.scalarInt(database, "SELECT COUNT(*) FROM files")
            let beforeSnapshots = try self.scalarInt(database, "SELECT COUNT(*) FROM token_snapshots")
            let beforeFileAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM file_day_aggregates")
            let beforeAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM day_aggregates")

            let candidates = try self.retentionCandidates(
                database,
                sinceDay: sinceDay,
                untilDay: untilDay)
            let deleteFile = try self.prepare(database, "DELETE FROM files WHERE path = ?")
            defer { sqlite3_finalize(deleteFile) }
            for candidate in candidates {
                sqlite3_reset(deleteFile)
                sqlite3_clear_bindings(deleteFile)
                self.bind(candidate.path, to: deleteFile, at: 1)
                try self.stepDone(deleteFile, database: database)
            }

            let deleteSnapshots = try self.prepare(database, """
            DELETE FROM token_snapshots WHERE day IS NOT NULL AND (day < ? OR day > ?)
            """)
            defer { sqlite3_finalize(deleteSnapshots) }
            self.bind(sinceDay, to: deleteSnapshots, at: 1)
            self.bind(untilDay, to: deleteSnapshots, at: 2)
            try self.stepDone(deleteSnapshots, database: database)

            let deleteFileAggregates = try self.prepare(
                database,
                "DELETE FROM file_day_aggregates WHERE day < ? OR day > ?")
            defer { sqlite3_finalize(deleteFileAggregates) }
            self.bind(sinceDay, to: deleteFileAggregates, at: 1)
            self.bind(untilDay, to: deleteFileAggregates, at: 2)
            try self.stepDone(deleteFileAggregates, database: database)

            let deleteAggregates = try self.prepare(
                database,
                "DELETE FROM day_aggregates WHERE day < ? OR day > ?")
            defer { sqlite3_finalize(deleteAggregates) }
            self.bind(sinceDay, to: deleteAggregates, at: 1)
            self.bind(untilDay, to: deleteAggregates, at: 2)
            try self.stepDone(deleteAggregates, database: database)

            try self.pruneDiscovery(database, candidates: candidates)
            var metadata = try self.readSingleton(
                CostUsageStoreMetadata.self,
                database: database,
                table: "scan_metadata") ?? .empty
            metadata.scanSinceDay = sinceDay
            metadata.scanUntilDay = untilDay
            try self.writeSingleton(metadata, database: database, table: "scan_metadata")

            let afterFiles = try self.scalarInt(database, "SELECT COUNT(*) FROM files")
            let afterSnapshots = try self.scalarInt(database, "SELECT COUNT(*) FROM token_snapshots")
            let afterFileAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM file_day_aggregates")
            let afterAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM day_aggregates")
            return CostUsageStoreRetentionResult(
                deletedFiles: Int(beforeFiles - afterFiles),
                deletedTokenSnapshots: Int(beforeSnapshots - afterSnapshots),
                deletedFileDayAggregates: Int(beforeFileAggregates - afterFileAggregates),
                deletedDayAggregates: Int(beforeAggregates - afterAggregates))
        }
    }

    private struct RetentionCandidate {
        var path: String
        var sessionID: String?
    }

    private static func retentionCandidates(
        _ database: OpaquePointer,
        sinceDay: String,
        untilDay: String) throws -> [RetentionCandidate]
    {
        let statement = try self.prepare(database, """
        SELECT f.path, f.session_id
        FROM files f
        WHERE f.scan_complete = 1
          AND f.coverage_since_day IS NOT NULL
          AND f.coverage_until_day IS NOT NULL
          AND (f.coverage_until_day < ? OR f.coverage_since_day > ?)
          AND NOT EXISTS (SELECT 1 FROM buffered_lines b WHERE b.file_id = f.id)
          AND (
              f.session_id IS NULL OR NOT EXISTS (
                  SELECT 1 FROM fork_lineage l
                  WHERE l.forked_from_id = f.session_id AND l.file_id != f.id
              )
          )
        ORDER BY f.updated_at_ms, f.path
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(sinceDay, to: statement, at: 1)
        self.bind(untilDay, to: statement, at: 2)
        var values: [RetentionCandidate] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0) else { throw StoreError.invalidData }
            values.append(RetentionCandidate(path: path, sessionID: self.columnText(statement, at: 1)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }

    private static func pruneDiscovery(
        _ database: OpaquePointer,
        candidates: [RetentionCandidate]) throws
    {
        guard !candidates.isEmpty,
              var state = try self.readSingleton(
                  CostUsageStoreDiscoveryState.self,
                  database: database,
                  table: "discovery_state")
        else { return }
        let paths = Set(candidates.map(\.path))
        let sessionIDs = Set(candidates.compactMap(\.sessionID))
        state.filePaths.removeAll(where: paths.contains)
        state.pendingSessionIDs.removeAll(where: sessionIDs.contains)
        state.missingSessionIDs.removeAll(where: sessionIDs.contains)
        state.filePathBySessionID = state.filePathBySessionID.filter {
            !sessionIDs.contains($0.key) && !paths.contains($0.value)
        }
        state.nextFileIndex = min(state.nextFileIndex, state.filePaths.count)
        try self.writeSingleton(state, database: database, table: "discovery_state")
    }
}

// MARK: - Budgets and vacuum

extension CostUsageStore {
    func enforceBudgets(maxRows: Int, maxFileBytes: Int64) -> CostUsageStoreBudgetResult {
        let fallback = CostUsageStoreBudgetResult(deletedRows: 0, rowCount: 0, fileBytes: 0)
        return self.withDatabase(default: fallback) { database in
            let initialRows = try Self.rowCount(database)
            if let metadata = try Self.readSingleton(
                CostUsageStoreMetadata.self,
                database: database,
                table: "scan_metadata"),
                let sinceDay = metadata.scanSinceDay,
                let untilDay = metadata.scanUntilDay,
                sinceDay <= untilDay
            {
                _ = try Self.prune(database, sinceDay: sinceDay, untilDay: untilDay)
            }

            let rowLimit = max(0, maxRows)
            while try Self.rowCount(database) > Int64(rowLimit) {
                guard try Self.deleteOldestRetainedRow(database) else { break }
            }
            try Self.reclaimFreePages(database)

            let byteLimit = max(0, maxFileBytes)
            var fileBytes = Self.fileSize(at: self.databaseURL)
            while fileBytes > byteLimit {
                guard try Self.deleteOldestRetainedRow(database) else { break }
                try Self.reclaimFreePages(database)
                fileBytes = Self.fileSize(at: self.databaseURL)
            }
            let finalRows = try Self.rowCount(database)
            return CostUsageStoreBudgetResult(
                deletedRows: Int(max(0, initialRows - finalRows)),
                rowCount: Int(finalRows),
                fileBytes: fileBytes)
        }
    }

    func fileSizeBytes() -> Int64 {
        self.withDatabase(default: 0) { database in
            try Self.reclaimFreePages(database)
            return Self.fileSize(at: self.databaseURL)
        }
    }

    private static func deleteOldestRetainedRow(_ database: OpaquePointer) throws -> Bool {
        let statements = [
            "DELETE FROM files WHERE id = (SELECT id FROM files ORDER BY updated_at_ms, id LIMIT 1)",
            """
            DELETE FROM day_aggregates WHERE rowid = (
                SELECT rowid FROM day_aggregates ORDER BY day, model LIMIT 1
            )
            """,
        ]
        for sql in statements {
            try self.execute(database, sql)
            if sqlite3_changes(database) > 0 {
                return true
            }
        }
        return false
    }

    private static func rowCount(_ database: OpaquePointer) throws -> Int64 {
        try self.scalarInt(database, """
        SELECT
            (SELECT COUNT(*) FROM files) +
            (SELECT COUNT(*) FROM token_snapshots) +
            (SELECT COUNT(*) FROM file_day_aggregates) +
            (SELECT COUNT(*) FROM day_aggregates) +
            (SELECT COUNT(*) FROM fork_lineage) +
            (SELECT COUNT(*) FROM buffered_lines) +
            (SELECT COUNT(*) FROM accumulators)
        """)
    }

    private static func reclaimFreePages(_ database: OpaquePointer) throws {
        try self.execute(database, "PRAGMA incremental_vacuum(1000000)")
        try self.execute(database, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Singleton write helper

extension CostUsageStore {
    private static func writeSingleton(
        _ value: some Encodable,
        database: OpaquePointer,
        table: String) throws
    {
        let payload = try JSONEncoder().encode(value)
        let statement = try self.prepare(database, """
        INSERT INTO \(table)(id, payload) VALUES (1, ?)
        ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(payload, to: statement, at: 1)
        try self.stepDone(statement, database: database)
    }
}
