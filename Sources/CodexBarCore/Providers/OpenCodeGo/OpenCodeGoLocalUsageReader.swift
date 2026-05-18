import Foundation

#if os(macOS)
import SQLite3

public enum OpenCodeGoLocalUsageError: LocalizedError, Sendable, Equatable {
    case notDetected
    case sqliteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notDetected:
            "OpenCode Go not detected. Log in with OpenCode Go or use it locally first."
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

    public func fetch(now: Date = Date()) throws -> OpenCodeGoUsageSnapshot {
        let hasAuth = Self.hasAuthKey(at: self.authURL)
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            if hasAuth {
                return Self.emptySnapshot(now: now)
            }
            throw OpenCodeGoLocalUsageError.notDetected
        }

        let rows: [UsageRow]
        do {
            rows = try self.readRows()
        } catch let error as OpenCodeGoLocalUsageError {
            if hasAuth {
                return Self.emptySnapshot(now: now)
            }
            throw error
        }
        guard hasAuth || !rows.isEmpty else {
            throw OpenCodeGoLocalUsageError.notDetected
        }
        return Self.snapshot(rows: rows, now: now)
    }

    private func readRows() throws -> [UsageRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw OpenCodeGoLocalUsageError.sqliteFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
            SELECT
              CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
              CAST(json_extract(data, '$.cost') AS REAL) AS cost
            FROM message
            WHERE json_valid(data)
              AND json_extract(data, '$.providerID') = 'opencode-go'
              AND json_extract(data, '$.role') = 'assistant'
              AND json_type(data, '$.cost') IN ('integer', 'real')
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw OpenCodeGoLocalUsageError.sqliteFailed(message)
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [UsageRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                throw OpenCodeGoLocalUsageError.sqliteFailed(message)
            }

            let createdMs = sqlite3_column_int64(stmt, 0)
            let cost = sqlite3_column_double(stmt, 1)
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            rows.append(UsageRow(createdMs: createdMs, cost: cost))
        }
        return rows
    }

    private struct UsageRow {
        let createdMs: Int64
        let cost: Double
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

    private static func snapshot(rows: [UsageRow], now: Date) -> OpenCodeGoUsageSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let sessionStart = nowMs - Int64(Self.fiveHours * 1000)
        let weekStart = self.startOfUTCWeek(now: now).timeIntervalSince1970 * 1000
        let weekStartMs = Int64(weekStart)
        let weekEndMs = weekStartMs + Int64(Self.week * 1000)
        let earliestMs = rows.map(\.createdMs).min()
        let monthBounds = self.monthBounds(now: now, anchorMs: earliestMs)

        let sessionCost = self.sum(rows: rows, startMs: sessionStart, endMs: nowMs)
        let weeklyCost = self.sum(rows: rows, startMs: weekStartMs, endMs: weekEndMs)
        let monthlyCost = self.sum(rows: rows, startMs: monthBounds.startMs, endMs: monthBounds.endMs)

        return OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: true,
            rollingUsagePercent: self.percent(used: sessionCost, limit: self.limits.session),
            weeklyUsagePercent: self.percent(used: weeklyCost, limit: self.limits.weekly),
            monthlyUsagePercent: self.percent(used: monthlyCost, limit: self.limits.monthly),
            rollingResetInSec: self.rollingReset(rows: rows, nowMs: nowMs),
            weeklyResetInSec: max(0, Int((weekEndMs - nowMs) / 1000)),
            monthlyResetInSec: max(0, Int((monthBounds.endMs - nowMs) / 1000)),
            updatedAt: now)
    }

    private static func emptySnapshot(now: Date) -> OpenCodeGoUsageSnapshot {
        self.snapshot(rows: [], now: now)
    }

    private static func sum(rows: [UsageRow], startMs: Int64, endMs: Int64) -> Double {
        rows.reduce(0) { total, row in
            guard row.createdMs >= startMs, row.createdMs < endMs else { return total }
            return total + row.cost
        }
    }

    private static func percent(used: Double, limit: Double) -> Double {
        guard used.isFinite, limit > 0 else { return 0 }
        let value = max(0, min(100, used / limit * 100))
        return (value * 10).rounded() / 10
    }

    private static func rollingReset(rows: [UsageRow], nowMs: Int64) -> Int {
        let sessionStart = nowMs - Int64(Self.fiveHours * 1000)
        let oldest = rows
            .filter { $0.createdMs >= sessionStart && $0.createdMs < nowMs }
            .map(\.createdMs)
            .min() ?? nowMs
        return max(0, Int((oldest + Int64(Self.fiveHours * 1000) - nowMs) / 1000))
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
        var nowComponents = calendar.dateComponents([.year, .month], from: now)

        var start = self.anchoredMonth(calendar: calendar, month: nowComponents, anchor: anchorComponents)
        if start > now {
            guard let previous = calendar.date(byAdding: .month, value: -1, to: start) else {
                let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
                return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
            }
            nowComponents = calendar.dateComponents([.year, .month], from: previous)
            start = self.anchoredMonth(calendar: calendar, month: nowComponents, anchor: anchorComponents)
        }
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
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

    public func fetch(now _: Date = Date()) throws -> OpenCodeGoUsageSnapshot {
        throw OpenCodeGoLocalUsageError.notSupported
    }
}

#endif
