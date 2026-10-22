import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// The shared machine-local OpenCode history for assistant records whose provider is exactly
/// `openai`, consumed by every path of the ambient Codex ledger (#3273).
///
/// Architecture — the reasons PR #4574 was closed are the contract here:
/// - **One durable cache, fingerprint gated.** The decoded per-day entries persist in this
///   store's own SQLite database; a scan re-reads the OpenCode database only when its
///   fingerprint (size, mtime, WAL size, WAL mtime) changes. Nothing is shared with the
///   OpenCode Go reader's in-memory cache, so the two histories never evict each other.
/// - **Cache-only publication.** Cached publications read the persisted entries and never
///   touch the OpenCode database, keeping the tightened cost-ledger I/O budget intact.
/// - **Windowing at read time.** The store retains compact per-day entries, not a
///   pre-windowed report, and aggregates for the requested window on each read.
///
/// Source contract (see issue #3273):
/// - Reads usage metadata only, with `SQLITE_OPEN_READONLY`. Prompts, responses, tool output
///   and `auth.json` are never read; rows are never attributed to an account.
/// - Selects only assistant records with an exact `providerID == "openai"` match.
/// - Counts valid `step-finish` parts when present and falls back to message-level totals
///   only when no valid parts exist, mirroring the OpenCode Go reader's precedence.
/// - Deduplicates by stable message IDs: OpenCode v2 copies legacy `message` rows into
///   `session_message` under the same IDs, so v2 rows only contribute IDs the legacy table
///   does not already hold. No fuzzy timestamp or token matching is attempted.
/// - Preserves recorded token dimensions. Recorded cost is surfaced as-is (OpenCode records
///   `$0` for subscription usage); dollars are never recomputed or reinterpreted here.
public struct OpenCodeLocalHistoryStore: Sendable {
    /// Versioned so a schema change ships as a new filename and older builds keep working.
    public static let cacheDatabaseFilename = "opencode-local-history-v1.sqlite"

    private let databaseURL: URL
    private let cacheURL: URL

    public init(
        cacheRoot: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        let dataRoot = Self.xdgDataRoot(homeDirectory: homeDirectory, environment: environment)
        let openCodeDirectory = dataRoot.appendingPathComponent("opencode", isDirectory: true)
        self.databaseURL = Self.primaryDatabaseURL(dataDirectory: openCodeDirectory, environment: environment)
        self.cacheURL = Self.resolvedCacheRoot(cacheRoot)
            .appendingPathComponent(Self.cacheDatabaseFilename, isDirectory: false)
    }

