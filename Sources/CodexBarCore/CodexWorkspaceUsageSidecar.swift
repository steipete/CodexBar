import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// swiftlint:disable type_body_length
/// CodexBar-owned persistence for local Workspaces attribution. This database
/// never attaches to or writes Codex's state database; it only imports typed
/// catalog/cache values after those sources have been read successfully.
struct CodexWorkspaceUsageSidecar: Sendable {
    private static let schemaVersion = 6
    private static let snapshotPayloadFormatVersion = 3
    private let cacheRoot: URL?
    private let usageRowReadRecorder: CostUsageCodexUsageRowStore.RowReadRecorder?
    private let usageCacheWorkRecorder: UsageCacheWorkRecorder?

    struct UsageCacheWorkMetrics: Equatable {
        let eventRowsDecoded: Int
        let eventRowGroupWritebacks: Int
    }

    final class UsageCacheWorkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var eventRowsDecoded = 0
        private var eventRowGroupWritebacks = 0

        func snapshot() -> UsageCacheWorkMetrics {
            self.lock.lock()
            defer { self.lock.unlock() }
            return UsageCacheWorkMetrics(
                eventRowsDecoded: self.eventRowsDecoded,
                eventRowGroupWritebacks: self.eventRowGroupWritebacks)
        }

        fileprivate func recordEventRowDecoded() {
            self.lock.lock()
            self.eventRowsDecoded += 1
            self.lock.unlock()
        }

