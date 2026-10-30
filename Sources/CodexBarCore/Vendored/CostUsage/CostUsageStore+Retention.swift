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
            try Self.prune(database, home: self.home, sinceDay: sinceDay, untilDay: untilDay, calendar: calendar)
        }
    }

    @discardableResult
    func deleteFile(path: String) -> Bool {
        self.withDatabase(default: false) { database in
            let statement = try Self.prepare(database, "DELETE FROM files WHERE path = ? AND home = ?")
            defer { sqlite3_finalize(statement) }
            Self.bind(path, to: statement, at: 1)
            Self.bind(self.home, to: statement, at: 2)
            try Self.stepDone(statement, database: database)
            return sqlite3_changes(database) > 0
        }
    }

    private static func prune(
        _ database: OpaquePointer,
        home: String,
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
            if activeWindow != nil {
                // Native rows retain their session-level policy. A registered database can
                // contain both recent and expired turns, so prune its usage rows individually.
                let source = "home = ? AND json_extract(CAST(scan_state AS TEXT), '$.source') = 'opencodeLocalHistory'"
                let outside = """
                (COALESCE(json_extract(CAST(r.payload AS TEXT), '$.day'),
                   strftime('%Y-%m-%d', json_extract(CAST(r.payload AS TEXT), '$.createdMs') / 1000, 'unixepoch')) < ?
                 OR COALESCE(json_extract(CAST(r.payload AS TEXT), '$.day'),
                   strftime('%Y-%m-%d', json_extract(CAST(r.payload AS TEXT), '$.createdMs') / 1000, 'unixepoch')) > ?)
                """
                let statements = [
                    """
                    UPDATE files SET scan_complete = 0,
                      scan_state = json_remove(CAST(scan_state AS TEXT), '$.resumePayload')
                    WHERE \(source) AND EXISTS (
                      SELECT 1 FROM usage_rows r WHERE r.file_id = files.id AND \(outside))
                    """,
                    """
                    DELETE FROM usage_rows AS r WHERE r.file_id IN (SELECT id FROM files WHERE \(source))
                    AND \(outside)
                    """,
                ]
                for sql in statements {
                    let statement = try Self.prepare(database, sql)
                    defer { sqlite3_finalize(statement) }
                    Self.bind(home, to: statement, at: 1)
                    Self.bind(sinceDay, to: statement, at: 2)
                    Self.bind(untilDay, to: statement, at: 3)
                    try Self.stepDone(statement, database: database)
                }
            }
            let deleteFile = try self.prepare(database, "DELETE FROM files WHERE path = ? AND home = ?")
            defer { sqlite3_finalize(deleteFile) }
            var candidates: [RetentionCandidate] = []
            // Iterate to a fixpoint: deleting a stale child releases the fork protection on
            // its stale parent, which must then be pruned in the same pass instead of
            // lingering as an unreferenced out-of-window row.
            while true {
                let round = try self.retentionCandidates(
                    database,
                    home: home,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    activeWindow: activeWindow)
                guard !round.isEmpty else { break }
                for candidate in round {
                    sqlite3_reset(deleteFile)
                    sqlite3_clear_bindings(deleteFile)
                    self.bind(candidate.path, to: deleteFile, at: 1)
                    self.bind(home, to: deleteFile, at: 2)
                    try self.stepDone(deleteFile, database: database)
                }
                candidates += round
            }

            let deleteFileAggregates = try self.prepare(
                database,
                "DELETE FROM file_day_aggregates WHERE (day < ? OR day > ?) " +
                    "AND file_id IN (SELECT id FROM files WHERE home = ?)")
            defer { sqlite3_finalize(deleteFileAggregates) }
            self.bind(sinceDay, to: deleteFileAggregates, at: 1)
            self.bind(untilDay, to: deleteFileAggregates, at: 2)
            self.bind(home, to: deleteFileAggregates, at: 3)
            try self.stepDone(deleteFileAggregates, database: database)

            let deleteAggregates = try self.prepare(
                database,
                "DELETE FROM day_aggregates WHERE (day < ? OR day > ?) AND home = ?")
            defer { sqlite3_finalize(deleteAggregates) }
            self.bind(sinceDay, to: deleteAggregates, at: 1)
            self.bind(untilDay, to: deleteAggregates, at: 2)
            self.bind(home, to: deleteAggregates, at: 3)
            try self.stepDone(deleteAggregates, database: database)

            try self.pruneDiscovery(database, home: home, candidates: candidates)
            var metadata = try self.readSingleton(
                CostUsageStoreMetadata.self,
                database: database,
                table: "scan_metadata",
                home: home) ?? .empty
            metadata.scanSinceDay = sinceDay
            metadata.scanUntilDay = untilDay
            try self.writeSingleton(metadata, database: database, table: "scan_metadata", home: home)

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
        let scanCalendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        guard let sinceDay, let untilDay,
              let since = Self.dayStart(sinceDay, calendar: scanCalendar),
              let until = Self.dayStart(untilDay, calendar: scanCalendar)
        else { return nil }
        let end = scanCalendar.date(byAdding: .day, value: 1, to: until) ?? until
        let lower = Int64(since.timeIntervalSince1970 * 1000)
        let upper = Int64(end.timeIntervalSince1970 * 1000)
        guard lower < upper else { return nil }
        return lower..<upper
    }

    private static func dayStart(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day))
    }

    private static func retentionCandidates(
        _ database: OpaquePointer,
        home: String,
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
                  SELECT 1 FROM fork_lineage l JOIN files child ON child.id = l.file_id
                  WHERE child.home = f.home AND l.forked_from_id = f.session_id AND l.file_id != f.id
                    AND (l.dependency_key IS NULL OR l.dependency_key != ?)
              )
          )
          AND f.home = ?
        ORDER BY f.updated_at_ms, f.path
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(sinceDay, to: statement, at: 1)
        self.bind(untilDay, to: statement, at: 2)
        self.bind(CostUsageScanner.codexForkDependencyNotRequiredKey, to: statement, at: 3)
        self.bind(home, to: statement, at: 4)
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
        home: String,
        candidates: [RetentionCandidate]) throws
    {
        guard !candidates.isEmpty,
              var state = try self.readSingleton(
                  CostUsageStoreDiscoveryState.self,
                  database: database,
                  table: "discovery_state",
                  home: home)
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
        try self.writeSingleton(state, database: database, table: "discovery_state", home: home)
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
                table: "scan_metadata",
                home: self.home)
            let sinceDay = requestedSinceDay ?? metadata?.scanSinceDay
            let untilDay = requestedUntilDay ?? metadata?.scanUntilDay
            let rowLimit = max(0, maxRows)
            let byteLimit = max(0, maxFileBytes)
            if initialRows > Int64(rowLimit) || initialBytes > byteLimit,
               let sinceDay, let untilDay, sinceDay <= untilDay
            {
                // Budget eviction cannot reconstruct archived rows outside a smaller report window.
                let hasArchives = try Self.readFiles(database, home: self.home).contains {
                    CostUsageScanner.isArchivedCodexRollout($0.path)
                }
                if !hasArchives {
                    _ = try Self.prune(
                        database,
                        home: self.home,
                        sinceDay: sinceDay,
                        untilDay: untilDay,
                        calendar: calendar)
                }
            }

            var catchUpRequired = false
            // The row and byte budgets only remove files outside the requested window. Once
            // only protected data remains, preserving report fidelity takes precedence over
            // forcing the database under its best-effort byte cap.
            while try Self.rowCount(database) > Int64(rowLimit) {
                guard try Self.deleteOldestRetainedFile(
                    database,
                    home: self.home,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    calendar: calendar) else { break }
                catchUpRequired = true
            }
            try Self.reclaimFreePages(database)

            var fileBytes = Self.fileSize(at: self.databaseURL)
            while fileBytes > byteLimit {
                guard try Self.deleteOldestRetainedFile(
                    database,
                    home: self.home,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    calendar: calendar)
                else { break }
                catchUpRequired = true
                try Self.reclaimFreePages(database)
                fileBytes = Self.fileSize(at: self.databaseURL)
            }
            if catchUpRequired {
                try Self.rebuildDayAggregates(database, home: self.home)
                try Self.markCatchUpRequired(database, home: self.home)
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
        home: String,
        sinceDay: String?,
        untilDay: String?,
        calendar: Calendar) throws -> Bool
    {
        let statement = try self.prepare(database, """
        SELECT f.id, f.path, f.mtime_ms, f.coverage_since_day, f.coverage_until_day
        FROM files f
        WHERE f.scan_complete = 1
          AND NOT EXISTS (SELECT 1 FROM buffered_lines b WHERE b.file_id = f.id)
          AND NOT EXISTS (
              SELECT 1 FROM fork_lineage child
              JOIN fork_lineage parent ON parent.session_id = child.forked_from_id
              JOIN files child_file ON child_file.id = child.file_id
              WHERE child_file.home = f.home AND parent.file_id = f.id
                AND child.file_id != f.id
                AND (child.dependency_key IS NULL OR child.dependency_key != ?)
          )
          AND f.home = ?
        ORDER BY f.updated_at_ms, f.id
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(CostUsageScanner.codexForkDependencyNotRequiredKey, to: statement, at: 1)
        self.bind(home, to: statement, at: 2)
        let activeWindow = self.activeWindowMs(sinceDay: sinceDay, untilDay: untilDay, calendar: calendar)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let mtime = sqlite3_column_int64(statement, 2)
            let coverageSince = self.columnText(statement, at: 3)
            let coverageUntil = self.columnText(statement, at: 4)
            let recentlyActive = activeWindow?.contains(mtime) == true
            let touchesWindow: Bool = if let sinceDay, let untilDay,
                                         let coverageSince, let coverageUntil
            {
                coverageUntil >= sinceDay && coverageSince <= untilDay
            } else {
                false
            }
            let archived = self.columnText(statement, at: 1).map(CostUsageScanner.isArchivedCodexRollout) == true
            let protected = touchesWindow || recentlyActive || archived
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

    static func rebuildDayAggregates(_ database: OpaquePointer, home: String) throws {
        try self.deleteHomeRows(database, table: "day_aggregates", home: home)
        let statement = try self.prepare(database, """
        INSERT INTO day_aggregates (
            home,
            day, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens,
            request_count, authoritative_cost_nanos,
            standard_input_tokens, standard_cached_tokens, standard_output_tokens,
            priority_input_tokens, priority_cached_tokens, priority_output_tokens,
            standard_tokens, priority_tokens
        )
        SELECT f.home, day, model, SUM(input_tokens), SUM(cached_tokens), SUM(output_tokens),
               SUM(reasoning_tokens), SUM(request_count), SUM(authoritative_cost_nanos),
               SUM(standard_input_tokens), SUM(standard_cached_tokens), SUM(standard_output_tokens),
               SUM(priority_input_tokens), SUM(priority_cached_tokens), SUM(priority_output_tokens),
               SUM(standard_tokens), SUM(priority_tokens)
        FROM file_day_aggregates a JOIN files f ON f.id = a.file_id
        WHERE f.home = ?
        GROUP BY day, model
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(home, to: statement, at: 1)
        try self.stepDone(statement, database: database)
    }

    private static func markCatchUpRequired(_ database: OpaquePointer, home: String) throws {
        var metadata = try self.readSingleton(
            CostUsageStoreMetadata.self,
            database: database,
            table: "scan_metadata",
            home: home) ?? .empty
        metadata.catchUpPending = true
        metadata.lastScanUnixMs = 0
        metadata.scanInventoryPaths = nil
        try self.writeSingleton(metadata, database: database, table: "scan_metadata", home: home)
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
    static func writeSingleton(
        _ value: some Encodable,
        database: OpaquePointer,
        table: String,
        home: String) throws
    {
        let payload = try JSONEncoder().encode(value)
        let statement = try self.prepare(database, """
        INSERT INTO \(table)(home, id, payload) VALUES (?, 1, ?)
        ON CONFLICT(home, id) DO UPDATE SET payload = excluded.payload
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(home, to: statement, at: 1)
        self.bind(payload, to: statement, at: 2)
        try self.stepDone(statement, database: database)
    }
}