    /// The store's own cache directory, mirroring the OpenCodex usage cache layout. A scan's
    /// cache root wins when supplied; production falls back to the CodexBar caches directory.
    static func resolvedCacheRoot(_ cacheRoot: URL?) -> URL {
        if let cacheRoot {
            return cacheRoot
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("opencode-local-history", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("opencode-local-history", isDirectory: true)
    }

    public init(databaseURL: URL, cacheURL: URL) {
        self.databaseURL = databaseURL
        self.cacheURL = cacheURL
    }

    // MARK: - Reads

    /// A windowed report for the scan path. The OpenCode database is opened only when its
    /// fingerprint changed since the persisted entries were decoded; otherwise the cached
    /// entries are used as-is. `nil` means there is no matching history. Only genuine
    /// SQLite read failures throw; a missing or empty OpenCode installation never disrupts
    /// the native Codex scan.
    public func loadDailyReport(since: Date, until: Date, calendar: Calendar) throws -> CostUsageDailyReport? {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            try? self.removeAllCachedEntries()
            return nil
        }
        let cached = try self.readCachedEntries()
        if let cached, cached.matchesCurrentDatabase(at: self.databaseURL) {
            return Self.windowedReport(entries: cached.entries, since: since, until: until, calendar: calendar)
        }
        guard let entries = try self.decodeEntries(), !entries.isEmpty else {
            try? self.removeAllCachedEntries()
            return nil
        }
        try? self.persist(entries: entries)
        return Self.windowedReport(entries: entries, since: since, until: until, calendar: calendar)
    }

    /// A windowed report for cached publications: reads only the persisted entries — no
    /// database access at all, not even a fingerprint stat (#3273 cache-only publication).
    /// `nil` when nothing is cached yet; the next scan refreshes the cache and its
    /// fingerprint gate decides whether the persisted entries are still current.
    public func cachedDailyReport(since: Date, until: Date, calendar: Calendar) -> CostUsageDailyReport? {
        guard let cached = try? self.readCachedEntries() else { return nil }
        return Self.windowedReport(entries: cached.entries, since: since, until: until, calendar: calendar)
    }

    /// Removes persisted entries. Called when the setting turns off so stale rows can never
    /// surface again.
    public func removeAllCachedEntries() throws {
        try CacheDatabase.withDatabase(at: self.cacheURL) { db in
            try CacheDatabase.execute(db, "DELETE FROM entries")
            try CacheDatabase.execute(db, "DELETE FROM meta WHERE key = 'fingerprint'")
        }
    }

    // MARK: - Entry model

    /// One decoded assistant turn. Compact by design: the durable cache holds these, and the
    /// in-process copy exists only between a scan and its aggregation.
    struct Entry: Codable, Equatable, Sendable {
        let createdMs: Int64
        let costUSD: Double
        /// The model OpenCode recorded for the turn; empty when unattributed.
        let modelID: String
        let totalTokens: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let reasoningTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
    }

    struct CachedEntries: Equatable, Sendable {
        let entries: [Entry]
        let fingerprint: DatabaseFingerprint

        func matchesCurrentDatabase(at url: URL) -> Bool {
            guard let current = DatabaseFingerprint.current(for: url) else { return false }
            return current == self.fingerprint
        }
    }

    // MARK: - Windowing

    /// Buckets entries into calendar-day rows keyed by the reporting calendar, matching how
    /// native Codex history is keyed, so they merge consistently with it. Windowing happens
    /// here, at read time, from compact entries — the store never retains a pre-windowed
    /// report.
    static func windowedReport(
        entries: [Entry],
        since: Date,
        until: Date,
        calendar: Calendar) -> CostUsageDailyReport?
    {
        // Normalize the lower bound to the reporting day's start: the foreground scan passes
        // a `now`-anchored window, and a clock-time bound would drop earlier-today turns.
        let sinceStartMs = Int64(calendar.startOfDay(for: since).timeIntervalSince1970 * 1000)
        let untilMs = Int64(until.timeIntervalSince1970 * 1000)
        var dayEntries: [String: CostUsageDailyReport.Entry] = [:]
        for entry in entries {
            guard entry.createdMs >= sinceStartMs, entry.createdMs <= untilMs else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(entry.createdMs) / 1000)
            let key = CostUsageScanner.CostUsageDayRange.dayKey(from: date, calendar: calendar)
            let day = dayEntries[key] ?? CostUsageDailyReport.Entry(
                date: key,
                inputTokens: 0,
                outputTokens: 0,
                totalTokens: 0,
                requestCount: 0,
                costUSD: 0,
                modelsUsed: [],
                modelBreakdowns: [],
                costIsSourceRecorded: true)
            let breakdown = Self.breakdown(for: entry, existing: day.modelBreakdowns ?? [])
            dayEntries[key] = CostUsageDailyReport.Entry(
                date: key,
                inputTokens: Self.sum(day.inputTokens, entry.inputTokens),
                outputTokens: Self.sum(day.outputTokens, entry.outputTokens),
                cacheReadTokens: Self.sum(day.cacheReadTokens, entry.cacheReadTokens),
                cacheCreationTokens: Self.sum(day.cacheCreationTokens, entry.cacheCreationTokens),
                reasoningTokens: Self.sum(day.reasoningTokens, entry.reasoningTokens),
                totalTokens: Self.totalSum(day.totalTokens, entry.totalTokens),
                requestCount: (day.requestCount ?? 0) + 1,
                costUSD: (day.costUSD ?? 0) + entry.costUSD,
                modelsUsed: Array((day.modelsUsed ?? []) + [breakdown.modelName]).sorted(),
                modelBreakdowns: (day.modelBreakdowns ?? [])
                    .filter { $0.modelName != breakdown.modelName } + [breakdown],
                // The cost comes from OpenCode's own records, not list-price estimation.
                costIsSourceRecorded: true)
        }
        guard !dayEntries.isEmpty else { return nil }
        return CostUsageDailyReport(
            data: dayEntries.values.sorted { $0.date < $1.date },
            summary: nil)
    }

