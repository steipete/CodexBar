import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite3
#endif
import Testing
@testable import CodexBarCore

/// A Codex trace database that Codex CLI closed cleanly is a WAL database without `-wal` and `-shm`
/// sidecars. Some SQLite builds (Apple's system library among them) decline a read-only open of that
/// file, which used to leave the whole Codex scan pending until Codex ran again.
struct CostUsageScannerCodexPriorityImmutableFallbackTests {
    private static let priorityBody = "thread_id=thread-a turn.id=turn-a websocket request: "
        + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#

    @Test
    func `wal database without sidecars resolves priority turns without pending validation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createWALLogsDatabase(at: dbURL)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: Self.priorityBody)
        try Self.removeSidecars(of: dbURL)

        let original = try Data(contentsOf: dbURL)
        let resolution = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: dbURL)

        #expect(resolution.validationPending == false)
        #expect(resolution.turns.keys.sorted() == ["turn-a"])
        #expect(try Data(contentsOf: dbURL) == original)
    }

    @Test
    func `bounded historical window reads a wal database without sidecars`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createWALLogsDatabase(at: dbURL)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: Self.priorityBody)
        try Self.removeSidecars(of: dbURL)

        // A window that ends before today takes the one-shot bounded query path.
        let resolution = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: dbURL,
            sinceDayKey: "2026-05-09",
            untilDayKey: "2026-05-11")

        #expect(resolution.validationPending == false)
        #expect(resolution.turns.keys.sorted() == ["turn-a"])
    }

    @Test
    func `immutable fallback handle reads the schema when it engages`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createWALLogsDatabase(at: dbURL)
        try Self.removeSidecars(of: dbURL)

        let opened = try #require(CostUsageScanner.openCodexPriorityDatabase(at: dbURL))
        defer { sqlite3_close(opened.db) }
        // Whether the fallback engages depends on the SQLite build; either way the handle must read.
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(opened.db, "select count(*) from logs", -1, &stmt, nil) == SQLITE_OK)
        sqlite3_finalize(stmt)
        if opened.idleState != nil {
            #expect(opened.idleState == SQLiteIdleDatabaseState.read(at: dbURL))
            #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
            #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-shm"))
        }
    }

    @Test
    func `idle database state tracks content changes and sidecars`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createWALLogsDatabase(at: dbURL)
        try Self.removeSidecars(of: dbURL)

        let before = try #require(SQLiteIdleDatabaseState.read(at: dbURL))
        #expect(SQLiteIdleDatabaseState.read(at: dbURL) == before)

        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: Self.priorityBody)
        try Self.removeSidecars(of: dbURL)
        let after = try #require(SQLiteIdleDatabaseState.read(at: dbURL))
        #expect(after != before)

        // A live writer leaves a -wal sidecar; the file is no longer idle.
        try Data().write(to: URL(fileURLWithPath: dbURL.path + "-wal"))
        #expect(SQLiteIdleDatabaseState.read(at: dbURL) == nil)
    }

    @Test
    func `schema probe waits for a lock released within the busy timeout`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: Self.priorityBody)

        // A rollback-journal exclusive lock blocks every reader, the same way WAL recovery does.
        let path = dbURL.path
        let locked = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        Thread {
            var holder: OpaquePointer?
            sqlite3_open(path, &holder)
            sqlite3_exec(holder, "begin exclusive", nil, nil, nil)
            locked.signal()
            proceed.wait()
            Thread.sleep(forTimeInterval: 0.05)
            sqlite3_exec(holder, "commit", nil, nil, nil)
            sqlite3_close(holder)
            released.signal()
        }.start()
        locked.wait()

        // Control: without a busy timeout, the first schema read fails while the lock is held.
        #expect(Self.schemaReadResultWithoutBusyTimeout(at: dbURL) == SQLITE_BUSY)
        proceed.signal()
        let resolution = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: dbURL)
        released.wait()

        #expect(resolution.validationPending == false)
        #expect(resolution.turns.keys.sorted() == ["turn-a"])
    }

    @Test
    func `older immutable invalidation preserves a newer validated cursor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        defer {
            CostUsageScanner._test_setCodexPriorityBeforeFallbackColdScanHook(databaseURL: dbURL, nil)
            CostUsageScanner.dropCodexPriorityTurnsMemo(databaseURL: dbURL)
        }
        try Self.createWALLogsDatabase(at: dbURL)
        let epoch = Int64(Date().timeIntervalSince1970)
        var rows = [(epochSeconds: epoch, body: Self.priorityBody)]
        rows.append(contentsOf: (1..<8).map { _ in (epochSeconds: epoch, body: "routine trace row") })
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)
        try Self.removeSidecars(of: dbURL)

        let probe = try #require(CostUsageScanner.openCodexPriorityDatabase(at: dbURL))
        let usesImmutable = probe.idleState != nil
        sqlite3_close(probe.db)
        // SQLite libraries that support ordinary read-only access do not take this invalidation path.
        guard usesImmutable else { return }
        let initial = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: dbURL)
        #expect(!initial.validationPending)
        #expect(initial.turns.keys.sorted() == ["turn-a"])

        // Row 1 is retained priority evidence but is outside the distributed anchors (2, 4, 6, 8).
        do {
            var writer: OpaquePointer?
            guard sqlite3_open(dbURL.path, &writer) == SQLITE_OK else { throw FixtureError.open }
            defer { sqlite3_close(writer) }
            guard sqlite3_exec(
                writer, "update logs set feedback_log_body='routine trace row' where rowid=1", nil, nil, nil) ==
                SQLITE_OK
            else { throw FixtureError.exec }
        }
        try Self.removeSidecars(of: dbURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        var newerCursor: CostUsageScanner.CodexPriorityTurnsPersistedCursor?
        CostUsageScanner._test_setCodexPriorityBeforeFallbackColdScanHook(databaseURL: dbURL) { _ in
            CostUsageScanner._test_setCodexPriorityBeforeFallbackColdScanHook(databaseURL: dbURL, nil)
            do {
                try CostUsageScannerCodexPriorityTests.insertTestLog(
                    dbURL: dbURL,
                    timestamp: "2026-05-10T12:00:00Z",
                    body: Self.priorityBody.replacingOccurrences(of: "turn-a", with: "turn-b"))
                try Self.removeSidecars(of: dbURL)
                try FileManager.default.setAttributes(
                    [.modificationDate: modified.addingTimeInterval(2)], ofItemAtPath: dbURL.path)
                let newer = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: dbURL)
                #expect(!newer.validationPending)
                #expect(newer.turns.keys.sorted() == ["turn-b"])
                newerCursor = CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL)
            } catch {
                Issue.record(error)
            }
        }

        let older = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: dbURL)
        let expected = try #require(newerCursor)
        #expect(older.validationPending)
        #expect(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: dbURL) == expected)
    }

    // MARK: - Fixtures

    private static func schemaReadResultWithoutBusyTimeout(at dbURL: URL) -> Int32 {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return sqlite3_errcode(db)
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        return sqlite3_prepare_v2(db, "select max(rowid) from logs", -1, &stmt, nil)
    }

    private static func createWALLogsDatabase(at dbURL: URL) throws {
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw FixtureError.open }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "pragma journal_mode=wal", nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.exec
        }
    }

    /// A clean close checkpoints and removes the sidecars; remove any that a build leaves behind so
    /// the fixture matches a Codex CLI that has exited.
    private static func removeSidecars(of dbURL: URL) throws {
        for suffix in ["-wal", "-shm"] {
            let path = dbURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
    }

    private enum FixtureError: Error {
        case open
        case exec
    }
}
