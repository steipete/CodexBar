#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct KimiDesktopAuthTokenTests {
    @Test
    func `reads newest plaintext Kimi auth token`() throws {
        let environment = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try Self.createDatabase(at: environment.databaseURL)
        try Self.insertCookie(
            databaseURL: environment.databaseURL,
            host: "www.kimi.com",
            value: "older-token",
            lastAccess: 1)
        try Self.insertCookie(
            databaseURL: environment.databaseURL,
            host: ".kimi.com",
            value: "newer-token",
            lastAccess: 2)

        #expect(KimiDesktopAuthToken.load(homeDirectory: environment.root) == "newer-token")
    }

    @Test
    func `reads active WAL without copying or mutating the database`() throws {
        let environment = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        var db: OpaquePointer?
        guard sqlite3_open(environment.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.createSchema(db: db)
        try Self.exec(db: db, sql: "PRAGMA journal_mode = WAL;")
        try Self.insertCookie(db: db, host: "www.kimi.com", value: "active-wal-token", lastAccess: 3)

        #expect(FileManager.default.fileExists(atPath: environment.databaseURL.path + "-wal"))
        #expect(KimiDesktopAuthToken.load(homeDirectory: environment.root) == "active-wal-token")
        #expect(FileManager.default.fileExists(atPath: environment.databaseURL.path + "-wal"))
    }

    @Test
    func `reads idle WAL database without creating sidecars`() throws {
        let environment = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try Self.createDatabase(at: environment.databaseURL)
        try Self.insertCookie(
            databaseURL: environment.databaseURL,
            host: "www.kimi.com",
            value: "idle-wal-token",
            lastAccess: 4)
        try Self.configureIdleWAL(at: environment.databaseURL)

        let walPath = environment.databaseURL.path + "-wal"
        let sharedMemoryPath = environment.databaseURL.path + "-shm"
        #expect(!FileManager.default.fileExists(atPath: walPath))
        #expect(!FileManager.default.fileExists(atPath: sharedMemoryPath))

        #expect(KimiDesktopAuthToken.load(homeDirectory: environment.root) == "idle-wal-token")
        #expect(!FileManager.default.fileExists(atPath: walPath))
        #expect(!FileManager.default.fileExists(atPath: sharedMemoryPath))
    }

    @Test
    func `ignores tokens from unrelated hosts`() throws {
        let environment = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try Self.createDatabase(at: environment.databaseURL)
        try Self.insertCookie(
            databaseURL: environment.databaseURL,
            host: "example.com",
            value: "wrong-host-token",
            lastAccess: 5)

        #expect(KimiDesktopAuthToken.load(homeDirectory: environment.root) == nil)
    }

    private static func makeEnvironment() throws -> (root: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiDesktopAuthTokenTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("kimi-desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (root, directory.appendingPathComponent("Cookies", isDirectory: false))
    }

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.createSchema(db: db)
    }

    private static func createSchema(db: OpaquePointer?) throws {
        try self.exec(
            db: db,
            sql: """
                CREATE TABLE cookies (
                  host_key TEXT NOT NULL,
                  name TEXT NOT NULL,
                  value TEXT NOT NULL,
                  encrypted_value BLOB NOT NULL DEFAULT X'',
                  last_access_utc INTEGER NOT NULL
                );
            """)
    }

    private static func insertCookie(
        databaseURL: URL,
        host: String,
        value: String,
        lastAccess: Int64) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.insertCookie(db: db, host: host, value: value, lastAccess: lastAccess)
    }

    private static func insertCookie(
        db: OpaquePointer?,
        host: String,
        value: String,
        lastAccess: Int64) throws
    {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO cookies (host_key, name, value, last_access_utc) VALUES (?, 'kimi-auth', ?, ?)",
            -1,
            &statement,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, host, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        sqlite3_bind_int64(statement, 3, lastAccess)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteTestError.exec }
    }

    private static func configureIdleWAL(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        do {
            try Self.exec(db: db, sql: "PRAGMA journal_mode = WAL; PRAGMA wal_checkpoint(TRUNCATE);")
        } catch {
            sqlite3_close(db)
            throw error
        }
        guard sqlite3_close(db) == SQLITE_OK else { throw SQLiteTestError.close }
        for suffix in ["-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteTestError.exec }
    }

    private enum SQLiteTestError: Error {
        case open
        case close
        case prepare
        case exec
    }
}

#endif
