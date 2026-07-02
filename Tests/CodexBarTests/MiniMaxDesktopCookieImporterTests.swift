import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

#if os(macOS)
struct MiniMaxDesktopCookieImporterTests {
    @Test
    func `imports minimax agent cookies from desktop sqlite`() throws {
        let databaseURL = try self.makeCookiesDatabase(
            records: [
                (".www.minimaxi.com", "_token", "desktop-token-value"),
                ("agent.minimaxi.com", "_token", "agent-token-value"),
            ])
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let session = MiniMaxDesktopCookieImporter.importSession(databaseURL: databaseURL)
        #expect(session?.sourceLabel == "MiniMax Agent")
        #expect(session?.cookieHeader.contains("_token=desktop-token-value") == true)
        #expect(session?.cookieHeader.contains("agent-token-value") == false)
    }

    @Test
    func `imports platform console cookies from desktop sqlite`() throws {
        let databaseURL = try self.makeCookiesDatabase(
            records: [
                ("platform.minimaxi.com", "_token", "platform-token-value"),
            ])
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let session = MiniMaxDesktopCookieImporter.importSession(databaseURL: databaseURL)
        #expect(session?.cookieHeader.contains("_token=platform-token-value") == true)
    }

    private func makeCookiesDatabase(records: [(String, String, String)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-desktop-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("Cookies")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw MiniMaxDesktopCookieImportError.sqliteFailed("open failed")
        }
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE cookies (
            host_key TEXT NOT NULL,
            name TEXT NOT NULL,
            value TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw MiniMaxDesktopCookieImportError.sqliteFailed("create failed")
        }

        for (host, name, value) in records {
            let insertSQL = "INSERT INTO cookies(host_key, name, value) VALUES ('\(host)','\(name)','\(value)');"
            guard sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK else {
                throw MiniMaxDesktopCookieImportError.sqliteFailed("insert failed")
            }
        }

        return databaseURL
    }
}
#endif
