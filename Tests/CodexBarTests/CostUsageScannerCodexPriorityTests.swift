import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

struct CostUsageScannerCodexPriorityTests {
    @Test
    func `parses priority turn metadata without exposing request body`() {
        let body = "INFO thread_id=11111111-1111-1111-1111-111111111111 "
            + "turn.id=22222222-2222-2222-2222-222222222222 websocket request: "
            + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority","instructions":"secret prompt"}"#

        let parsed = CostUsageScanner.parseCodexPriorityTraceRow(timestamp: "2026-05-10T12:00:00Z", body: body)

        #expect(parsed?.threadID == "11111111-1111-1111-1111-111111111111")
        #expect(parsed?.turnID == "22222222-2222-2222-2222-222222222222")
        #expect(parsed?.model == "gpt-5.5")
        #expect(parsed?.timestamp == "2026-05-10T12:00:00Z")
    }

    @Test
    func `ignores non priority malformed and non response request rows`() {
        let prefix = "thread_id=thread turn.id=turn websocket request: "

        #expect(CostUsageScanner.parseCodexPriorityTraceRow(
            timestamp: nil,
            body: prefix + #"{"type":"session.update","service_tier":"priority"}"#) == nil)
        #expect(CostUsageScanner.parseCodexPriorityTraceRow(
            timestamp: nil,
            body: prefix + #"{"type":"response.create"}"#) == nil)
        #expect(CostUsageScanner.parseCodexPriorityTraceRow(
            timestamp: nil,
            body: prefix + #"{"type":"response.create","service_tier":"default"}"#) == nil)
        #expect(CostUsageScanner.parseCodexPriorityTraceRow(
            timestamp: nil,
            body: prefix + #"{"#) == nil)
    }

    @Test
    func `parses completed response model without exposing response body`() {
        let body = "INFO thread_id=thread turn.id=turn websocket event: "
            + #"{"type":"response.completed","response":{"model":"gpt-5.4","output":[{"content":"private"}]}}"#

        let parsed = CostUsageScanner.parseCodexCompletedTraceRow(body: body)

        #expect(parsed?.turnID == "turn")
        #expect(parsed?.model == "gpt-5.4")
    }

