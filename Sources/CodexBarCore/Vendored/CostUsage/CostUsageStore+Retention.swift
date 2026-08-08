import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Retention

extension CostUsageStore {
    @discardableResult
    func retainDayWindow(
        sinceDay: String,
        untilDay: String,
        calendar: Calendar = .current) -> CostUsageStoreRetentionResult
    {
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
            try Self.prune(database, sinceDay: sinceDay, untilDay: untilDay, calendar: calendar)
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
        untilDay: String,
        calendar: Calendar) throws -> CostUsageStoreRetentionResult
    {
        try self.inTransaction(database) {
            let beforeFiles = try self.scalarInt(database, "SELECT COUNT(*) FROM files")
            let beforeSnapshots = try self.scalarInt(database, "SELECT COUNT(*) FROM token_snapshots")
            let beforeFileAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM file_day_aggregates")
            let beforeAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM day_aggregates")

            let activeWindow = self.activeWindowMs(sinceDay: sinceDay, untilDay: untilDay, calendar: calendar)
            let deleteFile = try self.prepare(database, "DELETE FROM files WHERE path = ?")
            defer { sqlite3_finalize(deleteFile) }
            var candidates: [RetentionCandidate] = []
            // Iterate to a fixpoint: deleting a stale child releases the fork protection on
            // its stale parent, which must then be pruned in the same pass instead of
            // lingering as an unreferenced out-of-window row.
            while true {
                let round = try self.retentionCandidates(
                    database,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    activeWindow: activeWindow)
                guard !round.isEmpty else { break }
                for candidate in round {
                    sqlite3_reset(deleteFile)
                    sqlite3_clear_bindings(deleteFile)
                    self.bind(candidate.path, to: deleteFile, at: 1)
                    try self.stepDone(deleteFile, database: database)
                }
                candidates += round
            }

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

    /// Milliseconds spanned by the scan window's local days; a session file whose mtime
    /// falls inside it is still active (it may hold unscanned in-window rows) even when its
    /// scanned coverage is entirely out of window, so retention must not drop it.
    static func activeWindowMs(
        sinceDay: String?,
        untilDay: String?,
        calendar: Calendar) -> Range<Int64>?
    {
        guard let sinceDay, let untilDay,
              let since = CostUsageScanner.parseDayKey(sinceDay, calendar: calendar),
              let until = CostUsageScanner.parseDayKey(untilDay, calendar: calendar)
        else { return nil }
        let scanCalendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        let end = scanCalendar.date(byAdding: .day, value: 1, to: until) ?? until
        let lower = Int64(since.timeIntervalSince1970 * 1000)
        let upper = Int64(end.timeIntervalSince1970 * 1000)
        guard lower < upper else { return nil }
        return lower..<upper
    }

    private static func retentionCandidates(
        _ database: OpaquePointer,
        sinceDay: String,
        untilDay: String,
        activeWindow: Range<Int64>?) throws -> [RetentionCandidate]
    {
        // Fork parents stay protected only while a surviving child still needs the parent's
        // baseline; lineage-only children (dependency key "not required") never resolve
        // inherited totals, so they do not keep a stale parent alive.
        let statement = try self.prepare(database, """
        SELECT f.path, f.session_id, f.mtime_ms
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
                    AND (l.dependency_key IS NULL OR l.dependency_key != ?)
              )
          )
        ORDER BY f.updated_at_ms, f.path
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(sinceDay, to: statement, at: 1)
        self.bind(untilDay, to: statement, at: 2)
        self.bind(CostUsageScanner.codexForkDependencyNotRequiredKey, to: statement, at: 3)
        var values: [RetentionCandidate] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0) else { throw StoreError.invalidData }
            let mtime = sqlite3_column_int64(statement, 2)
            if activeWindow?.contains(mtime) != true {
                values.append(RetentionCandidate(path: path, sessionID: self.columnText(statement, at: 1)))
            }
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
        // Cursors may point past the shortened arrays, and pruned coverage is no longer
        // complete; reset both so the next discovery pass re-enqueues remaining files
        // instead of trusting stale coverage.
        state.nextFileIndex = 0
        state.nextDirectoryIndex = 0
        state.validationDirectoryIndex = 0
        state.isComplete = false
        // The scanner round-trips discovery through the opaque payload, so the payload must
        // be pruned in lockstep with the typed columns or the deleted files resurface on the
        // next load.
        if let payload = state.payload,
           var discovery = try? JSONDecoder().decode(CostUsageCodexSessionDiscovery.self, from: payload)
        {
            discovery.filePaths.removeAll { paths.contains($0) }
            discovery.fileStamps = discovery.fileStamps.filter { !paths.contains($0.key) }
            discovery.filePathBySessionId = discovery.filePathBySessionId.filter {
                !sessionIDs.contains($0.key) && !paths.contains($0.value)
            }
            discovery.missingSessionIds.removeAll { sessionIDs.contains($0) }
            discovery.pendingSessionIds.removeAll { sessionIDs.contains($0) }
            if let head = discovery.headScan, paths.contains(head.path) {
                discovery.headScan = nil
            }
            discovery.nextFileIndex = 0
            discovery.nextDirectoryIndex = 0
            discovery.validationDirectoryIndex = 0
            discovery.isComplete = false
            state.payload = (try? JSONEncoder().encode(discovery)) ?? state.payload
        }
        try self.writeSingleton(state, database: database, table: "discovery_state")
    }
}

// MARK: - Budgets and vacuum

extension CostUsageStore {
    /// The row budget is the SQLite equivalent of the former 25k cache-entry cap: one
    /// retained session file is one entry. Dependent token and usage rows are bounded by
    /// the independent 256 MiB database cap, so active append/fork state is not discarded
    /// merely because a single session contains many events.
    func enforceBudgets(
        maxRows: Int,
        maxFileBytes: Int64,
        requestedSinceDay: String? = nil,
        requestedUntilDay: String? = nil,
        calendar: Calendar = .current) -> CostUsageStoreBudgetResult
    {
        let fallback = CostUsageStoreBudgetResult(deletedRows: 0, rowCount: 0, fileBytes: 0)
        return self.withDatabase(default: fallback) { database in
            let initialRows = try Self.rowCount(database)
            let initialBytes = Self.fileSize(at: self.databaseURL)
            let metadata = try Self.readSingleton(
                CostUsageStoreMetadata.self,
                database: database,
                table: "scan_metadata")
            let sinceDay = requestedSinceDay ?? metadata?.scanSinceDay
            let untilDay = requestedUntilDay ?? metadata?.scanUntilDay
            let rowLimit = max(0, maxRows)
            let byteLimit = max(0, maxFileBytes)
            if initialRows > Int64(rowLimit) || initialBytes > byteLimit,
               let sinceDay, let untilDay, sinceDay <= untilDay
            {
                _ = try Self.prune(database, sinceDay: sinceDay, untilDay: untilDay, calendar: calendar)
            }

            var catchUpRequired = false
            // The row budget mirrors the former entry budget: it only ever removes files the
            // requested window does not read. In-window and recently active files are never
            // dropped just for a row overage; the byte budget below is the sole authority
            // that may sacrifice in-window data.
            while try Self.rowCount(database) > Int64(rowLimit) {
                guard try Self.deleteOldestRetainedFile(
                    database,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    calendar: calendar,
                    protectRequestedWindow: true) else { break }
                catchUpRequired = true
            }
            try Self.reclaimFreePages(database)

            var fileBytes = Self.fileSize(at: self.databaseURL)
            while fileBytes > byteLimit {
                guard try Self.deleteOldestRetainedFile(
                    database,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    calendar: calendar,
                    protectRequestedWindow: false)
                else {
                    guard try Self.stripOldestRebuildableDetail(database) else { break }
                    catchUpRequired = true
                    try Self.markCatchUpRequired(database)
                    try Self.reclaimFreePages(database)
                    fileBytes = Self.fileSize(at: self.databaseURL)
                    continue
                }
                catchUpRequired = true
                try Self.reclaimFreePages(database)
                fileBytes = Self.fileSize(at: self.databaseURL)
            }
            if catchUpRequired {
                try Self.rebuildDayAggregates(database)
                try Self.markCatchUpRequired(database)
            }
            let finalRows = try Self.rowCount(database)
            return CostUsageStoreBudgetResult(
                deletedRows: Int(max(0, initialRows - finalRows)),
                rowCount: Int(finalRows),
                fileBytes: fileBytes,
                catchUpRequired: catchUpRequired)
        }
    }

    func fileSizeBytes() -> Int64 {
        self.withDatabase(default: 0) { database in
            try Self.reclaimFreePages(database)
            return Self.fileSize(at: self.databaseURL)
        }
    }

    private static func deleteOldestRetainedFile(
        _ database: OpaquePointer,
        sinceDay: String?,
        untilDay: String?,
        calendar: Calendar,
        protectRequestedWindow: Bool) throws -> Bool
    {
        let statement = try self.prepare(database, """
        SELECT f.id, f.path, f.mtime_ms, f.coverage_since_day, f.coverage_until_day
        FROM files f
        WHERE f.scan_complete = 1
          AND NOT EXISTS (SELECT 1 FROM buffered_lines b WHERE b.file_id = f.id)
          AND NOT EXISTS (
              SELECT 1 FROM fork_lineage child
              JOIN fork_lineage parent ON parent.session_id = child.forked_from_id
              WHERE parent.file_id = f.id
                AND child.file_id != f.id
                AND (child.dependency_key IS NULL OR child.dependency_key != ?)
          )
        ORDER BY f.updated_at_ms, f.id
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(CostUsageScanner.codexForkDependencyNotRequiredKey, to: statement, at: 1)
        let activeWindow = self.activeWindowMs(sinceDay: sinceDay, untilDay: untilDay, calendar: calendar)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let mtime = sqlite3_column_int64(statement, 2)
            let coverageSince = self.columnText(statement, at: 3)
            let coverageUntil = self.columnText(statement, at: 4)
            let recentlyActive = activeWindow?.contains(mtime) == true
            let zeroDayRecentlyActive = coverageSince == nil && coverageUntil == nil && recentlyActive
            let touchesWindow: Bool = if let sinceDay, let untilDay,
                                         let coverageSince, let coverageUntil
            {
                coverageUntil >= sinceDay && coverageSince <= untilDay
            } else {
                false
            }
            let protected = zeroDayRecentlyActive
                || (protectRequestedWindow && (touchesWindow || recentlyActive))
            if !protected {
                let fileID = sqlite3_column_int64(statement, 0)
                try self.execute(database, "DELETE FROM files WHERE id = \(fileID)")
                return sqlite3_changes(database) > 0
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return false
    }

    private static func rowCount(_ database: OpaquePointer) throws -> Int64 {
        try self.scalarInt(database, "SELECT COUNT(*) FROM files")
    }

    private static func stripOldestRebuildableDetail(_ database: OpaquePointer) throws -> Bool {
        let statement = try self.prepare(database, """
        SELECT f.id, f.scan_state
        FROM files f
        WHERE NOT EXISTS (SELECT 1 FROM buffered_lines b WHERE b.file_id = f.id)
          AND ((SELECT COUNT(*) FROM token_snapshots t WHERE t.file_id = f.id) > 0
            OR (SELECT COUNT(*) FROM usage_rows r WHERE r.file_id = f.id) > 0)
        ORDER BY f.updated_at_ms, f.id
        LIMIT 1
        """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let stateData = self.columnData(statement, at: 1),
              var state = try? JSONDecoder().decode(CostUsageStoreScanState.self, from: stateData)
        else { return false }
        let fileID = sqlite3_column_int64(statement, 0)
        state.isComplete = false
        state.resumePayload = nil
        state.tokenTimestampsMonotonic = nil
        state.nextUsageRowIndex = nil
        let updatedState = try JSONEncoder().encode(state)
        let update = try self.prepare(database, """
        UPDATE files
        SET parsed_bytes = 0, anchor_indexed_bytes = NULL, anchor_window_start = NULL,
            anchor_sha256 = NULL, scan_state = ?, scan_complete = 0
        WHERE id = ?
        """)
        defer { sqlite3_finalize(update) }
        self.bind(updatedState, to: update, at: 1)
        sqlite3_bind_int64(update, 2, fileID)
        try self.stepDone(update, database: database)
        try self.execute(database, "DELETE FROM token_snapshots WHERE file_id = \(fileID)")
        try self.execute(database, "DELETE FROM usage_rows WHERE file_id = \(fileID)")
        try self.execute(database, "DELETE FROM accumulators WHERE file_id = \(fileID)")
        return true
    }

    private static func rebuildDayAggregates(_ database: OpaquePointer) throws {
        try self.execute(database, "DELETE FROM day_aggregates")
        try self.execute(database, """
        INSERT INTO day_aggregates (
            day, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens,
            request_count, known_cost_nanos, priority_surcharge_nanos, unpriced_tokens,
            standard_cost_nanos, priority_cost_nanos, standard_tokens, priority_tokens
        )
        SELECT day, model, SUM(input_tokens), SUM(cached_tokens), SUM(output_tokens),
               SUM(reasoning_tokens), SUM(request_count), SUM(known_cost_nanos),
               SUM(priority_surcharge_nanos), SUM(unpriced_tokens), SUM(standard_cost_nanos),
               SUM(priority_cost_nanos), SUM(standard_tokens), SUM(priority_tokens)
        FROM file_day_aggregates
        GROUP BY day, model
        """)
    }

    private static func markCatchUpRequired(_ database: OpaquePointer) throws {
        var metadata = try self.readSingleton(
            CostUsageStoreMetadata.self,
            database: database,
            table: "scan_metadata") ?? .empty
        metadata.catchUpPending = true
        metadata.lastScanUnixMs = 0
        try self.writeSingleton(metadata, database: database, table: "scan_metadata")
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
