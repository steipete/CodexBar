import Foundation

#if os(macOS)
import SQLite3
#endif

public enum WindsurfUsageError: LocalizedError, Sendable, Equatable {
    case unsupportedPlatform
    case dbMissing(URL)
    case sqliteFailed(String)
    case cachedPlanMissing
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Windsurf usage tracking is only supported on macOS."
        case let .dbMissing(url):
            "Windsurf data not found at \(url.path). Launch Windsurf once and sign in, then refresh."
        case let .sqliteFailed(message):
            "Failed to read Windsurf usage: \(message)"
        case .cachedPlanMissing:
            "Windsurf cached plan usage is missing. Open Windsurf, then refresh."
        case .decodeFailed:
            "Could not decode Windsurf usage. Update Windsurf and retry."
        }
    }
}

public enum WindsurfLocalStorageReader {
    public static let envStateDBKey = "CODEXBAR_WINDSURF_STATE_DB"
    public static let envStateDBFallbackKey = "WINDSURF_STATE_DB"

    /// Default: ~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb
    public static func stateDBURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = cleaned(environment[envStateDBKey]) ?? cleaned(environment[envStateDBFallbackKey]) {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Windsurf", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb", isDirectory: false)
    }

    public static func loadCachedPlanInfo(environment: [String: String]) throws -> WindsurfCachedPlanInfo {
        #if os(macOS)
        let dbURL = self.stateDBURL(environment: environment)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw WindsurfUsageError.dbMissing(dbURL)
        }

        var db: OpaquePointer?
        let open = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard open == SQLITE_OK, let db else {
            let msg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "sqlite open failed"
            throw WindsurfUsageError.sqliteFailed(msg)
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 250)

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "sqlite prepare failed"
            throw WindsurfUsageError.sqliteFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "windsurf.settings.cachedPlanInfo", -1, transient)

        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            if step != SQLITE_DONE {
                let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "sqlite step failed"
                throw WindsurfUsageError.sqliteFailed(msg)
            }
            throw WindsurfUsageError.cachedPlanMissing
        }

        guard let bytes = sqlite3_column_blob(stmt, 0) else {
            throw WindsurfUsageError.cachedPlanMissing
        }
        let byteCount = Int(sqlite3_column_bytes(stmt, 0))
        guard byteCount > 0 else { throw WindsurfUsageError.cachedPlanMissing }

        let data = Data(bytes: bytes, count: byteCount)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw WindsurfUsageError.decodeFailed
        }
        let decoded = try? JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: Data(text.utf8))
        guard let decoded else { throw WindsurfUsageError.decodeFailed }
        return decoded
        #else
        _ = environment
        throw WindsurfUsageError.unsupportedPlatform
        #endif
    }

    public static func parseEpoch(_ value: Int?) -> Date? {
        guard let value else { return nil }
        if value >= 1_000_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
        }
        if value > 0 {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    public static func makeUsageSnapshot(info: WindsurfCachedPlanInfo, now: Date = Date()) throws -> UsageSnapshot {
        guard let usage = info.usage else {
            throw WindsurfUsageError.cachedPlanMissing
        }

        let resetsAt = Self.parseEpoch(info.endTimestamp)

        func window(total: Int?, used: Int?) -> RateWindow? {
            guard let total, total > 0, let used else { return nil }
            let ratio = max(0, min(1.0, Double(used) / Double(total)))
            return RateWindow(
                usedPercent: ratio * 100.0,
                windowMinutes: nil,
                resetsAt: resetsAt,
                resetDescription: nil)
        }

        let primary = window(total: usage.messages, used: usage.usedMessages)
        let secondary = window(total: usage.flexCredits, used: usage.usedFlexCredits)

        let identity = ProviderIdentitySnapshot(
            providerID: .windsurf,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: info.planName)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
