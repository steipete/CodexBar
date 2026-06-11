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
            + #"{"type":"response.create","model":"request-model","service_tier":"priority","#
            + #""instructions":"secret prompt"}"#

        let parsed = CostUsageScanner.parseCodexPriorityTraceRow(timestamp: "2026-05-10T12:00:00Z", body: body)

        #expect(parsed?.threadID == "11111111-1111-1111-1111-111111111111")
        #expect(parsed?.turnID == "22222222-2222-2222-2222-222222222222")
        #expect(parsed?.model == "request-model")
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
            + #"{"type":"response.completed","response":{"model":"completed-model","output":[{"content":"private"}]}}"#

        let parsed = CostUsageScanner.parseCodexCompletedTraceRow(body: body)

        #expect(parsed?.turnID == "turn")
        #expect(parsed?.model == "completed-model")
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
                + #"{"type":"response.create","model":"request-model","service_tier":"priority","input":"private"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: """
            thread_id=thread-b turn.id=turn-b websocket request: {"type":"response.create","model":"request-model"}
            """)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(turns.keys.sorted() == ["turn-a"])
        #expect(turns["turn-a"]?.threadID == "thread-a")
        #expect(turns["turn-a"]?.model == "request-model")
    }

    @Test
    func `cold scan uses timestamp index and warm scan uses rowid cursor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SQLiteTestError.open
        }
        defer { sqlite3_close(db) }

        let coldQuery = CostUsageScanner._test_codexPriorityAccumulationQuery(
            db,
            lastRowID: 0,
            coverageSinceEpoch: 1)
        let coldPlan = try Self.queryPlan(db: db, query: coldQuery, bindings: [1])
        #expect(coldPlan.contains { $0.contains("USING INDEX idx_logs_ts") })

        let unboundedColdQuery = CostUsageScanner._test_codexPriorityAccumulationQuery(
            db,
            lastRowID: 0,
            coverageSinceEpoch: 0)
        let unboundedColdPlan = try Self.queryPlan(
            db: db,
            query: unboundedColdQuery,
            bindings: [0, 0])
        #expect(unboundedColdPlan.contains { $0.contains("USING INTEGER PRIMARY KEY") })
        #expect(!unboundedColdPlan.contains { $0.contains("USE TEMP B-TREE") })

        let warmQuery = CostUsageScanner._test_codexPriorityAccumulationQuery(
            db,
            lastRowID: 1,
            coverageSinceEpoch: 0)
        let warmPlan = try Self.queryPlan(db: db, query: warmQuery, bindings: [1, 0])
        #expect(warmPlan.contains { $0.contains("USING INTEGER PRIMARY KEY") })
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
                + #"{"type":"response.create","model":"request-alias","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:01Z",
            body: "thread_id=thread turn.id=turn websocket event: "
                + #"{"type":"response.completed","response":{"model":"completed-model","input":"private"}}"#)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(turns["turn"]?.model == "completed-model")
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
                + #"{"type":"response.create","model":"request-alias","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:01Z",
            body: "thread_id=thread turn.id=turn websocket event: "
                + #"{"type": "response.completed", "response": {"model": "completed-model"}}"#)

        let turns = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(turns["turn"]?.model == "completed-model")
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
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: env.isoString(for: day),
            body: "thread_id=thread-new turn.id=turn-new websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

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
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            epochSeconds: Int64(nextSecond.timeIntervalSince1970),
            body: "thread_id=thread-after turn.id=turn-after websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

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
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

        #expect(CostUsageScanner.codexPriorityTurns(databaseURL: dbURL).keys.sorted() == ["turn-a"])

        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:05:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:05:01Z",
            body: "thread_id=thread-a turn.id=turn-a websocket event: "
                + #"{"type":"response.completed","response":{"model":"resolved-model"}}"#)

        let merged = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(merged.keys.sorted() == ["turn-a", "turn-b"])
        // A completed event appended later still upgrades the model of a turn accumulated earlier.
        #expect(merged["turn-a"]?.model == "resolved-model")
    }

    @Test
    func `memo drops pruned requests while ids keep increasing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        #expect(CostUsageScanner.codexPriorityTurns(databaseURL: dbURL).keys.sorted() == ["turn-a", "turn-b"])

        try Self.execDatabase(dbURL: dbURL, sql: "delete from logs where rowid = 1")
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:02:00Z",
            body: "thread_id=thread-c turn.id=turn-c websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

        let rebuilt = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(rebuilt.keys.sorted() == ["turn-b", "turn-c"])
    }

    @Test
    func `memo drops a pruned completion model without losing its request`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"request-alias","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:01Z",
            body: "thread_id=thread-a turn.id=turn-a websocket event: "
                + #"{"type":"response.completed","response":{"model":"resolved-model"}}"#)
        #expect(CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)["turn-a"]?.model == "resolved-model")

        try Self.execDatabase(dbURL: dbURL, sql: "delete from logs where rowid = 2")
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

        let pruned = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(pruned["turn-a"]?.model == "request-alias")
        #expect(pruned["turn-b"]?.model == "request-model")
    }

    @Test
    func `memo falls back to retained duplicate request and completion rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-old turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"request-old","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:01Z",
            body: "thread_id=thread-new turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"request-new","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:02Z",
            body: "thread_id=thread-old turn.id=turn-a websocket event: "
                + #"{"type":"response.completed","response":{"model":"completed-old"}}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:03Z",
            body: "thread_id=thread-new turn.id=turn-a websocket event: "
                + #"{"type":"response.completed","response":{"model":"completed-new"}}"#)

        let initial = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(initial["turn-a"]?.threadID == "thread-new")
        #expect(initial["turn-a"]?.model == "completed-new")

        try Self.execDatabase(dbURL: dbURL, sql: "delete from logs where rowid in (2, 4)")
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

        let pruned = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(pruned["turn-a"]?.threadID == "thread-old")
        #expect(pruned["turn-a"]?.model == "completed-old")
        #expect(pruned["turn-b"]?.model == "request-model")
    }

    @Test
    func `failed incremental scan does not report completion`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SQLiteTestError.open
        }
        defer { sqlite3_close(db) }
        sqlite3_progress_handler(db, 1, { _ in 1 }, nil)

        var state = CostUsageScanner.CodexPriorityTurnsMemoState(
            observationID: 1,
            coverageSinceEpoch: 0,
            lastRowID: 0,
            fileIdentity: nil,
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)

        #expect(!CostUsageScanner._test_accumulateCodexPriorityTurns(db, into: &state))
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
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: formatter.string(from: today),
            body: "thread_id=thread-new turn.id=turn-new websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

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
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        #expect(CostUsageScanner.codexPriorityTurns(databaseURL: dbURL).count == 2)

        try FileManager.default.removeItem(at: dbURL)
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-11T09:00:00Z",
            body: "thread_id=thread-c turn.id=turn-c websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)

        let replaced = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(replaced.keys.sorted() == ["turn-c"])
    }

    @Test
    func `database replacement during open is rejected`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        let oldURL = env.root.appendingPathComponent("logs-old.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        var replacementError: Error?

        let opened = CostUsageScanner.openCodexPriorityDatabase(at: dbURL) {
            do {
                try FileManager.default.moveItem(at: dbURL, to: oldURL)
                try Self.createTestLogsDatabase(at: dbURL)
            } catch {
                replacementError = error
            }
        }
        if let opened {
            sqlite3_close(opened.db)
        }

        #expect(replacementError == nil)
        #expect(opened == nil)
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
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:01:00Z",
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"request-model","service_tier":"priority"}"#)
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
        let overflow = limit + 8
        let epoch = Self.epochSeconds("2026-05-10T12:00:00Z")

        // A known priority turn keeps its resolved completion outside the bounded pending
        // cache while thousands of unrelated completions flow through the process.
        var rows = [
            (
                epochSeconds: epoch,
                body: "thread_id=priority turn.id=priority websocket request: "
                    + #"{"type":"response.create","model":"priority-alias","service_tier":"priority"}"#),
            (
                epochSeconds: epoch,
                body: "thread_id=priority turn.id=priority websocket event: "
                    + #"{"type":"response.completed","response":{"model":"resolved-model"}}"#),
        ]
        rows.append(contentsOf: (0..<(limit + overflow)).map { index in
            (
                epochSeconds: epoch,
                body: "thread_id=thread-\(index) turn.id=turn-\(index) websocket event: "
                    + #"{"type":"response.completed","response":{"model":"completed-model"}}"#)
        })
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
        #expect(memo.completedModelsByTurnID.count == limit - 1)
        #expect(
            memo.completedTurnIDInsertionOrder.count
                - memo.completedTurnIDInsertionOrderStartIndex == limit - 1)
        #expect(memo.completedTurnIDInsertionOrder.count < limit * 2)
        #expect(memo.priorityCompletedModelsByTurnID.count == 2)
        // The oldest completions were evicted, so the early request keeps its alias; the
        // recent completion is still retained and upgrades its request.
        #expect(turns["priority"]?.model == "resolved-model")
        #expect(turns["turn-0"]?.model == "alias-evicted")
        #expect(turns["turn-\(newest)"]?.model == "completed-model")
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
        var persisted = try #require(CodexPriorityTurnsMemoIO.load(cacheRoot: env.root))
        persisted[dbURL.path]?.observationID = UInt64.max
        CodexPriorityTurnsMemoIO.save(states: persisted, cacheRoot: env.root)

        // Simulated relaunch: in-process state is gone, the artifact remains.
        CostUsageScanner._test_removeCodexPriorityTurnsMemoState(forPath: dbURL.path)
        CostUsageScanner._test_resetCodexPriorityTurnsMemoDiskState()

        CostUsageScanner.loadCodexPriorityTurnsMemoFromDiskIfNeeded(cacheRoot: env.root)
        let seeded = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(seeded.observationID == 0)
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
        #expect(advanced.observationID > 0)
        #expect(advanced.lastRowID == scanned.lastRowID + 1)
    }

    @Test
    func `persisted memo from a different parser hash or version is discarded`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let state = CostUsageScanner.CodexPriorityTurnsMemoState(
            observationID: 7,
            coverageSinceEpoch: 0,
            lastRowID: 7,
            fileIdentity: 42,
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)

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
        try self.exec(
            db,
            "create table logs (id integer primary key autoincrement, ts integer not null, feedback_log_body text)")
        try self.exec(db, "create index idx_logs_ts on logs(ts desc, id desc)")
    }

    static func queryPlan(
        db: OpaquePointer?,
        query: String,
        bindings: [Int64]) throws -> [String]
    {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "explain query plan \(query)", -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteTestError.prepare
        }
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in bindings.enumerated() {
            sqlite3_bind_int64(stmt, Int32(offset + 1), value)
        }

        var details: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let detail = sqlite3_column_text(stmt, 3) {
                details.append(String(cString: detail))
            }
        }
        return details
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

    private static func execDatabase(dbURL: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try self.exec(db, sql)
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
