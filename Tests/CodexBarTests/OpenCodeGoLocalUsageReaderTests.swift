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
    func `reads idle WAL database without creating sidecars`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)
        try Self.configureIdleWAL(at: env.databaseURL)

        let walURL = URL(fileURLWithPath: env.databaseURL.path + "-wal")
        let sharedMemoryURL = URL(fileURLWithPath: env.databaseURL.path + "-shm")
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: sharedMemoryURL.path))

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: sharedMemoryURL.path))
    }

    @Test
    func `builds daily cost history buckets within the requested window`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        // Expected keys below use the same device-local calendar convention as production.
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T12:00:00.000Z"),
            cost: 3.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T13:00:00.000Z"),
            cost: 1.5)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-05T12:00:00.000Z"),
            cost: 6.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-01-01T12:00:00.000Z"),
            cost: 100.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let now = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-06T15:00:00.000Z")) / 1000)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        let previousDayKey = CostUsageScanner.CostUsageDayRange.dayKey(
            from: Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-05T12:00:00.000Z")) / 1000))
        let currentDayKey = CostUsageScanner.CostUsageDayRange.dayKey(
            from: Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-06T12:00:00.000Z")) / 1000))
        #expect(snapshot.daily.map(\.date) == [previousDayKey, currentDayKey])
        #expect(snapshot.daily.first?.costUSD == 6.0)
        #expect(snapshot.daily.first?.requestCount == 1)
        #expect(snapshot.daily.last?.costUSD == 4.5)
        #expect(snapshot.daily.last?.requestCount == 2)
    }

    @Test
    func `auth without history falls through to web strategy`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)

        #expect(throws: OpenCodeGoLocalUsageError.historyUnavailable("database not found")) {
            _ = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))
        }
    }

    @Test
    func `auth with unreadable history falls through to web strategy`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        var db: OpaquePointer?
        guard sqlite3_open(env.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        sqlite3_close(db)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)

        #expect(throws: OpenCodeGoLocalUsageError.self) {
            _ = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))
        }
    }

    @Test
    func `monthly window keeps original anchor after shorter month clamp`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-01-31T00:00:00.000Z"),
            cost: 1.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-29T10:00:00.000Z"),
            cost: 6.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let now = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-29T12:00:00.000Z")) / 1000)
        let snapshot = try reader.fetch(now: now)

        #expect(snapshot.monthlyUsagePercent == 10)
        #expect(snapshot.monthlyResetInSec == 129_600)
    }

    @Test
    func `reads step finish parts when message only stores metadata`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: nil)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 10)
        #expect(snapshot.monthlyUsagePercent == 5)
    }

    @Test
    func `uses message cost while counting step finish requests`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 1.0)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms("2026-03-06T11:05:00.000Z"),
            cost: 2.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 10)
        #expect(snapshot.monthlyUsagePercent == 5)
        #expect(snapshot.daily.first?.costUSD == 3.0)
        #expect(snapshot.daily.first?.requestCount == 2)
    }

    @Test
    func `daily request count buckets step finish parts by their timestamps`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let anchor = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-06T15:00:00.000Z")) / 1000)
        let dayStart = Calendar.current.startOfDay(for: anchor)
        let now = dayStart.addingTimeInterval(6 * 60 * 60)
        let beforeMidnight = dayStart.addingTimeInterval(-60)
        let afterMidnight = dayStart.addingTimeInterval(60)
        // One assistant turn can make provider requests on opposite sides of local midnight.
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(beforeMidnight),
            cost: nil)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms(beforeMidnight),
            cost: 1.0)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms(afterMidnight),
            cost: 2.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily.first?.costUSD == 1.0)
        #expect(snapshot.daily.first?.requestCount == 1)
        #expect(snapshot.daily.last?.costUSD == 2.0)
        #expect(snapshot.daily.last?.requestCount == 1)
    }

    @Test
    func `daily entries group cost by model within a day`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0,
            model: "claude-sonnet-4-5")
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T12:00:00.000Z"),
            cost: 2.0,
            model: "gpt-5.1-codex")
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T13:00:00.000Z"),
            cost: 1.0,
            model: "claude-sonnet-4-5")

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let now = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-06T15:00:00.000Z")) / 1000)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        #expect(snapshot.daily.count == 1)
        let entry = try #require(snapshot.daily.first)
        #expect(entry.costUSD == 6.0)
        #expect(entry.requestCount == 3)
        #expect(entry.modelsUsed == ["claude-sonnet-4-5", "gpt-5.1-codex"])

        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.count == 2)
        #expect(breakdowns.first?.modelName == "claude-sonnet-4-5")
        #expect(breakdowns.first?.costUSD == 4.0)
        #expect(breakdowns.first?.requestCount == 2)
        #expect(breakdowns.last?.modelName == "gpt-5.1-codex")
        #expect(breakdowns.last?.costUSD == 2.0)
        #expect(breakdowns.last?.requestCount == 1)
    }

    @Test
    func `step finish parts inherit their model from the parent message`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: nil,
            model: "grok-code-fast-1")
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        let entry = try #require(snapshot.daily.first)
        #expect(entry.modelsUsed == ["grok-code-fast-1"])
        #expect(entry.modelBreakdowns?.first?.modelName == "grok-code-fast-1")
        #expect(entry.modelBreakdowns?.first?.costUSD == 3.0)
    }

    @Test
    func `messages without a model fall back to the unknown model bucket`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 4.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        let entry = try #require(snapshot.daily.first)
        #expect(entry.costUSD == 4.0)
        #expect(entry.modelsUsed == ["unknown"])
        #expect(entry.modelBreakdowns?.first?.modelName == "unknown")
        #expect(entry.modelBreakdowns?.first?.costUSD == 4.0)
    }

    @Test
    func `whitespace only model ids fall back to the unknown model bucket`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 5.0,
            model: "   ")

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        let entry = try #require(snapshot.daily.first)
        #expect(entry.modelsUsed == ["unknown"])
        #expect(entry.modelBreakdowns?.first?.modelName == "unknown")
        #expect(entry.modelBreakdowns?.first?.costUSD == 5.0)
    }

    @Test
    func `model ids with incidental whitespace merge with the trimmed model bucket`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 2.0,
            model: "claude-sonnet-4-5")
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T12:00:00.000Z"),
            cost: 3.0,
            model: "  claude-sonnet-4-5  ")

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let now = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-06T15:00:00.000Z")) / 1000)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        let entry = try #require(snapshot.daily.first)
        #expect(entry.modelsUsed == ["claude-sonnet-4-5"])
        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.count == 1)
        #expect(breakdowns.first?.modelName == "claude-sonnet-4-5")
        #expect(breakdowns.first?.costUSD == 5.0)
        #expect(breakdowns.first?.requestCount == 2)
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
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
                CREATE TABLE part (
                  id TEXT PRIMARY KEY,
                  message_id TEXT NOT NULL,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
            """)
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
            let sidecarURL = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try FileManager.default.removeItem(at: sidecarURL)
            }
        }
    }

    @discardableResult
    private static func insertMessage(
        databaseURL: URL,
        createdMs: Int64,
        cost: Double?,
        model: String? = nil) throws -> String
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let messageID = UUID().uuidString
        var payload: [String: Any] = [
            "providerID": "opencode-go",
            "role": "assistant",
            "time": ["created": createdMs],
        ]
        if let cost {
            payload["cost"] = cost
        }
        if let model {
            payload["modelID"] = model
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message (id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, messageID, -1, transient)
        sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 3, json, -1, transient)
        sqlite3_bind_int64(stmt, 4, createdMs)
        sqlite3_bind_int64(stmt, 5, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
        return messageID
    }

    private static func insertStepFinishPart(
        databaseURL: URL,
        messageID: String,
        createdMs: Int64,
        cost: Double) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let payload: [String: Any] = [
            "type": "step-finish",
            "cost": cost,
            "tokens": ["input": 1, "output": 1, "total": 2],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO part (id, message_id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, messageID, -1, transient)
        sqlite3_bind_text(stmt, 3, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 4, json, -1, transient)
        sqlite3_bind_int64(stmt, 5, createdMs)
        sqlite3_bind_int64(stmt, 6, createdMs)
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

    private static func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private enum SQLiteTestError: Error {
        case close
        case open
        case prepare
        case step
        case exec
    }
}

#endif
