#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodeGoLocalUsageReaderTests {
    @Test
    func `reads local OpenCode Go history into usage windows`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-05T12:00:00.000Z"),
            cost: 6.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-02-25T07:53:16.000Z"),
            cost: 2.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 30)
        #expect(snapshot.monthlyUsagePercent == 18.3)
        #expect(snapshot.rollingResetInSec == 14400)
        #expect(snapshot.weeklyResetInSec == 216_000)
        #expect(snapshot.monthlyResetInSec == 1_626_796)
    }

    @Test
    func `auth without history returns zeroed bars`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 0)
        #expect(snapshot.weeklyUsagePercent == 0)
        #expect(snapshot.monthlyUsagePercent == 0)
    }

    @Test
    func `auth with unreadable history returns zeroed bars`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        var db: OpaquePointer?
        guard sqlite3_open(env.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        sqlite3_close(db)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 0)
        #expect(snapshot.weeklyUsagePercent == 0)
        #expect(snapshot.monthlyUsagePercent == 0)
    }

    @Test
    func `missing auth and history is not detected`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)

        #expect(throws: OpenCodeGoLocalUsageError.notDetected) {
            _ = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))
        }
    }

    private static func makeEnvironment() throws -> (root: URL, authURL: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoLocalUsageReaderTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            root,
            directory.appendingPathComponent("auth.json", isDirectory: false),
            directory.appendingPathComponent("opencode.db", isDirectory: false))
    }

    private static func writeAuth(to url: URL) throws {
        let data = Data(#"{"opencode-go":{"type":"api-key","key":"go-key"}}"#.utf8)
        try data.write(to: url)
    }

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.exec(
            db: db,
            sql: """
                CREATE TABLE message (
                  data TEXT NOT NULL,
                  time_created INTEGER
                );
            """)
    }

    private static func insertMessage(databaseURL: URL, createdMs: Int64, cost: Double) throws {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let payload: [String: Any] = [
            "providerID": "opencode-go",
            "role": "assistant",
            "time": ["created": createdMs],
            "cost": cost,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO message (data, time_created) VALUES (?, ?)", -1, &stmt, nil)
            == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, json, -1, transient)
        sqlite3_bind_int64(stmt, 2, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            sqlite3_free(message)
            throw SQLiteTestError.exec
        }
    }

    private static func ms(_ iso: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Int64((formatter.date(from: iso)?.timeIntervalSince1970 ?? 0) * 1000)
    }

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
        case exec
    }
}

#endif
