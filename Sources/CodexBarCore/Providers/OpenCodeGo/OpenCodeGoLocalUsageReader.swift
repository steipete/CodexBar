import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

public enum OpenCodeGoLocalUsageError: LocalizedError, Sendable, Equatable {
    case notDetected
    case historyUnavailable(String)
    case sqliteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notDetected:
            "OpenCode Go not detected. Log in with OpenCode Go or use it locally first."
        case let .historyUnavailable(message):
            "OpenCode Go local usage history is unavailable: \(message)"
        case let .sqliteFailed(message):
            "SQLite error reading OpenCode Go usage: \(message)"
        }
    }
}

public struct OpenCodeGoLocalUsageReader: Sendable {
    private static let fiveHours: TimeInterval = 5 * 60 * 60
    private static let week: TimeInterval = 7 * 24 * 60 * 60
    private static let limits = (session: 12.0, weekly: 30.0, monthly: 60.0)

    private static let sharedCache = CacheBox()
    private let cache: CacheBox
    private let authURL: URL
    private let databaseURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let openCodeDirectory = homeDirectory.appendingPathComponent(".local/share/opencode", isDirectory: true)
        self.cache = Self.sharedCache
        self.authURL = openCodeDirectory.appendingPathComponent("auth.json", isDirectory: false)
        self.databaseURL = openCodeDirectory.appendingPathComponent("opencode.db", isDirectory: false)
    }

    public init(authURL: URL, databaseURL: URL) {
        self.cache = CacheBox()
        self.authURL = authURL
        self.databaseURL = databaseURL
    }

    #if DEBUG
    @TaskLocal static var scanObserverForTesting: (@Sendable () -> Void)?
    #endif

    public func fetch(
        now: Date = Date(),
        historyDays: Int = 30,
        calendar: Calendar = .current) throws -> OpenCodeGoUsageSnapshot
    {
        let hasAuth = Self.hasAuthKey(at: self.authURL)
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            if hasAuth {
                throw OpenCodeGoLocalUsageError.historyUnavailable("database not found")
            }
            throw OpenCodeGoLocalUsageError.notDetected
        }

        let rows = try self.cache.read(at: self.databaseURL) { try self.readRows() }
        guard !rows.isEmpty else {
            throw hasAuth ? OpenCodeGoLocalUsageError.historyUnavailable("no local usage rows") : .notDetected
        }
        return Self.snapshot(rows: rows, now: now, historyDays: historyDays, calendar: calendar)
    }

    private func readRows() throws -> [UsageRow] {
        #if DEBUG
        Self.scanObserverForTesting?()
        #endif
        return try self.withDatabase { try self.readRows(db: $0) }
    }

    private func withDatabase<T>(_ read: (OpaquePointer?) throws -> T) throws -> T {
        let url = self.databaseURL.resolvingSymlinksInPath()
        func open(immutable: Bool) throws -> T {
            var db: OpaquePointer?
            let filename = immutable ? "\(url.absoluteURL.absoluteString)?immutable=1" : url.path
            let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
            let result = sqlite3_open_v2(filename, &db, flags, nil)
            defer { sqlite3_close(db) }
            guard result == SQLITE_OK else { throw Self.sqliteFailure(db: db, resultCode: result) }
            sqlite3_busy_timeout(db, 250)
            return try read(db)
        }
        do {
            return try open(immutable: false)
        } catch let failure as SQLiteReadFailure {
            // A clean WAL shutdown can remove both sidecars while leaving the header in WAL mode.
            // Never bypass an active or unreadable WAL, including when the database is a symlink.
            guard failure.code == SQLITE_CANTOPEN,
                  (try? Self.fileExists(at: URL(fileURLWithPath: url.path + "-wal"))) == false,
                  (try? Self.fileExists(at: URL(fileURLWithPath: url.path + "-shm"))) == false
            else { throw OpenCodeGoLocalUsageError.sqliteFailed(failure.message) }
            do {
                return try open(immutable: true)
            } catch let fallbackFailure as SQLiteReadFailure {
                throw OpenCodeGoLocalUsageError.sqliteFailed(fallbackFailure.message)
            }
        }
    }

    private func readRows(db: OpaquePointer?) throws -> [UsageRow] {
        let hasMessages = try Self.hasTable(named: "message", db: db)
        let hasParts = try Self.hasTable(named: "part", db: db)
        let hasV2 = try Self.hasTable(named: "session_message", db: db)
        guard hasMessages || hasV2 else { throw Self.sqliteFailure(db: db, resultCode: SQLITE_ERROR) }
        let legacySQL = hasMessages
            ? (hasParts ? Self.messageAndPartUsageSQL
                : "SELECT createdMs, cost, modelID, tokens, messageID FROM (\(Self.providerMessagesSQL)) WHERE hasCost")
            : "SELECT NULL AS createdMs, NULL AS cost, NULL AS modelID, NULL AS tokens, NULL AS messageID WHERE 0"
        // Deduplicate only usable legacy costs; malformed copies must not hide a valid v2 request.
        // Let SQLite inline the shared queries instead of materializing another copy of the selected history.
        let sql = """
        WITH legacy_usage AS NOT MATERIALIZED (\(legacySQL))
        SELECT * FROM legacy_usage
        \(hasV2 ? Self.sessionMessageUsageSQL : "")
        """

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [UsageRow] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(stmt) }
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
        guard step == SQLITE_DONE else { throw Self.sqliteFailure(db: db, resultCode: step) }
        return rows
    }

    private static func sqliteFailure(db: OpaquePointer?, resultCode: Int32) -> SQLiteReadFailure {
        SQLiteReadFailure(
            code: db.map { sqlite3_errcode($0) } ?? resultCode,
            message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }

    private static func hasTable(named name: String, db: OpaquePointer?) throws -> Bool {
        let result = sqlite3_table_column_metadata(db, nil, name, nil, nil, nil, nil, nil, nil)
        switch result {
        case SQLITE_OK: return true
        case SQLITE_ERROR: return false
        default: throw Self.sqliteFailure(db: db, resultCode: result)
        }
    }

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
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND json_extract(data, '$.role') = 'assistant'
    """

    private static let messageAndPartUsageSQL = """
        WITH provider_messages AS (\(Self.providerMessagesSQL)), provider_parts AS NOT MATERIALIZED (
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            AS createdMs,
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
          m.modelID AS modelID,
          CASE WHEN json_type(p.data, '$.tokens') = 'object'
            THEN json_extract(p.data, '$.tokens') END AS tokens,
          m.messageID AS messageID
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        )
        SELECT * FROM provider_parts
        UNION ALL
        SELECT createdMs, cost, modelID, tokens, messageID
        FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (
            SELECT 1
            FROM provider_parts p
            WHERE p.messageID = m.messageID
          )
    """

    private static let sessionMessageUsageSQL = """
        UNION ALL
        SELECT
          CAST(COALESCE(json_extract(s.data, '$.time.created'), s.time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(s.data, '$.cost') AS REAL) AS cost,
          COALESCE(json_extract(s.data, '$.model.id'), '') AS modelID,
          CASE WHEN json_type(s.data, '$.tokens') = 'object'
            THEN json_extract(s.data, '$.tokens') END AS tokens,
          s.id AS messageID
        FROM session_message s
        WHERE s.type IN ('assistant', 'compaction')
          AND json_valid(s.data)
          AND json_extract(s.data, '$.model.providerID') = 'opencode-go'
          AND json_type(s.data, '$.cost') IN ('integer', 'real')
          AND NOT EXISTS (
            SELECT 1 FROM legacy_usage m WHERE m.messageID = s.id
              AND m.createdMs > 0 AND m.cost BETWEEN 0 AND \(Double.greatestFiniteMagnitude))
    """

    private struct DatabaseFingerprint: Equatable {
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

    private final class CacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (fingerprint: DatabaseFingerprint, rows: [UsageRow])?

        func read(at url: URL, scan: () throws -> [UsageRow]) rethrows -> [UsageRow] {
            self.lock.lock()
            defer { self.lock.unlock() }
            let fingerprint = DatabaseFingerprint.current(for: url)
            if let fingerprint, let entry = self.entry, entry.fingerprint == fingerprint {
                return entry.rows
            }
            self.entry = nil
            let rows = try scan()
            // Keep exact timestamps for moving windows, but retain at most one 4 MiB row payload.
            // Large histories still work; they simply do not stay resident between scans.
            if let fingerprint, DatabaseFingerprint.current(for: url) == fingerprint,
               rows.count <= 4 * 1024 * 1024 / MemoryLayout<UsageRow>.stride,
               rows.reduce(0, { $0 + MemoryLayout<UsageRow>.stride + $1.model.utf8.count }) <= 4 * 1024 * 1024
            {
                self.entry = (fingerprint, rows)
            }
            return rows
        }
    }

    private struct UsageRow {
        let createdMs: Int64
        let cost: Double
        /// The underlying model behind the `opencode-go` Zen proxy; empty when unattributed.
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
                ? CheckedSum.integers(self.components.compactMap(\.self)) : nil)
        }

        var isValid: Bool {
            (self.components + [self.total]).allSatisfy { ($0 ?? 0) >= 0 } && self.resolvedTotal != nil
        }
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let message: String
    }

    private static func hasAuthKey(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String
        else {
            return false
        }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func snapshot(
        rows: [UsageRow],
        now: Date,
        historyDays: Int,
        calendar: Calendar) -> OpenCodeGoUsageSnapshot
    {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let sessionStart = nowMs - Int64(Self.fiveHours * 1000)
        let weekStartMs = Int64(self.startOfUTCWeek(now: now).timeIntervalSince1970 * 1000)
        let weekEndMs = weekStartMs + Int64(Self.week * 1000)
        let monthBounds = self.monthBounds(now: now, anchorMs: rows.lazy.map(\.createdMs).min())

        var sessionCost = 0.0
        var weeklyCost = 0.0
        var monthlyCost = 0.0
        var oldestSessionMs = nowMs
        for row in rows {
            if row.createdMs >= sessionStart, row.createdMs < nowMs {
                sessionCost += row.cost
                oldestSessionMs = min(oldestSessionMs, row.createdMs)
            }
            if row.createdMs >= weekStartMs, row.createdMs < weekEndMs {
                weeklyCost += row.cost
            }
            if row.createdMs >= monthBounds.startMs, row.createdMs < monthBounds.endMs {
                monthlyCost += row.cost
            }
        }
        let rollingResetInSec = max(0, Int((oldestSessionMs + Int64(Self.fiveHours * 1000) - nowMs) / 1000))

        return OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: self.percent(used: sessionCost, limit: self.limits.session),
            weeklyUsagePercent: self.percent(used: weeklyCost, limit: self.limits.weekly),
            monthlyUsagePercent: self.percent(used: monthlyCost, limit: self.limits.monthly),
            rollingResetInSec: rollingResetInSec,
            weeklyResetInSec: max(0, Int((weekEndMs - nowMs) / 1000)),
            monthlyResetInSec: max(0, Int((monthBounds.endMs - nowMs) / 1000)),
            daily: self.dailyEntries(rows: rows, now: now, historyDays: historyDays, calendar: calendar),
            updatedAt: now)
    }

    /// Buckets local `opencode-go` costs in the requested calendar, defaulting to device-local days.
    private static func dailyEntries(
        rows: [UsageRow],
        now: Date,
        historyDays: Int,
        calendar: Calendar) -> [CostUsageDailyReport.Entry]
    {
        guard let since = calendar.date(byAdding: .day, value: -(max(1, historyDays) - 1), to: now) else {
            return []
        }
        let sinceStartOfDay = calendar.startOfDay(for: since)

        let entries: [CostUsageDailyReport.Entry] = rows.compactMap { row in
            let date = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
            guard date >= sinceStartOfDay, date <= now else { return nil }
            let key = CostUsageScanner.CostUsageDayRange.dayKey(from: date, calendar: calendar)
            let trimmedModel = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = trimmedModel.isEmpty ? "unknown" : trimmedModel
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
                modelBreakdowns: [breakdown])
        }
        return CostUsageDailyReport.merged([.init(data: entries, summary: nil)], calendar: calendar).data
    }

    private static func percent(used: Double, limit: Double) -> Double {
        guard used.isFinite, limit > 0 else { return 0 }
        let value = max(0, min(100, used / limit * 100))
        return (value * 10).rounded() / 10
    }

    private static func startOfUTCWeek(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return calendar.date(from: components) ?? now
    }

    private static func monthBounds(now: Date, anchorMs: Int64?) -> (startMs: Int64, endMs: Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current

        guard let anchorMs else {
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
        }

        let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMs) / 1000)
        let anchorComponents = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor)

        var startMonthComponents = calendar.dateComponents([.year, .month], from: now)
        var start = self.anchoredMonth(calendar: calendar, month: startMonthComponents, anchor: anchorComponents)
        if start > now, let previous = calendar.date(byAdding: .month, value: -1, to: start) {
            startMonthComponents = calendar.dateComponents([.year, .month], from: previous)
            start = self.anchoredMonth(calendar: calendar, month: startMonthComponents, anchor: anchorComponents)
        }
        let end = self.anchoredMonth(
            calendar: calendar,
            month: self.monthComponents(after: startMonthComponents, calendar: calendar),
            anchor: anchorComponents)
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    private static func monthComponents(after month: DateComponents, calendar: Calendar) -> DateComponents {
        let monthStart = calendar.date(from: month) ?? Date()
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        return calendar.dateComponents([.year, .month], from: nextMonth)
    }

    private static func anchoredMonth(
        calendar: Calendar,
        month: DateComponents,
        anchor: DateComponents) -> Date
    {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = month.year
        components.month = month.month
        components.day = anchor.day
        components.hour = anchor.hour
        components.minute = anchor.minute
        components.second = anchor.second
        components.nanosecond = anchor.nanosecond

        if let date = calendar.date(from: components),
           calendar.component(.month, from: date) == month.month
        {
            return date
        }

        components.day = calendar.range(of: .day, in: .month, for: calendar.date(from: month) ?? Date())?.count
        return calendar.date(from: components) ?? Date()
    }
}

extension OpenCodeGoLocalUsageReader {
    static func loadCLICredential(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()) throws -> String?
    {
        let dataHome = environment["XDG_DATA_HOME"].flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        } ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        // Provider-specific by design: Go uses the OpenCode CLI's existing credential store.
        let directory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        let filename = environment["OPENCODE_DB"] ?? "opencode.db"
        guard filename != ":memory:" else { return nil }
        let database = filename.hasPrefix("/") ? URL(fileURLWithPath: filename)
            : directory.appendingPathComponent(filename)
        return try Self(authURL: directory.appendingPathComponent("auth.json"), databaseURL: database)
            .loadCLICredential(now: now)
    }

    func loadCLICredential(now: Date = Date()) throws -> String? {
        do {
            guard try Self.fileExists(at: self.databaseURL) else { return try self.legacyCredential() }
            return try self.withDatabase { db in
                guard try Self.hasTable(named: "credential", db: db) else {
                    return try self.legacyCredential()
                }
                return try Self.activeCredential(db: db, now: now)
            }
        } catch {
            // Do not expose database contents, tokens, or decoding diagnostics in a user-facing error.
            throw OpenCodeGoUsageError.invalidCredentials
        }
    }

    private static func activeCredential(db: OpaquePointer?, now: Date) throws -> String? {
        let sql = """
        SELECT integration_id, value FROM credential
        WHERE active = 1 AND integration_id IN ('opencode-go', 'opencode')
        ORDER BY CASE integration_id WHEN 'opencode-go' THEN 0 ELSE 1 END
        LIMIT 2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(statement) }
        let first = sqlite3_step(statement)
        if first == SQLITE_DONE { return nil }
        guard first == SQLITE_ROW, let integration = sqlite3_column_text(statement, 0),
              sqlite3_column_type(statement, 1) == SQLITE_TEXT,
              let bytes = sqlite3_column_blob(statement, 1)
        else { throw OpenCodeGoUsageError.invalidCredentials }
        let selectedIntegration = String(cString: integration)
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        // Two active rows for the chosen integration are ambiguous; never pick an arbitrary account.
        let next = sqlite3_step(statement)
        guard next == SQLITE_DONE || (next == SQLITE_ROW &&
            sqlite3_column_text(statement, 0).map { String(cString: $0) } != selectedIntegration)
        else { throw OpenCodeGoUsageError.invalidCredentials }
        let credential = try JSONDecoder().decode(CLICredential.self, from: data)
        switch credential.type {
        case "key":
            return try Self.credentialToken(credential.key)
        case "oauth":
            guard let expires = credential.expires, expires.isFinite, expires >= 0,
                  expires.rounded(.towardZero) == expires, expires / 1000 > now.timeIntervalSince1970
            else { throw OpenCodeGoUsageError.invalidCredentials }
            return try Self.credentialToken(credential.access)
        default:
            throw OpenCodeGoUsageError.invalidCredentials
        }
    }

    private func legacyCredential() throws -> String? {
        guard try Self.fileExists(at: self.authURL) else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: self.authURL))
        guard let entries = object as? [String: Any] else { throw OpenCodeGoUsageError.invalidCredentials }
        guard let entry = entries["opencode-go"] else { return nil }
        guard let value = entry as? [String: Any] else { throw OpenCodeGoUsageError.invalidCredentials }
        guard value["type"] as? String == "api" else { return nil }
        return try Self.credentialToken(value["key"] as? String)
    }

    private static func credentialToken(_ value: String?) throws -> String {
        guard let value, !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { throw OpenCodeGoUsageError.invalidCredentials }
        return value
    }

    private static func fileExists(at url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private struct CLICredential: Decodable {
        let type: String
        let key: String?
        let access: String?
        let expires: Double?
    }
}