    private static func breakdown(
        for entry: Entry,
        existing: [CostUsageDailyReport.ModelBreakdown]) -> CostUsageDailyReport.ModelBreakdown
    {
        let trimmed = entry.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseModel = trimmed.isEmpty ? "unknown" : trimmed
        // Keep the source visible (#3273 contract): rows stay identifiable as OpenCode
        // local history in UI model breakdowns and CLI JSON instead of silently merging
        // into native model totals.
        let model = "\(baseModel) (OpenCode local)"
        if let match = existing.first(where: { $0.modelName == model }) {
            return CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: (match.costUSD ?? 0) + entry.costUSD,
                totalTokens: Self.totalSum(match.totalTokens, entry.totalTokens),
                requestCount: (match.requestCount ?? 0) + 1,
                inputTokens: Self.sum(match.inputTokens, entry.inputTokens),
                outputTokens: Self.sum(match.outputTokens, entry.outputTokens),
                cacheReadTokens: Self.sum(match.cacheReadTokens, entry.cacheReadTokens),
                cacheCreationTokens: Self.sum(match.cacheCreationTokens, entry.cacheCreationTokens),
                reasoningTokens: Self.sum(match.reasoningTokens, entry.reasoningTokens))
        }
        return CostUsageDailyReport.ModelBreakdown(
            modelName: model,
            costUSD: entry.costUSD,
            totalTokens: entry.totalTokens,
            requestCount: 1,
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens,
            reasoningTokens: entry.reasoningTokens)
    }

    /// The day's total is conservatively unknown when any contributing turn lacks one,
    /// mirroring how native Codex history aggregates days with mixed token evidence.
    private static func totalSum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let l = lhs, let r = rhs else { return nil }
        let (total, overflow) = l.addingReportingOverflow(r)
        return overflow ? nil : total
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (l?, r?):
            let (total, overflow) = l.addingReportingOverflow(r)
            return overflow ? nil : total
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    // MARK: - Durable cache

    private func readCachedEntries() throws -> CachedEntries? {
        guard FileManager.default.fileExists(atPath: self.cacheURL.path) else { return nil }
        return try CacheDatabase.withDatabase(at: self.cacheURL) { db in
            guard let payload = try CacheDatabase.stringValue(db, "SELECT payload FROM entries LIMIT 1"),
                  let data = Data(base64Encoded: payload),
                  let entries = try? JSONDecoder().decode([Entry].self, from: data),
                  let fingerprintJSON = try CacheDatabase.stringValue(
                      db,
                      "SELECT value FROM meta WHERE key = 'fingerprint'"),
                  let fingerprintData = Data(base64Encoded: fingerprintJSON),
                  let fingerprint = try? JSONDecoder().decode(DatabaseFingerprint.self, from: fingerprintData)
            else { return nil }
            return CachedEntries(entries: entries, fingerprint: fingerprint)
        }
    }

    private func persist(entries: [Entry]) throws {
        let payload = try JSONEncoder().encode(entries).base64EncodedString()
        let fingerprint = DatabaseFingerprint.current(for: self.databaseURL)
        try CacheDatabase.withDatabase(at: self.cacheURL) { db in
            try CacheDatabase.execute(db, "BEGIN IMMEDIATE")
            try CacheDatabase.execute(db, "DELETE FROM entries")
            try CacheDatabase.execute(
                db,
                "INSERT INTO entries (ordinal, payload) VALUES (0, '\(payload)')")
            try CacheDatabase.execute(db, "DELETE FROM meta WHERE key = 'fingerprint'")
            if let fingerprint {
                let json = try JSONEncoder().encode(fingerprint).base64EncodedString()
                try CacheDatabase.execute(
                    db,
                    "INSERT INTO meta (key, value) VALUES ('fingerprint', '\(json)')")
            }
            try CacheDatabase.execute(db, "COMMIT")
        }
    }

    // MARK: - Database fingerprint

    /// Mirrors the OpenCode Go reader's fingerprint: the main database plus its WAL sidecar,
    /// so WAL appends invalidate the cache without a checkpoint.
    struct DatabaseFingerprint: Codable, Equatable, Sendable {
        let path: String
        let size: UInt64
        let modificationDate: Date
        let walSize: UInt64?
        let walModificationDate: Date?

        static func current(for url: URL) -> Self? {
            let url = url.resolvingSymlinksInPath()
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? UInt64,
                  let mtime = attrs[.modificationDate] as? Date
            else { return nil }
            let walAttrs = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
            return Self(
                path: url.path,
                size: size,
                modificationDate: mtime,
                walSize: walAttrs?[.size] as? UInt64,
                walModificationDate: walAttrs?[.modificationDate] as? Date)
        }
    }

    // MARK: - Environment resolution

    /// Resolves the XDG data root the way OpenCode's `xdg-basedir` dependency does: an
    /// absolute `XDG_DATA_HOME` wins; relative or missing values fall back to `~/.local/share`.
    static func xdgDataRoot(homeDirectory: URL, environment: [String: String]) -> URL {
        if let raw = Self.cleaned(environment["XDG_DATA_HOME"]),
           raw.hasPrefix("/")
        {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
    }

    /// Resolves the single database OpenCode itself would use, mirroring upstream
    /// `database.path()`: `OPENCODE_DB` selects exactly one database (`:memory:` is in-memory
    /// history an on-disk reader cannot see; absolute paths win as-is; relative names resolve
    /// inside the data directory) and is never substituted with another database. Without an
    /// explicit selection, upstream derives the channel from a build-time constant, which an
    /// external reader cannot observe — release channels and the
    /// `OPENCODE_DISABLE_CHANNEL_DB` opt-out all select the plain database, so that is the
    /// contract's selection here. Non-release channel databases stay reachable through
    /// `OPENCODE_DB`, exactly like pointing OpenCode itself at them.
    static func primaryDatabaseURL(
        dataDirectory: URL,
        environment: [String: String]) -> URL
    {
        if let override = Self.cleaned(environment["OPENCODE_DB"]) {
            if override == ":memory:" {
                return dataDirectory.appendingPathComponent("unreachable-memory-db", isDirectory: false)
            }
            if override.hasPrefix("/") {
                return URL(fileURLWithPath: override)
            }
            return dataDirectory.appendingPathComponent(override, isDirectory: false)
        }
        return dataDirectory.appendingPathComponent("opencode.db", isDirectory: false)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if canImport(SQLite3) || canImport(CSQLite3)

// MARK: - SQLite helpers

enum CacheDatabase {
    static func withDatabase<T>(at url: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, db != nil else {
            let failure = OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: openResult)
            if let db {
                _ = sqlite3_close(db)
            }
            throw failure
        }
        defer { _ = sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        try Self.execute(db, """
            CREATE TABLE IF NOT EXISTS entries (
              ordinal INTEGER PRIMARY KEY,
              payload TEXT NOT NULL
            )
            """)
        try Self.execute(db, """
            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
            """)
        return try body(db)
    }

    static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: sqlite3_errcode(db))
        }
    }

    static func stringValue(_ db: OpaquePointer?, _ sql: String) throws -> String? {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}

