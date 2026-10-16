import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)

/// Reads machine-local OpenCode usage metadata for assistant records whose provider is
/// exactly `openai`, so Codex-origin traffic generated through OpenCode can appear in the
/// ambient Codex menu/CLI history.
///
/// Contract (see issue #3273):
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
public struct OpenCodeLocalUsageReader: Sendable {
    private let databaseURLs: [URL]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        let dataRoot = Self.xdgDataRoot(homeDirectory: homeDirectory, environment: environment)
        let openCodeDirectory = dataRoot.appendingPathComponent("opencode", isDirectory: true)
        self.databaseURLs = Self.candidateDatabaseURLs(dataDirectory: openCodeDirectory, environment: environment)
    }

    public init(databaseURLs: [URL]) {
        self.databaseURLs = databaseURLs
    }

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
    /// explicit selection, upstream derives the channel from a build-time constant
    /// (`InstallationChannel`), which an external reader cannot observe — release channels
    /// (`latest`/`beta`/`prod`) and the `OPENCODE_DISABLE_CHANNEL_DB` opt-out both select the
    /// plain database, so that is the contract's selection here. Non-release channel
    /// databases stay reachable through `OPENCODE_DB`, exactly like pointing OpenCode itself
    /// at them.
    public static func candidateDatabaseURLs(
        dataDirectory: URL,
        environment: [String: String]) -> [URL]
    {
        if let override = Self.cleaned(environment["OPENCODE_DB"]) {
            if override == ":memory:" {
                return []
            }
            if override.hasPrefix("/") {
                return [URL(fileURLWithPath: override)]
            }
            return [dataDirectory.appendingPathComponent(override, isDirectory: false)]
        }
        return [dataDirectory.appendingPathComponent("opencode.db", isDirectory: false)]
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A daily report built from the matched rows. The report is `nil` when no candidate
    /// database exists or it holds no matching rows; only genuine SQLite read failures throw,
    /// so a missing or empty OpenCode installation never disrupts the native Codex scan.
    public func loadDailyReport(since: Date, until: Date, calendar: Calendar) throws -> CostUsageDailyReport? {
        for url in self.databaseURLs {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let rows = try self.readRows(databaseURL: url), !rows.isEmpty else { continue }
            let entries = Self.dailyEntries(rows: rows, since: since, until: until, calendar: calendar)
            guard !entries.isEmpty else { continue }
            // Merge same-day entries into one entry per day, matching how native Codex
            // history is keyed, so downstream aggregation sees a single day row.
            return CostUsageDailyReport.merged(
                [CostUsageDailyReport(data: entries, summary: nil)],
                calendar: calendar)
        }
        return nil
    }

    // MARK: - SQLite

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let message: String
    }

    private func readRows(databaseURL: URL) throws -> [UsageRow]? {
        do {
            return try self.readRows(databaseURL: databaseURL, immutable: false)
        } catch let failure as SQLiteReadFailure {
            // A clean WAL shutdown can remove both sidecars while leaving the database header
            // in WAL mode. Immutable mode reads that idle main file without recreating the
            // sidecars; active WALs stay on the normal path.
            guard failure.code == SQLITE_CANTOPEN, Self.walSidecarsAreMissing(at: databaseURL) else {
                throw failure
            }
            return try self.readRows(databaseURL: databaseURL, immutable: true)
        }
    }

    private func readRows(databaseURL: URL, immutable: Bool) throws -> [UsageRow]? {
        var db: OpaquePointer?
        let filename = immutable
            ? "\(databaseURL.absoluteURL.absoluteString)?immutable=1"
            : databaseURL.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &db, flags, nil)
        guard openResult == SQLITE_OK, db != nil else {
            // sqlite3_open_v2 can return a non-null connection handle even on failure.
            // Capture the failure (it reads sqlite3_errcode/errmsg through the handle)
            // before closing, then release the handle on every failure path.
            let failure = Self.sqliteFailure(db: db, resultCode: openResult)
            if let db {
                _ = sqlite3_close(db)
            }
            throw failure
        }
        defer { sqlite3_close(db) }
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
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [UsageRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw Self.sqliteFailure(db: db, resultCode: step)
            }

            let createdMs = sqlite3_column_int64(stmt, 0)
            let cost = sqlite3_column_double(stmt, 1)
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            let model = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let tokens = sqlite3_column_text(stmt, 3).flatMap { json in
                try? JSONDecoder().decode(TokenCounts.self, from: Data(String(cString: json).utf8))
            }
            rows.append(UsageRow(
                createdMs: createdMs,
                cost: cost,
                model: model,
                tokens: tokens.flatMap { $0.isValid ? $0 : nil }))
        }
        return rows
    }

    private static func tableExists(_ db: OpaquePointer?, _ table: String) -> Bool {
        sqlite3_table_column_metadata(db, nil, table, nil, nil, nil, nil, nil, nil) == SQLITE_OK
    }

    /// Prepares a schema-touching statement so an unreadable database fails here with its
    /// real SQLite result code instead of silently reading as "no tables".
    private static func assertReadable(_ db: OpaquePointer?) throws {
        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &stmt, nil)
        guard result == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: result)
        }
        sqlite3_finalize(stmt)
    }

    private static func walSidecarsAreMissing(at url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path + "-wal") &&
            !FileManager.default.fileExists(atPath: url.path + "-shm")
    }

    private static func sqliteFailure(db: OpaquePointer?, resultCode: Int32) -> SQLiteReadFailure {
        SQLiteReadFailure(
            code: db.map { sqlite3_errcode($0) } ?? resultCode,
            message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }

    // MARK: - SQL

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

    // MARK: - Rows

    private struct UsageRow {
        let createdMs: Int64
        let cost: Double
        /// The model OpenCode recorded for the turn; empty when unattributed.
        let model: String
        let tokens: TokenCounts?
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

    /// Buckets rows into calendar-day entries keyed by the supplied reporting calendar,
    /// matching how native Codex history is keyed, so they merge consistently with it.
    private static func dailyEntries(
        rows: [UsageRow],
        since: Date,
        until: Date,
        calendar: Calendar) -> [CostUsageDailyReport.Entry]
    {
        // Normalize the lower bound to the reporting day's start: the foreground scan passes
        // a `now`-anchored window, and a clock-time bound would drop earlier-today turns.
        let sinceStartMs = Int64(calendar.startOfDay(for: since).timeIntervalSince1970 * 1000)
        let untilMs = Int64(until.timeIntervalSince1970 * 1000)
        return rows.compactMap { row in
            guard row.createdMs >= sinceStartMs, row.createdMs <= untilMs else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
            let key = CostUsageScanner.CostUsageDayRange.dayKey(from: date, calendar: calendar)
            let trimmedModel = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseModel = trimmedModel.isEmpty ? "unknown" : trimmedModel
            // Keep the source visible (#3273 contract): rows stay identifiable as OpenCode
            // local history in UI model breakdowns and CLI JSON instead of silently merging
            // into native model totals.
            let model = "\(baseModel) (OpenCode local)"
            let tokens = row.tokens
            let breakdown = CostUsageDailyReport.ModelBreakdown(
                modelName: model,
                costUSD: row.cost,
                totalTokens: tokens?.resolvedTotal,
                requestCount: 1,
                inputTokens: tokens?.input,
                outputTokens: tokens?.output,
                cacheReadTokens: tokens?.cache?.read,
                cacheCreationTokens: tokens?.cache?.write,
                reasoningTokens: tokens?.reasoning)
            return CostUsageDailyReport.Entry(
                date: key,
                inputTokens: tokens?.input,
                outputTokens: tokens?.output,
                cacheReadTokens: tokens?.cache?.read,
                cacheCreationTokens: tokens?.cache?.write,
                reasoningTokens: tokens?.reasoning,
                totalTokens: tokens?.resolvedTotal,
                requestCount: 1,
                costUSD: row.cost,
                modelsUsed: [model],
                modelBreakdowns: [breakdown],
                // The cost comes from OpenCode's own records, not list-price estimation.
                costIsSourceRecorded: true)
        }
    }
}

#else

public struct OpenCodeLocalUsageReader: Sendable {
    public init(
        homeDirectory _: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment _: [String: String] = ProcessInfo.processInfo.environment)
    {}

    public init(databaseURLs _: [URL]) {}

    public func loadDailyReport(since _: Date, until _: Date, calendar _: Calendar) throws -> CostUsageDailyReport? {
        nil
    }
}

#endif
