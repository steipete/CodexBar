#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodeGoV2LocalUsageReaderTests {
    @Test
    func `reads v2 Go requests without a legacy auth file or message table`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoV2Tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("opencode.db")
        try Self.withDatabase(at: databaseURL) { db in
            try Self.createV2Table(db: db)
            try Self.insertV2Message(
                db: db,
                id: "msg_go",
                createdMs: 1_772_794_800_000,
                data: """
                {"agent":"build","model":{"providerID":"opencode-go","id":"fixture-model"},
                 "content":[],"cost":3,"time":{"created":1772794800000}}
                """)
        }

        let reader = OpenCodeGoLocalUsageReader(
            authURL: root.appendingPathComponent("auth.json"),
            databaseURL: databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        let day = try #require(snapshot.daily.first)
        #expect(day.costUSD == 3)
        #expect(day.requestCount == 1)
        #expect(day.modelsUsed == ["fixture-model"])
        #expect(day.modelBreakdowns?.first?.costUSD == 3)
    }

    @Test(arguments: [false, true])
    func `keeps legacy requests and counts migrated messages once`(hasParts: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoV2Tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("opencode.db")
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_772_798_400))
        let beforeMidnight = Int64(dayStart.addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        let afterMidnight = Int64(dayStart.addingTimeInterval(60).timeIntervalSince1970 * 1000)
        try Self.withDatabase(at: databaseURL) { db in
            try Self.createV2Table(db: db)
            try Self.exec(db: db, sql: """
            CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL, time_created INTEGER);
            INSERT INTO message VALUES ('msg_old',
              '{"role":"assistant","providerID":"opencode-go","cost":4}', \(beforeMidnight));
            INSERT INTO message VALUES ('msg_migrated',
              '{"role":"assistant","providerID":"opencode-go","cost":3}', \(beforeMidnight));
            """)
            if hasParts {
                try Self.exec(db: db, sql: """
                CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, data TEXT, time_created INTEGER);
                INSERT INTO part VALUES ('prt_1', 'msg_migrated',
                  '{"type":"step-finish","cost":1}', \(beforeMidnight));
                INSERT INTO part VALUES ('prt_2', 'msg_migrated',
                  '{"type":"step-finish","cost":2}', \(afterMidnight));
                """)
            }
            try Self.insertV2Message(
                db: db,
                id: "msg_migrated",
                createdMs: beforeMidnight,
                data: #"{"model":{"providerID":"opencode-go","id":"fixture-model"},"cost":3}"#)
            try Self.insertV2Message(
                db: db,
                id: "msg_new",
                createdMs: afterMidnight,
                data: #"{"model":{"providerID":"opencode-go","id":"fixture-model"},"cost":5}"#)
        }

        let reader = OpenCodeGoLocalUsageReader(
            authURL: root.appendingPathComponent("auth.json"),
            databaseURL: databaseURL)
        let snapshot = try reader.fetch(now: dayStart.addingTimeInterval(12 * 3600))

        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily.first?.costUSD == (hasParts ? 5 : 7))
        #expect(snapshot.daily.last?.costUSD == (hasParts ? 7 : 5))
        #expect(snapshot.daily.reduce(0) { $0 + ($1.requestCount ?? 0) } == (hasParts ? 4 : 3))
    }

    @Test(arguments: [false, true])
    func `ignores malformed and unrelated v2 requests while retaining known zero costs`(hasLegacy: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoV2Tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("opencode.db")
        try Self.withDatabase(at: databaseURL) { db in
            try Self.createV2Table(db: db)
            if hasLegacy {
                // An invalid legacy copy must not hide a valid migrated request.
                try Self.exec(db: db, sql: """
                CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL, time_created INTEGER);
                INSERT INTO message VALUES ('msg_go',
                  '{"role":"assistant","providerID":"opencode-go","cost":-3}', 1772794800000);
                """)
            }
            try Self.insertV2Message(
                db: db,
                id: "msg_go",
                createdMs: 1_772_794_800_000,
                data: #"{"model":{"providerID":"opencode-go","id":"fixture-model"},"cost":3}"#)
            try Self.insertV2Message(
                db: db,
                id: "msg_zero",
                createdMs: 1_772_794_800_000,
                data: #"{"model":{"providerID":"opencode-go"},"cost":0}"#)
            let invalidPayloads = [
                "{",
                #"{"model":{"providerID":"opencode"},"cost":99}"#,
                #"{"model":{"providerID":"another-provider"},"cost":99}"#,
                #"{"providerID":"opencode-go","role":"assistant","cost":99}"#,
                #"{"model":{"providerID":"opencode-go"},"cost":"99"}"#,
                #"{"model":{"providerID":"opencode-go"},"cost":null}"#,
                #"{"model":{"providerID":"opencode-go"}}"#,
                #"{"model":{"providerID":"opencode-go"},"cost":-1}"#,
                #"{"model":{"providerID":"opencode-go"},"cost":1e999}"#,
            ]
            for (index, data) in invalidPayloads.enumerated() {
                try Self.insertV2Message(
                    db: db, id: "msg_invalid_\(index)", createdMs: 1_772_794_800_000, data: data)
            }
            try Self.insertV2Message(
                db: db,
                id: "msg_user",
                type: "user",
                createdMs: 1_772_794_800_000,
                data: #"{"model":{"providerID":"opencode-go"},"cost":99}"#)
        }

        let reader = OpenCodeGoLocalUsageReader(
            authURL: root.appendingPathComponent("auth.json"),
            databaseURL: databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        let day = try #require(snapshot.daily.first)
        #expect(day.costUSD == 3)
        #expect(day.requestCount == 2)
        #expect(day.modelsUsed == ["fixture-model", "unknown"])
        #expect(day.modelBreakdowns?.first?.costUSD == 3)
        #expect(day.modelBreakdowns?.last?.costUSD == 0)
    }

    @Test(arguments: [false, true])
    func `reads idle v2 WAL history without changing the database or creating sidecars`(hasLegacy: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoV2Tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("opencode.db")
        try Self.withDatabase(at: databaseURL) { db in
            try Self.exec(db: db, sql: "PRAGMA journal_mode = WAL;")
            try Self.createV2Table(db: db)
            if hasLegacy {
                try Self.exec(db: db, sql: """
                CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL, time_created INTEGER);
                """)
            }
            try Self.insertV2Message(
                db: db,
                id: "msg_go",
                createdMs: 1_772_794_800_000,
                data: #"{"model":{"providerID":"opencode-go","id":"fixture-model"},"cost":3}"#)
            try Self.exec(db: db, sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        }
        // Match an idle WAL database whose last writer removed its checkpointed sidecars.
        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try FileManager.default.removeItem(at: sidecarURL)
            }
        }
        let contents = try Data(contentsOf: databaseURL)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(filesBefore == ["opencode.db"])

        let reader = OpenCodeGoLocalUsageReader(
            authURL: root.appendingPathComponent("auth.json"),
            databaseURL: databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.daily.first?.costUSD == 3)
        #expect(try Data(contentsOf: databaseURL) == contents)
        let filesAfter = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(filesAfter == ["opencode.db"])
    }

    @Test
    func `includes v2 Go compaction request costs`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoV2Tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("opencode.db")
        try Self.withDatabase(at: databaseURL) { db in
            try Self.exec(db: db, sql: "CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT)")
            try Self.createV2Table(db: db)
            try Self.insertV2Message(
                db: db,
                id: "msg_compaction",
                type: "compaction",
                createdMs: 1_772_794_800_000,
                data: """
                {"status":"completed","reason":"auto","summary":"Summary","recent":"",
                 "model":{"providerID":"opencode-go","id":"fixture-model"},"cost":2,
                 "tokens":{"input":2,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}
                """)
        }

        let reader = OpenCodeGoLocalUsageReader(
            authURL: root.appendingPathComponent("auth.json"),
            databaseURL: databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.daily.first?.costUSD == 2)
        #expect(snapshot.daily.first?.requestCount == 1)
        #expect(snapshot.daily.first?.modelsUsed == ["fixture-model"])
        #expect(snapshot.daily.first?.inputTokens == 2)
        #expect(snapshot.daily.first?.outputTokens == 1)
        #expect(snapshot.daily.first?.totalTokens == 3)
    }

    private static func createV2Table(db: OpaquePointer?) throws {
        // OpenCode v2 stores type separately and omits id/type from the JSON payload.
        try self.exec(db: db, sql: """
        CREATE TABLE session_message (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          type TEXT NOT NULL,
          seq INTEGER NOT NULL,
          time_created INTEGER NOT NULL,
          time_updated INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
        """)
    }

    private static func insertV2Message(
        db: OpaquePointer?,
        id: String,
        type: String = "assistant",
        createdMs: Int64,
        data: String) throws
    {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
        VALUES (?, 'session-1', ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM session_message), ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(statement, 2, type, -1, transient)
        sqlite3_bind_int64(statement, 3, createdMs)
        sqlite3_bind_int64(statement, 4, createdMs)
        sqlite3_bind_text(statement, 5, data, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func withDatabase(at url: URL, body: (OpaquePointer?) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        do {
            try body(db)
        } catch {
            sqlite3_close(db)
            throw error
        }
        guard sqlite3_close(db) == SQLITE_OK else { throw SQLiteTestError.close }
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteTestError.exec }
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