struct OpenCodeLocalHistorySQLiteFailure: Error {
    let code: Int32
    let message: String

    init(db: OpaquePointer?, resultCode: Int32) {
        self.code = resultCode
        self.message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite failure"
    }
}

// MARK: - OpenCode database decoding

extension OpenCodeLocalHistoryStore {
    /// Reads the matched rows from the OpenCode database. `nil` when the database exists but
    /// holds no matching rows; only genuine SQLite read failures throw.
    func decodeEntries() throws -> [Entry]? {
        do {
            return try self.decodeEntries(immutable: false)
        } catch let failure as OpenCodeLocalHistorySQLiteFailure {
            // A clean WAL shutdown can remove both sidecars while leaving the database header
            // in WAL mode. Immutable mode reads that idle main file without recreating the
            // sidecars; active WALs stay on the normal path.
            guard failure.code == SQLITE_CANTOPEN, Self.walSidecarsAreMissing(at: self.databaseURL) else {
                throw failure
            }
            return try self.decodeEntries(immutable: true)
        }
    }

    private static func walSidecarsAreMissing(at url: URL) -> Bool {
        let wal = url.appendingPathExtension("wal").path
        let shm = url.appendingPathExtension("shm").path
        return !FileManager.default.fileExists(atPath: wal) && !FileManager.default.fileExists(atPath: shm)
    }

