import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
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

    private let authURL: URL
    private let databaseURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let openCodeDirectory = homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        self.authURL = openCodeDirectory.appendingPathComponent("auth.json", isDirectory: false)
        self.databaseURL = openCodeDirectory.appendingPathComponent("opencode.db", isDirectory: false)
    }

    public init(authURL: URL, databaseURL: URL) {
        self.authURL = authURL
        self.databaseURL = databaseURL
    }

    public func fetch(now: Date = Date(), historyDays: Int = 30) throws -> OpenCodeGoUsageSnapshot {
        let hasAuth = Self.hasAuthKey(at: self.authURL)
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            if hasAuth {
                throw OpenCodeGoLocalUsageError.historyUnavailable("database not found")
            }
            throw OpenCodeGoLocalUsageError.notDetected
        }

        let rows = try self.readRows()
        guard hasAuth || !rows.isEmpty else {
            throw OpenCodeGoLocalUsageError.notDetected
        }
        guard !rows.isEmpty else {
            throw OpenCodeGoLocalUsageError.historyUnavailable("no local usage rows")
        }
        return Self.snapshot(rows: rows, now: now, historyDays: historyDays)
    }

    private func readRows() throws -> [UsageRow] {
        do {
            return try self.readRows(immutable: false)
        } catch let failure as SQLiteReadFailure {
            // A clean WAL shutdown can remove both sidecars while leaving the database header in WAL mode.
            // Immutable mode reads that idle main file without recreating sidecars; active WALs stay on the normal
            // path.
            guard failure.code == SQLITE_CANTOPEN, self.walSidecarsAreMissing else {
                throw OpenCodeGoLocalUsageError.sqliteFailed(failure.message)
            }

            do {
                return try self.readRows(immutable: true)
            } catch let fallbackFailure as SQLiteReadFailure {
                throw OpenCodeGoLocalUsageError.sqliteFailed(fallbackFailure.message)
            }
        }
    }

    private func readRows(immutable: Bool) throws -> [UsageRow] {
        var db: OpaquePointer?
        let filename = immutable ? "\(self.databaseURL.absoluteURL.absoluteString)?immutable=1" : self.databaseURL.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &db, flags, nil)
        guard openResult == SQLITE_OK else {
            let failure = Self.sqliteFailure(db: db, resultCode: openResult)
            sqlite3_close(db)
            throw failure
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = try self.hasTable(named: "part", db: db)
            ? Self.messageAndPartUsageSQL
            : "SELECT createdMs, cost, modelID, tokens FROM (\(Self.providerMessagesSQL)) WHERE hasCost"

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

    private var walSidecarsAreMissing: Bool {
        !FileManager.default.fileExists(atPath: self.databaseURL.path + "-wal") &&
            !FileManager.default.fileExists(atPath: self.databaseURL.path + "-shm")
    }

    private func hasTable(named name: String, db: OpaquePointer?) throws -> Bool {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &stmt,
            nil)
        guard prepareResult == SQLITE_OK else {
            throw Self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, transient)
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW {
            return true
        }
        guard step == SQLITE_DONE else { throw Self.sqliteFailure(db: db, resultCode: step) }
        return false
    }

    private static func sqliteFailure(db: OpaquePointer?, resultCode: Int32) -> SQLiteReadFailure {
        SQLiteReadFailure(
            code: db.map { sqlite3_errcode($0) } ?? resultCode,
            message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
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

    private static func snapshot(rows: [UsageRow], now: Date, historyDays: Int) -> OpenCodeGoUsageSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let sessionStart = nowMs - Int64(Self.fiveHours * 1000)
        let weekStart = self.startOfUTCWeek(now: now).timeIntervalSince1970 * 1000
        let weekStartMs = Int64(weekStart)
        let weekEndMs = weekStartMs + Int64(Self.week * 1000)
        let earliestMs = rows.map(\.createdMs).min()
        let monthBounds = self.monthBounds(now: now, anchorMs: earliestMs)

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
            daily: self.dailyEntries(rows: rows, now: now, historyDays: historyDays),
            updatedAt: now)
    }

    /// Buckets local `opencode-go` message costs into calendar-day entries (device local time,
    /// matching how Codex/Claude cost history is keyed) so the cost history chart can render a
    /// per-day bar chart the same way it does for those providers.
    private static func dailyEntries(
        rows: [UsageRow],
        now: Date,
        historyDays: Int) -> [CostUsageDailyReport.Entry]
    {
        let clampedHistoryDays = max(1, min(365, historyDays))
        let calendar = Calendar.current
        guard let since = calendar.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) else {
            return []
        }
        let sinceStartOfDay = calendar.startOfDay(for: since)

        let entries: [CostUsageDailyReport.Entry] = rows.compactMap { row in
            let date = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
            guard date >= sinceStartOfDay, date <= now else { return nil }
            let key = CostUsageScanner.CostUsageDayRange.dayKey(from: date)
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
        let nowComponents = calendar.dateComponents([.year, .month], from: now)

        var startMonthComponents = nowComponents
        var start = self.anchoredMonth(calendar: calendar, month: startMonthComponents, anchor: anchorComponents)
        if start > now {
            guard let previous = calendar.date(byAdding: .month, value: -1, to: start) else {
                let end = self.anchoredMonth(
                    calendar: calendar,
                    month: self.monthComponents(after: startMonthComponents, calendar: calendar),
                    anchor: anchorComponents)
                return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
            }
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

#else

public enum OpenCodeGoLocalUsageError: LocalizedError, Sendable, Equatable {
    case notSupported

    public var errorDescription: String? {
        "OpenCode Go local usage is only supported on macOS."
    }
}

public struct OpenCodeGoLocalUsageReader: Sendable {
    public init(homeDirectory _: URL = FileManager.default.homeDirectoryForCurrentUser) {}
    public init(authURL _: URL, databaseURL _: URL) {}

    public func fetch(now _: Date = Date(), historyDays _: Int = 30) throws -> OpenCodeGoUsageSnapshot {
        throw OpenCodeGoLocalUsageError.notSupported
    }
}

#endif
