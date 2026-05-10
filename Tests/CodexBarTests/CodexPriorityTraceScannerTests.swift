import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

struct CodexPriorityTraceScannerTests {
    @Test
    func `parses priority turn metadata without exposing request body`() {
        let body = "INFO thread_id=11111111-1111-1111-1111-111111111111 "
            + "turn.id=22222222-2222-2222-2222-222222222222 websocket request: "
            + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority","instructions":"secret prompt"}"#

        let parsed = CodexPriorityTraceScanner.parseTraceRow(timestamp: "2026-05-10T12:00:00Z", body: body)

        #expect(parsed?.threadID == "11111111-1111-1111-1111-111111111111")
        #expect(parsed?.turnID == "22222222-2222-2222-2222-222222222222")
        #expect(parsed?.model == "gpt-5.5")
        #expect(parsed?.timestamp == "2026-05-10T12:00:00Z")
    }

    @Test
    func `ignores non priority malformed and non response request rows`() {
        let prefix = "thread_id=thread turn.id=turn websocket request: "

        #expect(CodexPriorityTraceScanner.parseTraceRow(
            timestamp: nil,
            body: prefix + #"{"type":"session.update","service_tier":"priority"}"#) == nil)
        #expect(CodexPriorityTraceScanner.parseTraceRow(
            timestamp: nil,
            body: prefix + #"{"type":"response.create"}"#) == nil)
        #expect(CodexPriorityTraceScanner.parseTraceRow(
            timestamp: nil,
            body: prefix + #"{"type":"response.create","service_tier":"default"}"#) == nil)
        #expect(CodexPriorityTraceScanner.parseTraceRow(
            timestamp: nil,
            body: prefix + #"{"#) == nil)
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

        let turns = CodexPriorityTraceScanner.priorityTurns(databaseURL: dbURL)

        #expect(turns.keys.sorted() == ["turn-a"])
        #expect(turns["turn-a"]?.threadID == "thread-a")
        #expect(turns["turn-a"]?.model == "gpt-5.5")
    }

    @Test
    func `sqlite scan only returns priority turns in requested day range`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try Self.createTestLogsDatabase(at: dbURL)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-09T23:59:59Z",
            body: "thread_id=thread-old turn.id=turn-old websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertTestLog(
            dbURL: dbURL,
            timestamp: "2026-05-10T12:00:00Z",
            body: "thread_id=thread-new turn.id=turn-new websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let turns = CodexPriorityTraceScanner.priorityTurns(
            databaseURL: dbURL,
            sinceDayKey: "2026-05-10",
            untilDayKey: "2026-05-10")

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

        let turns = CodexPriorityTraceScanner.priorityTurns(
            databaseURL: dbURL,
            sinceDayKey: dayKey,
            untilDayKey: dayKey)

        #expect(turns.keys.sorted() == ["turn-after"])
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