    @Test
    func `reads priority turns from sqlite logs table`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority","input":"private"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: """
            thread_id=thread-b turn.id=turn-b websocket request: {"type":"response.create","model":"gpt-5.5"}
            """)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(turns.keys.sorted() == ["turn-a"])
        #expect(turns["turn-a"]?.threadID == "thread-a")
        #expect(turns["turn-a"]?.model == "gpt-5.5")
    }

    @Test
    func `sqlite scan upgrades priority request alias with completed response model`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread turn.id=turn websocket request: "
                + #"{"type":"response.create","model":"codex-auto-review","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:01Z",
            body: "thread_id=thread turn.id=turn websocket event: "
                + #"{"type":"response.completed","response":{"model":"gpt-5.4","input":"private"}}"#)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(turns["turn"]?.model == "gpt-5.4")
    }

    @Test
    func `sqlite scan matches spaced completed response json`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread turn.id=turn websocket request: "
                + #"{"type":"response.create","model":"codex-auto-review","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:01Z",
            body: "thread_id=thread turn.id=turn websocket event: "
                + #"{"type": "response.completed", "response": {"model": "gpt-5.4"}}"#)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(turns["turn"]?.model == "gpt-5.4")
    }

    @Test
    func `sqlite scan only returns priority turns in requested day range`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let previousDay = try #require(Calendar.current.date(byAdding: .day, value: -1, to: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: env.isoString(for: previousDay),
            body: "thread_id=thread-old turn.id=turn-old websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: env.isoString(for: day),
            body: "thread_id=thread-new turn.id=turn-new websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let turns = CostUsageScanner.codexPriorityTurns(
            databaseURL: dbURL,
            sinceDayKey: dayKey,
            untilDayKey: dayKey)

        #expect(turns.keys.sorted() == ["turn-new"])
    }

    @Test
    func `sqlite scan uses local day boundaries for integer timestamps`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)

        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = 2026
        components.month = 5
        components.day = 10
        let dayStart = try #require(components.date)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: dayStart)
        let previousSecond = try #require(Calendar.current.date(byAdding: .second, value: -1, to: dayStart))
        let nextSecond = try #require(Calendar.current.date(byAdding: .second, value: 1, to: dayStart))

        try Self.insertTestLog(
            dbURL: dbURL,
            epochSeconds: Int64(previousSecond.timeIntervalSince1970),
            body: "thread_id=thread-before turn.id=turn-before websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            epochSeconds: Int64(nextSecond.timeIntervalSince1970),
            body: "thread_id=thread-after turn.id=turn-after websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let turns = CostUsageScanner.codexPriorityTurns(
            databaseURL: dbURL,
            sinceDayKey: dayKey,
            untilDayKey: dayKey)

        #expect(turns.keys.sorted() == ["turn-after"])
    }

    @Test
    func `incremental memo picks up rows appended after the first query`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        #expect(CostUsageScanner.codexPriorityTurns(databaseURL: dbURL).keys.sorted() == ["turn-a"])

        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:05:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:05:01Z",
            body: "thread_id=thread-a turn.id=turn-a websocket event: "
                + #"{"type":"response.completed","response":{"model":"gpt-5.6"}}"#)

        let merged = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(merged.keys.sorted() == ["turn-a", "turn-b"])
        // A completed event appended later still upgrades the model of a turn accumulated earlier.
        #expect(merged["turn-a"]?.model == "gpt-5.6")
    }

    @Test
    func `memo rescans when requested window expands earlier than accumulated coverage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        // Live refreshes always query through today, which is the memoized path.
        let today = Date()
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: today))
        let todayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: today)
        let yesterdayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: yesterday)
        let formatter = ISO8601DateFormatter()
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: formatter.string(from: yesterday),
            body: "thread_id=thread-old turn.id=turn-old websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: formatter.string(from: today),
            body: "thread_id=thread-new turn.id=turn-new websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let narrow = CostUsageScanner.codexPriorityTurns(
            databaseURL: dbURL,
            sinceDayKey: todayKey,
            untilDayKey: todayKey)
        #expect(narrow.keys.sorted() == ["turn-new"])

        let expanded = CostUsageScanner.codexPriorityTurns(
            databaseURL: dbURL,
            sinceDayKey: yesterdayKey,
            untilDayKey: todayKey)
        #expect(expanded.keys.sorted() == ["turn-new", "turn-old"])
    }

    @Test
    func `memo rescans when the database shrinks or is replaced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        #expect(CostUsageScanner.codexPriorityTurns(databaseURL: dbURL).count == 2)

        try FileManager.default.removeItem(at: dbURL)
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-11T09:00:00Z",
            body: "thread_id=thread-c turn.id=turn-c websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let replaced = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(replaced.keys.sorted() == ["turn-c"])
    }

    @Test
    func `overlapping refresh writeback cannot replace newer memo state`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        #expect(CostUsageScanner.codexPriorityTurns(databaseURL: dbURL).count == 2)
        let stored = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        // A slower overlapping refresh writes back a snapshot read before the second row was
        // appended: an older cursor that only observed the first turn. It must not win.
        var stale = stored
        stale.lastRowID -= 1
        stale.turns = stored.turns.filter { $0.key == "turn-a" }
        CostUsageScanner.storeCodexPriorityTurnsMemoIfNewer(stale, forPath: dbURL.path)

        let retained = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(retained.lastRowID == stored.lastRowID)
        #expect(retained.turns.keys.sorted() == ["turn-a", "turn-b"])

        // A snapshot with a newer cursor still replaces the stored state.
        var newer = stored
        newer.lastRowID += 1
        CostUsageScanner.storeCodexPriorityTurnsMemoIfNewer(newer, forPath: dbURL.path)
        #expect(
            CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path)?
                .lastRowID == stored.lastRowID + 1)

        // A full rescan that expanded coverage earlier than the stored window also replaces,
        // even when its cursor is not ahead, so broader history is never discarded.
        var broader = stored
        broader.coverageSinceEpoch -= 1
        CostUsageScanner.storeCodexPriorityTurnsMemoIfNewer(broader, forPath: dbURL.path)
        #expect(
            CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path)?
                .coverageSinceEpoch == broader.coverageSinceEpoch)
    }

    @Test
    func `memo bounds retained completion metadata for non-priority turns`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        let limit = CostUsageScanner.codexPriorityCompletedModelRetentionLimit
        let overflow = 8
        let epoch = Self.epochSeconds("2026-05-10T12:00:00Z")

        // A long-running trace: far more non-priority completed turns than the retention
        // limit, followed by priority requests whose completions are evicted vs retained.
        var rows = (0..<(limit + overflow)).map { index in
            (
                epochSeconds: epoch,
                body: "thread_id=thread-\(index) turn.id=turn-\(index) websocket event: "
                    + #"{"type":"response.completed","response":{"model":"gpt-5.4"}}"#)
        }
        rows.append((
            epochSeconds: epoch,
            body: "thread_id=thread-0 turn.id=turn-0 websocket request: "
                + #"{"type":"response.create","model":"alias-evicted","service_tier":"priority"}"#))
        let newest = limit + overflow - 1
        rows.append((
            epochSeconds: epoch,
            body: "thread_id=thread-\(newest) turn.id=turn-\(newest) "
                + "websocket request: "
                + #"{"type":"response.create","model":"alias-retained","service_tier":"priority"}"#))
        try Self.insertTestLogs(dbURL: dbURL, rows: rows)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        let memo = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(memo.completedModelsByTurnID.count == limit)
        #expect(memo.completedTurnIDInsertionOrder.count == limit)
        // The oldest completions were evicted, so the early request keeps its alias; the
        // recent completion is still retained and upgrades its request.
        #expect(turns["turn-0"]?.model == "alias-evicted")
        #expect(turns["turn-\(newest)"]?.model == "gpt-5.4")
    }

    @Test
    func `persisted memo survives a simulated relaunch and keeps refreshes incremental`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        #expect(CostUsageScanner.codexPriorityTurns(databaseURL: dbURL).count == 2)
        let scanned = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        CostUsageScanner.persistCodexPriorityTurnsMemoIfDirty(cacheRoot: env.root)
        #expect(FileManager.default.fileExists(
            atPath: CodexPriorityTurnsMemoIO.artifactURL(cacheRoot: env.root).path))

        // Simulated relaunch: in-process state is gone, the artifact remains.
        CostUsageScanner._test_removeCodexPriorityTurnsMemoState(forPath: dbURL.path)
        CostUsageScanner._test_resetCodexPriorityTurnsMemoDiskState()

        CostUsageScanner.loadCodexPriorityTurnsMemoFromDiskIfNeeded(cacheRoot: env.root)
        let seeded = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(seeded.lastRowID == scanned.lastRowID)
        #expect(seeded.turns.keys.sorted() == ["turn-a", "turn-b"])

        // The next refresh resumes from the persisted cursor instead of rescanning.
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:02:00Z",
            body: "thread_id=thread-c turn.id=turn-c websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(turns.keys.sorted() == ["turn-a", "turn-b", "turn-c"])
        let advanced = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(advanced.lastRowID == scanned.lastRowID + 1)
    }

    @Test
    func `persisted memo from a different parser hash or version is discarded`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let state = CostUsageScanner.CodexPriorityTurnsMemoState(
            coverageSinceEpoch: 0,
            lastRowID: 7,
            fileIdentity: 42,
            turns: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [])

        CodexPriorityTurnsMemoIO.save(states: ["/tmp/db": state], cacheRoot: env.root, producerKey: "codex:pt:pstale")
        #expect(CodexPriorityTurnsMemoIO.load(cacheRoot: env.root) == nil)

        CodexPriorityTurnsMemoIO.save(states: ["/tmp/db": state], cacheRoot: env.root)
        #expect(CodexPriorityTurnsMemoIO.load(cacheRoot: env.root)?["/tmp/db"]?.lastRowID == 7)
        #expect(CodexPriorityTurnsMemoIO.load(cacheRoot: env.root, producerKey: "codex:pt:pother") == nil)
    }

    @Test
    func `corrupted persisted memo artifact is ignored`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let url = CodexPriorityTurnsMemoIO.artifactURL(cacheRoot: env.root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        #expect(CodexPriorityTurnsMemoIO.load(cacheRoot: env.root) == nil)
    }

    static func insertTestLogs(dbURL: URL, rows: [(epochSeconds: Int64, body: String)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "insert into logs (ts, feedback_log_body) values (?, ?)", -1, &stmt, nil)
            == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        try self.exec(db, "begin transaction")
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            sqlite3_bind_int64(stmt, 1, row.epochSeconds)
            sqlite3_bind_text(stmt, 2, row.body, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
            sqlite3_reset(stmt)
        }
        try self.exec(db, "commit")
    }

    static func createTestLogsDatabase(at dbURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try self.exec(db, "create table logs (ts integer not null, feedback_log_body text)")
    }

    static func insertTestLog(dbURL: URL, timestamp: String, body: String) throws {
        try self.insertTestLog(dbURL: dbURL, epochSeconds: self.epochSeconds(timestamp), body: body)
    }

    static func insertTestLog(dbURL: URL, epochSeconds: Int64, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "insert into logs (ts, feedback_log_body) values (?, ?)", -1, &stmt, nil)
            == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, epochSeconds)
        sqlite3_bind_text(stmt, 2, body, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func epochSeconds(_ timestamp: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: timestamp) else { return 0 }
        return Int64(date.timeIntervalSince1970)
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            sqlite3_free(message)
            throw SQLiteTestError.exec
        }
    }

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
        case exec
    }
}
#endif