        fileprivate func recordEventRowGroupWriteback() {
            self.lock.lock()
            self.eventRowGroupWritebacks += 1
            self.lock.unlock()
        }
    }

    private struct RolloutSourceIdentity: Equatable {
        let mtimeUnixMs: Int64
        let size: Int64
        let parsedBytes: Int64
        let sessionID: String
        let producerKey: String
        let pricingKey: String
        let contentFingerprint: String

        init(
            mtimeUnixMs: Int64,
            size: Int64,
            parsedBytes: Int64,
            sessionID: String,
            producerKey: String,
            pricingKey: String,
            contentFingerprint: String)
        {
            self.mtimeUnixMs = mtimeUnixMs
            self.size = size
            self.parsedBytes = parsedBytes
            self.sessionID = sessionID
            self.producerKey = producerKey
            self.pricingKey = pricingKey
            self.contentFingerprint = contentFingerprint
        }

        init(usage: CostUsageFileUsage, cache: CostUsageCache) {
            self.mtimeUnixMs = usage.mtimeUnixMs
            self.size = usage.size
            self.parsedBytes = usage.parsedBytes ?? -1
            self.sessionID = usage.codexSession?.sessionId ?? usage.sessionId ?? ""
            self.producerKey = cache.producerKey ?? ""
            self.pricingKey = cache.codexPricingKey ?? ""
            self.contentFingerprint = usage.codexWorkspaceUsageFingerprintValue()
        }

        var legacyFingerprint: String {
            [
                "version=3",
                "mtime=\(self.mtimeUnixMs)",
                "size=\(self.size)",
                "parsed=\(self.parsedBytes)",
                "session=\(self.sessionID)",
                "producer=\(self.producerKey)",
                "pricing=\(self.pricingKey)",
                "content=\(self.contentFingerprint)",
            ].joined(separator: "|")
        }
    }

    private struct UsageRowPublication: Equatable {
        let generation: String
        let rowCount: Int
        let prefixDigest: String

        init(generation: String, rowCount: Int, prefixDigest: String) {
            self.generation = generation
            self.rowCount = rowCount
            self.prefixDigest = prefixDigest
        }

        init(_ state: CostUsageCodexUsageRowSidecarState) {
            self.init(
                generation: state.generation,
                rowCount: state.rowCount,
                prefixDigest: state.prefixDigest)
        }

        func hasSameContent(as other: Self) -> Bool {
            self.rowCount == other.rowCount && self.prefixDigest == other.prefixDigest
        }
    }

    private struct PersistedRollout {
        let identity: RolloutSourceIdentity
        let usageRowPublication: UsageRowPublication?
    }

    init(
        cacheRoot: URL? = nil,
        usageRowReadRecorder: CostUsageCodexUsageRowStore.RowReadRecorder? = nil,
        usageCacheWorkRecorder: UsageCacheWorkRecorder? = nil)
    {
        self.cacheRoot = cacheRoot
        self.usageRowReadRecorder = usageRowReadRecorder
        self.usageCacheWorkRecorder = usageCacheWorkRecorder
    }

    func loadLatestSnapshot(
        scopeSignature: String,
        historyDays: Int,
        rootsFingerprint: [String: Int64]? = nil,
        cache: CostUsageCache? = nil,
        catalog: CodexThreadCatalog? = nil) -> CodexLocalProjectUsageSnapshot?
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard let db = self.open(readOnly: true) else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT snapshot_payloads.payload,
               index_state.roots_fingerprint,
               index_state.catalog_fingerprint,
               index_state.cache_producer_key,
               index_state.pricing_key,
               index_state.cache_fingerprint,
               snapshot_payloads.payload_format_version
        FROM snapshot_payloads
        JOIN index_state ON index_state.scope_signature = snapshot_payloads.scope_signature
        WHERE snapshot_payloads.scope_signature = ?
          AND snapshot_payloads.history_days = ?
          AND snapshot_payloads.is_complete = 1
        ORDER BY updated_at_ms DESC
        LIMIT 1
        """
        guard let statement = Self.prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        Self.bind(scopeSignature, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, Int64(historyDays))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        let length = Int(sqlite3_column_bytes(statement, 0))
        let data = Data(bytes: bytes, count: length)
        let payloadFormatVersion = Int(sqlite3_column_int(statement, 6))
        guard payloadFormatVersion == Self.snapshotPayloadFormatVersion,
              let snapshot = try? JSONDecoder.codexLocalProjectUsageSidecar.decode(
                  CodexLocalProjectUsageSnapshot.self,
                  from: data)
        else { return nil }
        // Snapshots written before project-level detail was persisted can still
        // contain valid totals, but cannot render a selected project's chart or
        // sessions. Keep the sidecar's normalized rows and rebuild only this
        // presentation payload on the next background refresh.
        guard snapshot.hasInspectorDetail, snapshot.modelsAnalytics != nil else { return nil }
        if let rootsFingerprint {
            guard let rootsBytes = sqlite3_column_blob(statement, 1) else { return nil }
            let rootsLength = Int(sqlite3_column_bytes(statement, 1))
            guard let persistedRoots = try? JSONDecoder().decode(
                [String: Int64].self,
                from: Data(bytes: rootsBytes, count: rootsLength)),
                persistedRoots == rootsFingerprint
            else { return nil }
        }
        if let cache {
            guard Self.columnString(statement, at: 3) == cache.producerKey,
                  Self.columnString(statement, at: 4) == cache.codexPricingKey,
                  Self.columnString(statement, at: 5) == Self.cacheFingerprint(cache)
            else { return nil }
        }
        if let catalog, Self.columnString(statement, at: 2) != catalog.fingerprint {
            return nil
        }
        return snapshot
        #else
        return nil
        #endif
    }

    func synchronize(
        snapshot: CodexLocalProjectUsageSnapshot,
        cache: CostUsageCache,
        catalog: CodexThreadCatalog,
        catalogIsComplete: Bool = true,
        rootsFingerprint: [String: Int64]) throws
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard let db = self.open(readOnly: false) else {
            throw SidecarError.openFailed
        }
        defer { sqlite3_close(db) }
        try Self.ensureSchema(db)
        try Self.begin(db)
        do {
            let generation = UUID().uuidString
            try self.upsertCatalog(catalog, generation: generation, db: db)
            if catalogIsComplete {
                try self.pruneCatalog(generation: generation, db: db)
            }
            try self.importChangedRollouts(cache, catalog: catalog, generation: generation, db: db)
            try self.markMissingRollouts(generation: generation, db: db)
            try self.storeSnapshot(snapshot, cache: cache, catalog: catalog, rootsFingerprint: rootsFingerprint, db: db)
            try Self.commit(db)
        } catch {
            Self.rollback(db)
            throw error
        }
        #else
        _ = snapshot
        _ = cache
        _ = catalog
        _ = catalogIsComplete
        _ = rootsFingerprint
        #endif
    }

    /// Imports only source deltas. Callers can then aggregate from
    /// `usageCache(roots:)` before committing a new complete snapshot.
    func synchronizeSources(
        cache: CostUsageCache,
        catalog: CodexThreadCatalog,
        catalogIsComplete: Bool = true) throws
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard let db = self.open(readOnly: false) else { throw SidecarError.openFailed }
        defer { sqlite3_close(db) }
        try Self.ensureSchema(db)
        try Self.begin(db)
        do {
            let generation = UUID().uuidString
            try self.upsertCatalog(catalog, generation: generation, db: db)
            if catalogIsComplete {
                try self.pruneCatalog(generation: generation, db: db)
            }
            try self.importChangedRollouts(cache, catalog: catalog, generation: generation, db: db)
            try self.markMissingRollouts(generation: generation, db: db)
            try Self.commit(db)
        } catch {
            Self.rollback(db)
            throw error
        }
        #else
        _ = cache
        _ = catalog
        _ = catalogIsComplete
        #endif
    }

    /// Rehydrates only the attribution fields and daily usage rows needed by
    /// the existing project aggregator. The scanner remains authoritative for
    /// JSONL cursors and token deltas; this avoids another walk of its cache.
    func usageCache(roots: [String: Int64]) throws -> CostUsageCache {
        #if canImport(SQLite3) || canImport(CSQLite3)
        guard let db = self.open(readOnly: true) else { throw SidecarError.openFailed }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT r.rollout_path,
               COALESCE(c.id, r.session_id),
               COALESCE(c.cwd, r.cwd),
               COALESCE(c.title, c.preview, r.title),
               COALESCE(c.created_at_ms, r.started_at_ms),
               COALESCE(c.updated_at_ms, r.latest_activity_ms),
               COALESCE(c.model, r.last_model),
               r.forked_from_id,
               r.project_path,
               r.canonical_project_path,
               d.day,
               d.model,
               d.input_tokens,
               d.cached_input_tokens,
               d.output_tokens,
               d.cost_nanos,
               d.standard_tokens,
               d.priority_tokens,
               d.standard_cost_nanos,
               d.priority_cost_nanos,
               d.priority_surcharge_nanos
        FROM usage_rollouts r
        LEFT JOIN catalog_threads c ON c.id = r.session_id OR c.rollout_path = r.rollout_path
        JOIN usage_daily d ON d.rollout_path = r.rollout_path
        WHERE r.is_present = 1
        ORDER BY r.rollout_path, d.day, d.model
        """
        guard let statement = Self.prepare(db, sql) else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }

        var cache = CostUsageCache()
        cache.roots = roots
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = Self.columnString(statement, at: 0),
                  let day = Self.columnString(statement, at: 10),
                  let model = Self.columnString(statement, at: 11)
            else { continue }

            var usage = cache.files[path] ?? Self.emptyFileUsage(
                sessionId: Self.columnString(statement, at: 1),
                cwd: Self.columnString(statement, at: 2),
                title: Self.columnString(statement, at: 3),
                startedAtUnixMs: Self.columnInt64(statement, at: 4),
                latestActivityUnixMs: Self.columnInt64(statement, at: 5),
                lastModel: Self.columnString(statement, at: 6),
                forkedFromId: Self.columnString(statement, at: 7),
                projectPath: Self.columnString(statement, at: 8),
                canonicalProjectPath: Self.columnString(statement, at: 9))
            usage.days[day, default: [:]][model] = [
                Int(sqlite3_column_int64(statement, 12)),
                Int(sqlite3_column_int64(statement, 13)),
                Int(sqlite3_column_int64(statement, 14)),
            ]
            Self.assign(Self.columnInt64(statement, at: 15), to: &usage.codexCostNanos, day: day, model: model)
            Self.assign(Self.columnInt64(statement, at: 16), to: &usage.codexStandardTokens, day: day, model: model)
            Self.assign(Self.columnInt64(statement, at: 17), to: &usage.codexPriorityTokens, day: day, model: model)
            Self.assign(Self.columnInt64(statement, at: 18), to: &usage.codexStandardCostNanos, day: day, model: model)
            Self.assign(Self.columnInt64(statement, at: 19), to: &usage.codexPriorityCostNanos, day: day, model: model)
            Self.assign(
                Self.columnInt64(statement, at: 20),
                to: &usage.codexPrioritySurchargeNanos,
                day: day,
                model: model)
            cache.files[path] = usage
        }
        let eventSQL = """
        SELECT e.rollout_path, e.day, e.canonical_model, e.raw_model, e.turn_id, e.event_index,
               e.timestamp_ms, e.input_tokens, e.cached_input_tokens, e.output_tokens,
               e.known_cost_nanos, e.unpriced_tokens, e.pricing_model, e.pricing_mode,
               e.reasoning_tokens
        FROM usage_events e
        JOIN usage_rollouts r ON r.rollout_path = e.rollout_path
        WHERE r.is_present = 1 AND r.event_detail_complete = 1
        ORDER BY e.rollout_path, e.event_index
        """
        guard let eventStatement = Self.prepare(db, eventSQL) else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(eventStatement) }
        var currentEventPath: String?
        var currentEventRows: [CostUsageScanner.CodexUsageRow] = []
        func publishCurrentEventRows() {
            guard let currentEventPath,
                  !currentEventRows.isEmpty,
                  var usage = cache.files[currentEventPath]
            else { return }
            usage.codexRows = currentEventRows
            cache.files[currentEventPath] = usage
            self.usageCacheWorkRecorder?.recordEventRowGroupWriteback()
        }
        while sqlite3_step(eventStatement) == SQLITE_ROW {
            guard let path = Self.columnString(eventStatement, at: 0),
                  cache.files[path] != nil
            else { continue }
            if currentEventPath != path {
                publishCurrentEventRows()
                currentEventPath = path
                // The just-published array now shares storage with the cache entry. Drop the
                // local reference instead of asking Array to preserve capacity and copy it.
                currentEventRows = []
            }
            guard let day = Self.columnString(eventStatement, at: 1),
                  let canonicalModel = Self.columnString(eventStatement, at: 2)
            else { continue }
            self.usageCacheWorkRecorder?.recordEventRowDecoded()
            currentEventRows.append(CostUsageScanner.CodexUsageRow(
                day: day,
                model: canonicalModel,
                rawModel: Self.columnString(eventStatement, at: 3),
                turnID: Self.columnString(eventStatement, at: 4),
                eventIndex: Self.columnInt64(eventStatement, at: 5).map(Int.init),
                timestampUnixMs: Self.columnInt64(eventStatement, at: 6),
                input: Int(sqlite3_column_int64(eventStatement, 7)),
                cached: Int(sqlite3_column_int64(eventStatement, 8)),
                output: Int(sqlite3_column_int64(eventStatement, 9)),
                reasoning: Self.columnInt64(eventStatement, at: 14).map(Int.init),
                knownCostNanos: Self.columnInt64(eventStatement, at: 10),
                unpricedTokens: Self.columnInt64(eventStatement, at: 11).map(Int.init),
                pricingModel: Self.columnString(eventStatement, at: 12),
                pricingMode: Self.columnString(eventStatement, at: 13)))
        }
        publishCurrentEventRows()
        return cache
        #else
        _ = roots
        return CostUsageCache()
        #endif
    }

    func clear() {
        try? FileManager.default.removeItem(at: self.databaseURL())
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: self.databaseURL().path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: self.databaseURL().path + "-shm"))
    }

    private func databaseURL() -> URL {
        let root = self.cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("local-usage", isDirectory: true)
            .appendingPathComponent("codex-workspaces-v1.sqlite", isDirectory: false)
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private func open(readOnly: Bool) -> OpaquePointer? {
        let url = self.databaseURL()
        if !readOnly {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 250)
        if !readOnly {
            guard sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil) == SQLITE_OK,
                  sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil) == SQLITE_OK
            else {
                sqlite3_close(db)
                return nil
            }
        }
        return db
    }

    private static func ensureSchema(_ db: OpaquePointer?) throws {
        let current = Self.userVersion(db)
        guard current == 0 || current == 5 || current == Self.schemaVersion else {
            throw SidecarError.incompatibleSchema
        }
        if current == 5 {
            try Self.begin(db)
            do {
                try Self.execute(db, "ALTER TABLE usage_rollouts ADD COLUMN row_sidecar_generation TEXT")
                try Self.execute(db, "ALTER TABLE usage_rollouts ADD COLUMN row_sidecar_row_count INTEGER")
                try Self.execute(db, "ALTER TABLE usage_rollouts ADD COLUMN row_sidecar_prefix_digest TEXT")
                try Self.execute(db, "PRAGMA user_version = \(Self.schemaVersion)")
                try Self.commit(db)
            } catch {
                Self.rollback(db)
                throw error
            }
            return
        }
        guard current == 0 else { return }
        try Self.execute(db, """
        CREATE TABLE IF NOT EXISTS schema_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS catalog_threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            cwd TEXT,
            title TEXT,
            preview TEXT,
            model_provider TEXT,
            model TEXT,
            reasoning_effort TEXT,
            created_at_ms INTEGER,
            updated_at_ms INTEGER,
            archived INTEGER NOT NULL,
            source_fingerprint TEXT,
            last_seen_generation TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_rollouts (
            rollout_path TEXT PRIMARY KEY,
            fingerprint TEXT NOT NULL,
            session_id TEXT,
            cwd TEXT,
            title TEXT,
            started_at_ms INTEGER,
            latest_activity_ms INTEGER,
            last_model TEXT,
            project_path TEXT,
            canonical_project_path TEXT,
            forked_from_id TEXT,
            source_mtime_ms INTEGER,
            source_size INTEGER,
            source_parsed_bytes INTEGER,
            source_session_id TEXT,
            source_producer_key TEXT,
            source_pricing_key TEXT,
            content_fingerprint TEXT,
            row_sidecar_generation TEXT,
            row_sidecar_row_count INTEGER,
            row_sidecar_prefix_digest TEXT,
            event_detail_complete INTEGER NOT NULL DEFAULT 0,
            is_present INTEGER NOT NULL DEFAULT 1,
            last_seen_generation TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_daily (
            rollout_path TEXT NOT NULL,
            day TEXT NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cost_nanos INTEGER,
            standard_tokens INTEGER,
            priority_tokens INTEGER,
            standard_cost_nanos INTEGER,
            priority_cost_nanos INTEGER,
            priority_surcharge_nanos INTEGER,
            PRIMARY KEY (rollout_path, day, model)
        );
        CREATE TABLE IF NOT EXISTS usage_events (
            rollout_path TEXT NOT NULL,
            event_index INTEGER NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            day TEXT NOT NULL,
            canonical_model TEXT NOT NULL,
            raw_model TEXT,
            turn_id TEXT,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            known_cost_nanos INTEGER,
            unpriced_tokens INTEGER NOT NULL,
            pricing_model TEXT,
            pricing_mode TEXT,
            reasoning_tokens INTEGER,
            PRIMARY KEY (rollout_path, event_index)
        );
        CREATE TABLE IF NOT EXISTS snapshot_payloads (
            scope_signature TEXT NOT NULL,
            history_days INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            is_complete INTEGER NOT NULL,
            payload_format_version INTEGER NOT NULL DEFAULT 1,
            payload BLOB NOT NULL,
            PRIMARY KEY (scope_signature, history_days)
        );
        CREATE TABLE IF NOT EXISTS index_state (
            scope_signature TEXT PRIMARY KEY,
            roots_fingerprint TEXT NOT NULL,
            catalog_fingerprint TEXT,
            cache_producer_key TEXT,
            pricing_key TEXT,
            cache_fingerprint TEXT,
            last_success_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS usage_daily_rollout_day ON usage_daily (rollout_path, day);
        CREATE INDEX IF NOT EXISTS usage_events_timestamp ON usage_events (timestamp_ms);
        CREATE INDEX IF NOT EXISTS usage_events_model_timestamp ON usage_events (canonical_model, timestamp_ms);
        CREATE INDEX IF NOT EXISTS usage_events_turn ON usage_events (turn_id);
        CREATE INDEX IF NOT EXISTS usage_rollouts_session ON usage_rollouts (session_id);
        CREATE INDEX IF NOT EXISTS catalog_threads_rollout ON catalog_threads (rollout_path);
        """)
        try Self.execute(db, "PRAGMA user_version = \(Self.schemaVersion)")
    }

    private func upsertCatalog(
        _ catalog: CodexThreadCatalog,
        generation: String,
        db: OpaquePointer?) throws
    {
        let sql = """
        INSERT INTO catalog_threads (
            id, rollout_path, cwd, title, preview, model_provider, model, reasoning_effort,
            created_at_ms, updated_at_ms, archived, source_fingerprint, last_seen_generation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            rollout_path = excluded.rollout_path,
            cwd = excluded.cwd,
            title = excluded.title,
            preview = excluded.preview,
            model_provider = excluded.model_provider,
            model = excluded.model,
            reasoning_effort = excluded.reasoning_effort,
            created_at_ms = excluded.created_at_ms,
            updated_at_ms = excluded.updated_at_ms,
            archived = excluded.archived,
            source_fingerprint = excluded.source_fingerprint,
            last_seen_generation = excluded.last_seen_generation
        """
        guard let statement = Self.prepare(db, sql) else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }
        for entry in catalog.entriesById.values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            Self.bind(entry.id, to: statement, at: 1)
            Self.bind(entry.rolloutPath, to: statement, at: 2)
            Self.bind(entry.cwd, to: statement, at: 3)
            Self.bind(entry.title, to: statement, at: 4)
            Self.bind(entry.preview, to: statement, at: 5)
            Self.bind(entry.modelProvider, to: statement, at: 6)
            Self.bind(entry.model, to: statement, at: 7)
            Self.bind(entry.reasoningEffort, to: statement, at: 8)
            Self.bind(entry.createdAtUnixMs, to: statement, at: 9)
            Self.bind(entry.updatedAtUnixMs, to: statement, at: 10)
            sqlite3_bind_int(statement, 11, entry.archived ? 1 : 0)
            Self.bind(catalog.fingerprint, to: statement, at: 12)
            Self.bind(generation, to: statement, at: 13)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }
        }
    }

    /// A complete catalog generation is authoritative: entries absent from it
    /// must no longer override rollout-derived metadata. Unavailable reads
    /// deliberately skip this deletion so the last-good attribution remains.
    private func pruneCatalog(generation: String, db: OpaquePointer?) throws {
        guard let statement = Self.prepare(
            db,
            "DELETE FROM catalog_threads WHERE last_seen_generation != ?")
        else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }
        Self.bind(generation, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }
    }

    private func importChangedRollouts(
        _ cache: CostUsageCache,
        catalog: CodexThreadCatalog,
        generation: String,
        db: OpaquePointer?) throws
    {
        let existing = try Self.existingRollouts(db: db)
        let usageRowStore = CostUsageCodexUsageRowStore(
            cacheRoot: self.cacheRoot,
            rowReadRecorder: self.usageRowReadRecorder)
        guard let touchStatement = Self.prepare(
            db,
            "UPDATE usage_rollouts SET is_present = 1, last_seen_generation = ? WHERE rollout_path = ?")
        else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(touchStatement) }

        for (path, usage) in cache.files {
            let identity = RolloutSourceIdentity(usage: usage, cache: cache)
            let persisted = existing[path]
            let incomingPublication = usage.codexUsageRowSidecarState.map { UsageRowPublication($0) }
            let catalogEntry = catalog.entry(
                sessionId: usage.codexSession?.sessionId ?? usage.sessionId,
                rolloutPath: path)

            // Source growth can publish no new usage rows, and crash recovery can republish the
            // same content under another generation. In both cases the normalized events are
            // already exact; update only rollout/source metadata and the published reference.
            if let persisted,
               let persistedPublication = persisted.usageRowPublication,
               let incomingPublication,
               persistedPublication.hasSameContent(as: incomingPublication)
            {
                // A generation-only republish can reuse the normalized events, but the new JSON
                // reference must still be readable. This keeps missing/corrupt replacement
                // generations on the transactional failure path instead of accepting them based
                // on digest text alone.
                if persistedPublication.generation != incomingPublication.generation {
                    guard let reference = try Self.publishedUsageRowReference(
                        path: path,
                        usage: usage,
                        cache: cache)
                    else { throw SidecarError.invalidPublishedUsageRowReference }
                    try Self.requirePublishedUsageRowReference(
                        usageRowStore.validatePublishedReference(reference))
                }
                if persisted.identity == identity, persistedPublication == incomingPublication {
                    try Self.touchRollout(path: path, generation: generation, statement: touchStatement)
                } else {
                    try Self.upsertRollout(
                        path: path,
                        usage: usage,
                        catalogEntry: catalogEntry,
                        identity: identity,
                        usageRowPublication: incomingPublication,
                        eventDetailComplete: true,
                        generation: generation,
                        db: db)
                }
                continue
            }

            if persisted?.identity == identity,
               persisted?.usageRowPublication == nil,
               incomingPublication == nil
            {
                try Self.touchRollout(path: path, generation: generation, statement: touchStatement)
                continue
            }

            if let persisted,
               let persistedPublication = persisted.usageRowPublication,
               let incomingPublication,
               persistedPublication.generation == incomingPublication.generation,
               incomingPublication.rowCount > persistedPublication.rowCount
            {
                guard let reference = try Self.publishedUsageRowReference(
                    path: path,
                    usage: usage,
                    cache: cache)
                else { throw SidecarError.invalidPublishedUsageRowReference }
                let boundary = CostUsageCodexUsageRowPrefixBoundary(
                    generation: persistedPublication.generation,
                    rowCount: persistedPublication.rowCount,
                    prefixDigest: persistedPublication.prefixDigest)
                let records = try Self.publishedUsageRows(
                    usageRowStore.loadSuffix(reference, after: boundary))
                let rows = records.map(\.usageRow)
                guard rows.count == incomingPublication.rowCount - persistedPublication.rowCount,
                      Self.hasCompleteEventDetail(rows)
                else { throw SidecarError.invalidPublishedUsageRowReference }
                try Self.upsertRollout(
                    path: path,
                    usage: usage,
                    catalogEntry: catalogEntry,
                    identity: identity,
                    usageRowPublication: incomingPublication,
                    eventDetailComplete: true,
                    generation: generation,
                    db: db)
                try Self.insertDaily(path: path, usage: usage, db: db)
                try Self.insertEvents(path: path, rows: rows, db: db)
                continue
            }

            let eventUsage = try Self.usageForEventImport(
                path: path,
                usage: usage,
                cache: cache,
                store: usageRowStore)

            // A new content generation (or any non-monotonic state in the same generation) is a
            // replacement. Delete and rebuild inside this transaction so load/import failures
            // leave the last complete Workspace snapshot untouched.
            try Self.deleteUsage(path: path, db: db)
            try Self.upsertRollout(
                path: path,
                usage: eventUsage,
                catalogEntry: catalogEntry,
                identity: identity,
                usageRowPublication: incomingPublication,
                eventDetailComplete: Self.hasCompleteEventDetail(eventUsage),
                generation: generation,
                db: db)
            try Self.insertDaily(path: path, usage: eventUsage, db: db)
            try Self.insertEvents(path: path, usage: eventUsage, db: db)
        }
    }

    /// Hydrates scanner-owned rows only through the compact reference published in JSON. SQLite
    /// may contain a later, unpublished append after a crash, so querying the latest generation by
    /// path would make Workspaces observe data that the cost cache has not committed yet.
    private static func usageForEventImport(
        path: String,
        usage: CostUsageFileUsage,
        cache: CostUsageCache,
        store: CostUsageCodexUsageRowStore) throws -> CostUsageFileUsage
    {
        guard let reference = try publishedUsageRowReference(
            path: path,
            usage: usage,
            cache: cache)
        else { return usage }
        let records = try Self.publishedUsageRows(store.load(reference))
        var hydrated = usage
        hydrated.codexRows = records.map(\.usageRow)
        return hydrated
    }

    private static func publishedUsageRowReference(
        path: String,
        usage: CostUsageFileUsage,
        cache: CostUsageCache) throws -> CostUsageCodexUsageRowReference?
    {
        guard let state = usage.codexUsageRowSidecarState else { return nil }
        guard let fileId = usage.codexScanFileId,
              let anchor = usage.codexTokenIndexAnchor,
              let producerKey = usage.codexUsageRowProducerKey ?? cache.producerKey,
              !producerKey.isEmpty,
              let timeZoneIdentifier = cache.timeZoneIdentifier,
              !timeZoneIdentifier.isEmpty,
              anchor.indexedBytes == (usage.parsedBytes ?? usage.size)
        else { throw SidecarError.invalidPublishedUsageRowReference }

        return CostUsageCodexUsageRowReference(
            source: CostUsageCodexUsageRowSource(
                path: CostUsageCodexUsageRowStore.sourcePath(for: URL(fileURLWithPath: path)),
                fileId: fileId,
                indexedBytes: anchor.indexedBytes,
                anchor: anchor,
                isComplete: usage.codexScanComplete != false,
                changeUnixNs: usage.codexScanChangeUnixNs,
                sessionId: usage.codexSession?.sessionId ?? usage.sessionId,
                forkedFromId: usage.forkedFromId,
                forkDependencyKey: usage.forkBaselineDependencyKey,
                producerKey: producerKey,
                timeZoneIdentifier: timeZoneIdentifier),
            state: state)
    }

    private static func publishedUsageRows(
        _ lookup: CostUsageCodexUsageRowsLookup<[CostUsageCodexUsageRowRecord]>) throws ->
        [CostUsageCodexUsageRowRecord]
    {
        switch lookup {
        case let .ready(records):
            return records
        case .needsRebuild:
            throw SidecarError.publishedUsageRowsNeedRebuild
        case .temporarilyUnavailable:
            throw SidecarError.publishedUsageRowsTemporarilyUnavailable
        }
    }

    private static func requirePublishedUsageRowReference(
        _ lookup: CostUsageCodexUsageRowsLookup<Void>) throws
    {
        switch lookup {
        case .ready:
            return
        case .needsRebuild:
            throw SidecarError.publishedUsageRowsNeedRebuild
        case .temporarilyUnavailable:
            throw SidecarError.publishedUsageRowsTemporarilyUnavailable
        }
    }

    private func markMissingRollouts(generation: String, db: OpaquePointer?) throws {
        guard let statement = Self.prepare(
            db,
            "UPDATE usage_rollouts SET is_present = 0 WHERE last_seen_generation != ?")
        else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }
        Self.bind(generation, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }
    }

    private func storeSnapshot(
        _ snapshot: CodexLocalProjectUsageSnapshot,
        cache: CostUsageCache,
        catalog: CodexThreadCatalog,
        rootsFingerprint: [String: Int64],
        db: OpaquePointer?) throws
    {
        let data = try JSONEncoder.codexLocalProjectUsageSidecar.encode(snapshot)
        let sql = """
        INSERT INTO snapshot_payloads (
            scope_signature, history_days, updated_at_ms, is_complete, payload_format_version, payload
        ) VALUES (?, ?, ?, 1, ?, ?)
        ON CONFLICT(scope_signature, history_days) DO UPDATE SET
            updated_at_ms = excluded.updated_at_ms,
            is_complete = 1,
            payload_format_version = excluded.payload_format_version,
            payload = excluded.payload
        """
        guard let statement = Self.prepare(db, sql) else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }
        Self.bind(snapshot.scopeSignature, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, Int64(snapshot.historyDays))
        sqlite3_bind_int64(statement, 3, Int64((snapshot.updatedAt.timeIntervalSince1970 * 1000).rounded()))
        sqlite3_bind_int(statement, 4, Int32(Self.snapshotPayloadFormatVersion))
        Self.bind(data, to: statement, at: 5)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }

        let stateSQL = """
        INSERT INTO index_state (
            scope_signature, roots_fingerprint, catalog_fingerprint, cache_producer_key, pricing_key, cache_fingerprint,
            last_success_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(scope_signature) DO UPDATE SET
            roots_fingerprint = excluded.roots_fingerprint,
            catalog_fingerprint = COALESCE(excluded.catalog_fingerprint, index_state.catalog_fingerprint),
            cache_producer_key = excluded.cache_producer_key,
            pricing_key = excluded.pricing_key,
            cache_fingerprint = excluded.cache_fingerprint,
            last_success_ms = excluded.last_success_ms
        """
        guard let state = Self.prepare(db, stateSQL) else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(state) }
        Self.bind(snapshot.scopeSignature, to: state, at: 1)
        let rootsData = try JSONEncoder().encode(rootsFingerprint)
        Self.bind(rootsData, to: state, at: 2)
        Self.bind(catalog.fingerprint, to: state, at: 3)
        Self.bind(cache.producerKey, to: state, at: 4)
        Self.bind(cache.codexPricingKey, to: state, at: 5)
        Self.bind(Self.cacheFingerprint(cache), to: state, at: 6)
        sqlite3_bind_int64(state, 7, Int64((snapshot.updatedAt.timeIntervalSince1970 * 1000).rounded()))
        guard sqlite3_step(state) == SQLITE_DONE else { throw SidecarError.writeFailed }
    }

    // Source fields remain explicit so the sidecar never reconstructs parser state.
    // swiftlint:disable:next function_parameter_count
    private static func upsertRollout(
        path: String,
        usage: CostUsageFileUsage,
        catalogEntry: CodexThreadCatalogEntry?,
        identity: RolloutSourceIdentity,
        usageRowPublication: UsageRowPublication?,
        eventDetailComplete: Bool,
        generation: String,
        db: OpaquePointer?) throws
    {
        let session = usage.codexSession
        let sql = """
        INSERT INTO usage_rollouts (
            rollout_path, fingerprint, session_id, cwd, title, started_at_ms, latest_activity_ms, last_model,
            project_path, canonical_project_path, forked_from_id,
            source_mtime_ms, source_size, source_parsed_bytes, source_session_id, source_producer_key,
            source_pricing_key, content_fingerprint, row_sidecar_generation, row_sidecar_row_count,
            row_sidecar_prefix_digest, event_detail_complete, is_present, last_seen_generation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT(rollout_path) DO UPDATE SET
            fingerprint = excluded.fingerprint,
            session_id = COALESCE(excluded.session_id, usage_rollouts.session_id),
            cwd = COALESCE(excluded.cwd, usage_rollouts.cwd),
            title = COALESCE(excluded.title, usage_rollouts.title),
            started_at_ms = COALESCE(excluded.started_at_ms, usage_rollouts.started_at_ms),
            latest_activity_ms = COALESCE(excluded.latest_activity_ms, usage_rollouts.latest_activity_ms),
            last_model = COALESCE(excluded.last_model, usage_rollouts.last_model),
            project_path = COALESCE(excluded.project_path, usage_rollouts.project_path),
            canonical_project_path = COALESCE(excluded.canonical_project_path, usage_rollouts.canonical_project_path),
            forked_from_id = COALESCE(excluded.forked_from_id, usage_rollouts.forked_from_id),
            source_mtime_ms = excluded.source_mtime_ms,
            source_size = excluded.source_size,
            source_parsed_bytes = excluded.source_parsed_bytes,
            source_session_id = excluded.source_session_id,
            source_producer_key = excluded.source_producer_key,
            source_pricing_key = excluded.source_pricing_key,
            content_fingerprint = excluded.content_fingerprint,
            row_sidecar_generation = excluded.row_sidecar_generation,
            row_sidecar_row_count = excluded.row_sidecar_row_count,
            row_sidecar_prefix_digest = excluded.row_sidecar_prefix_digest,
            event_detail_complete = excluded.event_detail_complete,
            is_present = 1,
            last_seen_generation = excluded.last_seen_generation
        """
        guard let statement = Self.prepare(db, sql) else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }
        Self.bind(path, to: statement, at: 1)
        Self.bind(identity.legacyFingerprint, to: statement, at: 2)
        Self.bind(catalogEntry?.id ?? session?.sessionId ?? usage.sessionId, to: statement, at: 3)
        Self.bind(catalogEntry?.cwd ?? session?.cwd, to: statement, at: 4)
        Self.bind(catalogEntry?.title ?? session?.title, to: statement, at: 5)
        Self.bind(catalogEntry?.createdAtUnixMs ?? session?.startedAtUnixMs, to: statement, at: 6)
        Self.bind(catalogEntry?.updatedAtUnixMs ?? session?.latestActivityUnixMs, to: statement, at: 7)
        Self.bind(catalogEntry?.model ?? usage.lastModel, to: statement, at: 8)
        Self.bind(usage.projectPath, to: statement, at: 9)
        Self.bind(usage.canonicalProjectPath, to: statement, at: 10)
        Self.bind(
            catalogEntry == nil ? session?.forkedFromId ?? usage.forkedFromId : usage.forkedFromId,
            to: statement,
            at: 11)
        sqlite3_bind_int64(statement, 12, identity.mtimeUnixMs)
        sqlite3_bind_int64(statement, 13, identity.size)
        sqlite3_bind_int64(statement, 14, identity.parsedBytes)
        Self.bind(identity.sessionID, to: statement, at: 15)
        Self.bind(identity.producerKey, to: statement, at: 16)
        Self.bind(identity.pricingKey, to: statement, at: 17)
        Self.bind(identity.contentFingerprint, to: statement, at: 18)
        Self.bind(usageRowPublication?.generation, to: statement, at: 19)
        Self.bind(usageRowPublication?.rowCount, to: statement, at: 20)
        Self.bind(usageRowPublication?.prefixDigest, to: statement, at: 21)
        sqlite3_bind_int(statement, 22, eventDetailComplete ? 1 : 0)
        Self.bind(generation, to: statement, at: 23)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }
    }

    private static func insertDaily(path: String, usage: CostUsageFileUsage, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO usage_daily (
            rollout_path, day, model, input_tokens, cached_input_tokens, output_tokens, cost_nanos,
            standard_tokens, priority_tokens, standard_cost_nanos, priority_cost_nanos, priority_surcharge_nanos
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(rollout_path, day, model) DO UPDATE SET
            input_tokens = excluded.input_tokens,
            cached_input_tokens = excluded.cached_input_tokens,
            output_tokens = excluded.output_tokens,
            cost_nanos = excluded.cost_nanos,
            standard_tokens = excluded.standard_tokens,
            priority_tokens = excluded.priority_tokens,
            standard_cost_nanos = excluded.standard_cost_nanos,
            priority_cost_nanos = excluded.priority_cost_nanos,
            priority_surcharge_nanos = excluded.priority_surcharge_nanos
        """
        guard let statement = Self.prepare(db, sql) else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }
        for (day, models) in usage.days {
            for (model, values) in models {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                Self.bind(path, to: statement, at: 1)
                Self.bind(day, to: statement, at: 2)
                Self.bind(model, to: statement, at: 3)
                sqlite3_bind_int64(statement, 4, Int64(max(0, values[safe: 0] ?? 0)))
                sqlite3_bind_int64(statement, 5, Int64(max(0, values[safe: 1] ?? 0)))
                sqlite3_bind_int64(statement, 6, Int64(max(0, values[safe: 2] ?? 0)))
                Self.bind(usage.codexCostNanos?[day]?[model], to: statement, at: 7)
                Self.bind(usage.codexStandardTokens?[day]?[model], to: statement, at: 8)
                Self.bind(usage.codexPriorityTokens?[day]?[model], to: statement, at: 9)
                Self.bind(usage.codexStandardCostNanos?[day]?[model], to: statement, at: 10)
                Self.bind(usage.codexPriorityCostNanos?[day]?[model], to: statement, at: 11)
                Self.bind(usage.codexPrioritySurchargeNanos?[day]?[model], to: statement, at: 12)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }
            }
        }
    }

    private static func insertEvents(path: String, usage: CostUsageFileUsage, db: OpaquePointer?) throws {
        guard self.hasCompleteEventDetail(usage), let rows = usage.codexRows else { return }
        try self.insertEvents(path: path, rows: rows, db: db)
    }

    private static func insertEvents(
        path: String,
        rows: [CostUsageScanner.CodexUsageRow],
        db: OpaquePointer?) throws
    {
        let sql = """
        INSERT INTO usage_events (
            rollout_path, event_index, timestamp_ms, day, canonical_model, raw_model, turn_id,
            input_tokens, cached_input_tokens, output_tokens, known_cost_nanos, unpriced_tokens,
            pricing_model, pricing_mode, reasoning_tokens
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard let statement = Self.prepare(db, sql) else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            guard let eventIndex = row.eventIndex, let timestampUnixMs = row.timestampUnixMs else { continue }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            Self.bind(path, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, Int64(eventIndex))
            sqlite3_bind_int64(statement, 3, timestampUnixMs)
            Self.bind(row.day, to: statement, at: 4)
            Self.bind(row.model, to: statement, at: 5)
            Self.bind(row.rawModel, to: statement, at: 6)
            Self.bind(row.turnID, to: statement, at: 7)
            sqlite3_bind_int64(statement, 8, Int64(max(0, row.input)))
            sqlite3_bind_int64(statement, 9, Int64(max(0, row.cached)))
            sqlite3_bind_int64(statement, 10, Int64(max(0, row.output)))
            Self.bind(row.knownCostNanos, to: statement, at: 11)
            sqlite3_bind_int64(statement, 12, Int64(max(0, row.unpricedTokens ?? 0)))
            Self.bind(row.pricingModel, to: statement, at: 13)
            Self.bind(row.pricingMode, to: statement, at: 14)
            Self.bind(row.reasoning.map(Int64.init), to: statement, at: 15)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }
        }
    }

    private static func deleteUsage(path: String, db: OpaquePointer?) throws {
        for table in ["usage_daily", "usage_events"] {
            guard let statement = prepare(db, "DELETE FROM \(table) WHERE rollout_path = ?")
            else { throw SidecarError.statementFailed }
            defer { sqlite3_finalize(statement) }
            Self.bind(path, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }
        }
    }

    private static func hasCompleteEventDetail(_ usage: CostUsageFileUsage) -> Bool {
        guard let rows = usage.codexRows, !rows.isEmpty else { return usage.days.isEmpty }
        return self.hasCompleteEventDetail(rows)
    }

    private static func hasCompleteEventDetail(
        _ rows: [CostUsageScanner.CodexUsageRow]) -> Bool
    {
        rows.allSatisfy { $0.eventIndex != nil && $0.timestampUnixMs != nil }
    }

    private static func touchRollout(path: String, generation: String, statement: OpaquePointer?) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        self.bind(generation, to: statement, at: 1)
        self.bind(path, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SidecarError.writeFailed }
    }

    private static func existingRollouts(
        db: OpaquePointer?) throws -> [String: PersistedRollout]
    {
        guard let statement = prepare(
            db,
            """
            SELECT rollout_path, source_mtime_ms, source_size, source_parsed_bytes, source_session_id,
                   source_producer_key, source_pricing_key, content_fingerprint,
                   row_sidecar_generation, row_sidecar_row_count, row_sidecar_prefix_digest
            FROM usage_rollouts
            WHERE event_detail_complete = 1
            """)
        else { throw SidecarError.statementFailed }
        defer { sqlite3_finalize(statement) }
        var rollouts: [String: PersistedRollout] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = Self.columnString(statement, at: 0),
                  let contentFingerprint = Self.columnString(statement, at: 7)
            else { continue }
            let identity = RolloutSourceIdentity(
                mtimeUnixMs: Self.columnInt64(statement, at: 1) ?? Int64.min,
                size: Self.columnInt64(statement, at: 2) ?? Int64.min,
                parsedBytes: Self.columnInt64(statement, at: 3) ?? Int64.min,
                sessionID: Self.columnString(statement, at: 4) ?? "",
                producerKey: Self.columnString(statement, at: 5) ?? "",
                pricingKey: Self.columnString(statement, at: 6) ?? "",
                contentFingerprint: contentFingerprint)
            let publication: UsageRowPublication? = if let generation = Self.columnString(statement, at: 8),
                                                       let storedRowCount = Self.columnInt64(statement, at: 9),
                                                       let rowCount = Int(exactly: storedRowCount),
                                                       rowCount >= 0,
                                                       let prefixDigest = Self.columnString(statement, at: 10)
            {
                UsageRowPublication(
                    generation: generation,
                    rowCount: rowCount,
                    prefixDigest: prefixDigest)
            } else {
                nil
            }
            rollouts[path] = PersistedRollout(
                identity: identity,
                usageRowPublication: publication)
        }
        return rollouts
    }

    private static func cacheFingerprint(_ cache: CostUsageCache) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for (path, usage) in cache.files.sorted(by: { $0.key < $1.key }) {
            let identity = RolloutSourceIdentity(usage: usage, cache: cache)
            for byte in "\(path)|\(identity.legacyFingerprint)\n".utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return String(hash, radix: 16)
    }

    private static func columnString(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private static func columnInt64(_ statement: OpaquePointer?, at index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private static func assign<T: FixedWidthInteger>(
        _ value: Int64?,
        to map: inout [String: [String: T]]?,
        day: String,
        model: String)
    {
        guard let value else { return }
        var values = map ?? [:]
        values[day, default: [:]][model] = T(value)
        map = values
    }

    // A SQL row carries scanner metadata as individual columns. Keeping the
    // parameters explicit avoids a lossy intermediate representation.
    // swiftlint:disable:next function_parameter_count
    private static func emptyFileUsage(
        sessionId: String?,
        cwd: String?,
        title: String?,
        startedAtUnixMs: Int64?,
        latestActivityUnixMs: Int64?,
        lastModel: String?,
        forkedFromId: String?,
        projectPath: String?,
        canonicalProjectPath: String?) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            mtimeUnixMs: 0,
            size: 0,
            days: [:],
            parsedBytes: nil,
            lastModel: lastModel,
            lastTotals: nil,
            lastCountedTotals: nil,
            lastRawTotalsBaseline: nil,
            hasDivergentTotals: nil,
            lastCodexTurnID: nil,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexCostCacheComplete: true,
            codexSession: CostUsageCodexSessionMetadata(
                sessionId: sessionId,
                forkedFromId: forkedFromId,
                cwd: cwd,
                title: title,
                startedAtUnixMs: startedAtUnixMs,
                latestActivityUnixMs: latestActivityUnixMs),
            codexCostNanos: nil,
            codexPrioritySurchargeNanos: nil,
            codexStandardCostNanos: nil,
            codexPriorityCostNanos: nil,
            codexStandardTokens: nil,
            codexPriorityTokens: nil,
            codexTurnIDs: nil,
            codexRows: nil,
            claudeRows: nil)
    }

    private static func begin(_ db: OpaquePointer?) throws {
        try self.execute(db, "BEGIN IMMEDIATE")
    }

    private static func commit(_ db: OpaquePointer?) throws {
        try self.execute(db, "COMMIT")
    }

    private static func rollback(_ db: OpaquePointer?) {
        try? self.execute(db, "ROLLBACK")
    }

    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SidecarError.writeFailed }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private static func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private static func bind(_ value: Int64?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private static func bind(_ value: Int?, to statement: OpaquePointer?, at index: Int32) {
        self.bind(value.map(Int64.init), to: statement, at: index)
    }

    private static func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.sqliteTransient)
        }
    }

    private static func userVersion(_ db: OpaquePointer?) -> Int32 {
        guard let statement = prepare(db, "PRAGMA user_version") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private enum SidecarError: Error {
        case openFailed
        case incompatibleSchema
        case statementFailed
        case writeFailed
        case invalidPublishedUsageRowReference
        case publishedUsageRowsNeedRebuild
        case publishedUsageRowsTemporarilyUnavailable
    }
    #endif
}

extension JSONDecoder {
    static var codexLocalProjectUsageSidecar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

extension JSONEncoder {
    static var codexLocalProjectUsageSidecar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

// swiftlint:enable type_body_length
