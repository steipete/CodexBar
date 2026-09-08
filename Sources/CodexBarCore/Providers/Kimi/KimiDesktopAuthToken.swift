import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
/// Read-only access to the official Kimi Desktop Chromium cookie store.
public enum KimiDesktopAuthToken: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.kimi, scope: "cookie"))

    public static func cookiesDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("kimi-desktop", isDirectory: true)
            .appendingPathComponent("Cookies", isDirectory: false)
    }

    public static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        self.load(databaseURL: self.cookiesDatabaseURL(homeDirectory: homeDirectory))
    }

    static func load(databaseURL: URL) -> String? {
        guard FileManager.default.isReadableFile(atPath: databaseURL.path) else { return nil }
        do {
            return try self.read(databaseURL: databaseURL, immutable: false)
        } catch let failure as SQLiteReadFailure {
            // Chromium can leave the main database in WAL mode after a clean shutdown removes both sidecars.
            // Immutable mode reads that idle file without recreating sidecars; active WAL databases stay on the
            // normal read-only path so committed WAL records remain visible.
            guard failure.code == SQLITE_CANTOPEN, self.walSidecarsAreMissing(databaseURL: databaseURL) else {
                Self.log.debug("Kimi Desktop Cookies read failed: \(failure.message)")
                return nil
            }
            do {
                return try self.read(databaseURL: databaseURL, immutable: true)
            } catch let fallbackFailure as SQLiteReadFailure {
                Self.log.debug("Kimi Desktop Cookies immutable read failed: \(fallbackFailure.message)")
                return nil
            } catch {
                return nil
            }
        } catch {
            return nil
        }
    }

    private static func read(databaseURL: URL, immutable: Bool) throws -> String? {
        var db: OpaquePointer?
        let filename = immutable ? "\(databaseURL.absoluteURL.absoluteString)?immutable=1" : databaseURL.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &db, flags, nil)
        guard openResult == SQLITE_OK else {
            let failure = self.sqliteFailure(db: db, resultCode: openResult)
            sqlite3_close(db)
            throw failure
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT value
        FROM cookies
        WHERE name = 'kimi-auth'
          AND host_key IN ('www.kimi.com', '.www.kimi.com', '.kimi.com', 'kimi.com')
        ORDER BY last_access_utc DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw self.sqliteFailure(db: db, resultCode: prepareResult)
        }
        defer { sqlite3_finalize(statement) }

        let step = sqlite3_step(statement)
        if step == SQLITE_DONE {
            return nil
        }
        guard step == SQLITE_ROW else {
            throw self.sqliteFailure(db: db, resultCode: step)
        }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        let token = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty || Self.isExpired(token) ? nil : token
    }

    /// Cookie expiry and JWT expiry can differ. An old desktop JWT must not shadow a live browser session.
    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = claims["exp"] as? Double else { return false }
        return expiry <= now.timeIntervalSince1970
    }

    private static func walSidecarsAreMissing(databaseURL: URL) -> Bool {
        !FileManager.default.fileExists(atPath: databaseURL.path + "-wal") &&
            !FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
    }

    private static func sqliteFailure(db: OpaquePointer?, resultCode: Int32) -> SQLiteReadFailure {
        SQLiteReadFailure(
            code: db.map { sqlite3_errcode($0) } ?? resultCode,
            message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }

    private struct SQLiteReadFailure: Error {
        let code: Int32
        let message: String
    }
}
#else
public enum KimiDesktopAuthToken: Sendable {
    public static func cookiesDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("kimi-desktop", isDirectory: true)
            .appendingPathComponent("Cookies", isDirectory: false)
    }

    public static func load(homeDirectory _: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        nil
    }
}
#endif
