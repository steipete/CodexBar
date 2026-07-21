import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the `kimi-auth` web session token from the official Kimi Desktop Electron app.
///
/// Kimi Code CLI tokens can fetch weekly/rate-limit usage from `api.kimi.com`, but the
/// **Monthly** subscription pool still comes from the web membership API and needs a
/// `kimi-auth` cookie. Users who only run the CLI (no browser login) often still have
/// Kimi Desktop signed in — its Cookies DB stores `kimi-auth` in plaintext.
public enum KimiDesktopAuthToken: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.kimiCookie)

    public static func cookiesDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("kimi-desktop", isDirectory: true)
            .appendingPathComponent("Cookies", isDirectory: false)
    }

    /// Returns a non-empty `kimi-auth` value, or nil when missing/unreadable.
    public static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        #if os(macOS)
        let dbURL = self.cookiesDatabaseURL(homeDirectory: homeDirectory)
        guard FileManager.default.isReadableFile(atPath: dbURL.path) else { return nil }

        // Chrome/Electron may hold a write lock; copy to a temp file first.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kimi-desktop-cookies-\(UUID().uuidString).db")
        do {
            try FileManager.default.copyItem(at: dbURL, to: tempURL)
        } catch {
            Self.log.debug("Kimi Desktop Cookies copy failed: \(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let token = self.readKimiAuth(fromSQLitePath: tempURL.path) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
        #else
        return nil
        #endif
    }

    private static func readKimiAuth(fromSQLitePath path: String) -> String? {
        // Minimal SQLite3 open without a package dependency — Cookies is a standard Chromium DB.
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT value, length(encrypted_value)
            FROM cookies
            WHERE name = 'kimi-auth'
              AND (host_key = 'www.kimi.com' OR host_key = '.www.kimi.com' OR host_key = '.kimi.com' OR host_key = 'kimi.com')
            ORDER BY last_access_utc DESC
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if let cString = sqlite3_column_text(statement, 0) {
            let value = String(cString: cString)
            if !value.isEmpty { return value }
        }
        // Encrypted-only rows need Keychain AES — leave those to BrowserCookieClient.
        return nil
    }
}