    private func decodeEntries(immutable: Bool) throws -> [Entry]? {
        var db: OpaquePointer?
        let filename = immutable
            ? "\(self.databaseURL.absoluteURL.absoluteString)?immutable=1"
            : self.databaseURL.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &db, flags, nil)
        guard openResult == SQLITE_OK, db != nil else {
            let failure = OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: openResult)
            if let db {
                _ = sqlite3_close(db)
            }
            throw failure
        }
        defer { _ = sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let hasMessage = Self.tableExists(db, "message")
        let hasParts = Self.tableExists(db, "part")
        let hasSessionMessages = Self.tableExists(db, "session_message")
        guard hasMessage || hasSessionMessages else {
            // An idle WAL database with removed sidecars fails table detection with CANTOPEN
            // before any query runs. Probe readability so that case surfaces as a failure the
            // immutable fallback can handle, while a readable database without our tables
            // reads as empty history rather than an error.
            try Self.assertReadable(db)
            return nil
        }

        var statements: [String] = []
        if hasMessage {
            statements.append(hasParts ? Self.messageAndPartUsageSQL : Self.messageOnlyUsageSQL)
        }
        if hasSessionMessages {
            statements.append(Self.sessionMessageUsageSQL(hasLegacyMessages: hasMessage))
        }
        let sql = statements.joined(separator: "\nUNION ALL\n")

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }

        var entries: [Entry] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: step)
            }
            let createdMs = sqlite3_column_int64(stmt, 0)
            let cost = sqlite3_column_double(stmt, 1)
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            let model = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let tokens = sqlite3_column_text(stmt, 3).flatMap { json in
                try? JSONDecoder().decode(TokenCounts.self, from: Data(String(cString: json).utf8))
            }
            let resolved = tokens.flatMap { $0.isValid ? $0 : nil }
            entries.append(Entry(
                createdMs: createdMs,
                costUSD: cost,
                modelID: model,
                totalTokens: resolved?.resolvedTotal,
                inputTokens: resolved?.input,
                outputTokens: resolved?.output,
                reasoningTokens: resolved?.reasoning,
                cacheReadTokens: resolved?.cache?.read,
                cacheCreationTokens: resolved?.cache?.write))
        }
        return entries
    }

    private static func tableExists(_ db: OpaquePointer?, _ table: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(table)'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { _ = sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func assertReadable(_ db: OpaquePointer?) throws {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: prepareResult)
        }
        defer { _ = sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW || step == SQLITE_DONE else {
            throw OpenCodeLocalHistorySQLiteFailure(db: db, resultCode: step)
        }
    }

    /// Legacy `message` rows for the selected provider, as a reusable projection.
    private static let providerMessagesSQL = """
        SELECT
          id AS messageID,
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost,
          json_type(data, '$.cost') IN ('integer', 'real') AS hasCost,
          COALESCE(json_extract(data, '$.modelID'), '') AS modelID,
          CASE WHEN json_type(data, '$.tokens') = 'object'
            THEN json_extract(data, '$.tokens') END AS tokens
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') = 'openai'
          AND json_extract(data, '$.role') = 'assistant'
    """

    /// Message-level totals only, for databases without a `part` table.
    private static let messageOnlyUsageSQL = """
        SELECT createdMs, cost, modelID, tokens
        FROM (\(Self.providerMessagesSQL))
        WHERE hasCost
    """

    /// Valid `step-finish` parts win; the message fallback contributes only when a message
    /// has no valid part, so a message is never counted twice.
    private static let messageAndPartUsageSQL = """
        WITH provider_messages AS (\(Self.providerMessagesSQL))
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            AS createdMs,
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
          m.modelID AS modelID,
          CASE WHEN json_type(p.data, '$.tokens') = 'object'
            THEN json_extract(p.data, '$.tokens') END AS tokens
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        UNION ALL
        SELECT createdMs, cost, modelID, tokens
        FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (
            SELECT 1
            FROM part p
            WHERE p.message_id = m.messageID
              AND json_valid(p.data)
              AND json_extract(p.data, '$.type') = 'step-finish'
              AND json_type(p.data, '$.cost') IN ('integer', 'real')
          )
    """

    /// OpenCode v2 writes new turns to `session_message` and copies older turns there under
    /// the same IDs, so v2 rows only add IDs the legacy `message` table does not already hold.
    private static func sessionMessageUsageSQL(hasLegacyMessages: Bool) -> String {
        let legacyExclusion = hasLegacyMessages
            ? "\n  AND NOT EXISTS (SELECT 1 FROM message m WHERE m.id = s.id)"
            : ""
        return """
            SELECT
              CAST(COALESCE(json_extract(s.data, '$.time.created'), s.time_created) AS INTEGER) AS createdMs,
              CAST(json_extract(s.data, '$.cost') AS REAL) AS cost,
              COALESCE(json_extract(s.data, '$.model.id'), '') AS modelID,
              CASE WHEN json_type(s.data, '$.tokens') = 'object'
                THEN json_extract(s.data, '$.tokens') END AS tokens
            FROM session_message s
            WHERE s.type = 'assistant'
              AND json_valid(s.data)
              AND json_extract(s.data, '$.model.providerID') = 'openai'
              AND json_type(s.data, '$.cost') IN ('integer', 'real')\(legacyExclusion)
            """
    }

    private struct TokenCounts: Decodable {
        struct Cache: Decodable {
            let read: Int?
            let write: Int?
        }

        let total: Int?
        let input: Int?
        let output: Int?
        let reasoning: Int?
        let cache: Cache?

        private var components: [Int?] {
            [self.input, self.output, self.reasoning, self.cache?.read, self.cache?.write]
        }

        var resolvedTotal: Int? {
            // OpenCode separates output from reasoning and input from cache counts.
            self.total ?? (self.components.allSatisfy { $0 != nil }
                ? Self.checkedSum(self.components.compactMap(\.self)) : nil)
        }

        var isValid: Bool {
            (self.components + [self.total]).allSatisfy { ($0 ?? 0) >= 0 } && self.resolvedTotal != nil
        }

        private static func checkedSum(_ values: [Int]) -> Int? {
            var total = 0
            for value in values {
                let (partial, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { return nil }
                total = partial
            }
            return total
        }
    }
}

#else

extension OpenCodeLocalHistoryStore {
    func decodeEntries() throws -> [Entry]? { nil }
}

#endif
