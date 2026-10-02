import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Testing
@testable import CodexBarCore

struct CodexPrioritySQLiteTests {
    @Test
    func `reads live and historical priority evidence from the platform sqlite module`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase()
        try fixture.insert(turn: "priority", priority: true)
        try fixture.insert(turn: "standard", priority: false)

        let live = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: fixture.database)
        #expect(!live.validationPending)
        #expect(live.turns.keys.sorted() == ["priority"])
        #expect(live.turns["priority"]?.threadID == "priority-session")
        #expect(live.turns["priority"]?.model == "gpt-5.4")

        let historical = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: fixture.database, sinceDayKey: "2026-05-10", untilDayKey: "2026-05-10")
        #expect(!historical.validationPending)
        #expect(historical.turns == live.turns)
    }

    @Test
    func `restores a persisted priority cursor and reads appended evidence`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase()
        try fixture.insert(turn: "first", priority: true)
        _ = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: fixture.database)
        let cursor = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: fixture.database))
        let restored = try JSONDecoder().decode(
            CostUsageScanner.CodexPriorityTurnsPersistedCursor.self, from: JSONEncoder().encode(cursor))
        CostUsageScanner.dropCodexPriorityTurnsMemo(databaseURL: fixture.database)
        CostUsageScanner.seedCodexPriorityTurnsMemoIfEmpty(restored, databaseURL: fixture.database)
        try fixture.insert(turn: "second", priority: true)

        let result = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: fixture.database)
        #expect(!result.validationPending)
        #expect(result.turns.keys.sorted() == ["first", "second"])
        let advanced = try #require(CostUsageScanner.codexPriorityTurnsPersistedCursor(databaseURL: fixture.database))
        #expect(advanced.lastRowID > cursor.lastRowID)
    }

    @Test
    func `distinguishes an optional missing trace from an unreadable database`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missing = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: fixture.database)
        #expect(missing.turns.isEmpty)
        #expect(!missing.validationPending)
        try Data("not a sqlite database".utf8).write(to: fixture.database)
        let corrupt = CostUsageScanner.resolveCodexPriorityTurns(databaseURL: fixture.database)
        #expect(corrupt.turns.isEmpty)
        #expect(corrupt.validationPending)
    }

    @Test
    func `native snapshots and host summaries retain priority prices and coverage`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase()
        try fixture.insert(turn: "priority", priority: true)
        try fixture.insert(turn: "standard", priority: false)
        try fixture.writeSessions()
        try fixture.savePrices()

        let snapshot = try await fixture.snapshot()
        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.standardTokens == 110)
        #expect(breakdown.priorityTokens == 110)
        let summary = CodexCostSummary(snapshot: snapshot, calendar: fixture.calendar)
        try summary.validate(historyDays: 1)
        #expect(summary.history.totalTokens == 220)
        // Standard: (80 * 2 + 20 * 0.5 + 10 * 8) / 1M = 0.00025; Priority doubles it.
        let cost = try #require(summary.history.costUSD)
        #expect(abs(cost - 0.00075) < 1e-12)
        #expect(summary.today == summary.history)
        #expect(summary.historyCoverageIsEstablished)
        #expect(summary.history.incompleteRequestCount == 0)
        #expect(summary.history.coverage.priced > 0)
        #expect(summary.history.coverage.unpriced == 0)
        #expect(summary.history.coverage.unmetered == 0)
        #expect(summary.history.provenance == .listPriceEstimate)

        // Losing a previously observed optional database must not downgrade known Priority usage.
        try FileManager.default.removeItem(at: fixture.database)
        let unavailable = try await fixture.snapshot()
        #expect(unavailable.last30DaysCostUSD == snapshot.last30DaysCostUSD)
        #expect(unavailable.daily.first?.modelBreakdowns?.first?.priorityTokens == 110)
    }

    @Test
    func `ordinary refresh reprices cached native usage when priority evidence becomes readable`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase()
        try fixture.writeSessions()
        try fixture.savePrices()
        let before = try await fixture.snapshot()
        #expect(try abs(#require(before.last30DaysCostUSD) - 0.00050) < 1e-12)

        try fixture.insert(turn: "priority", priority: true)
        let after = try await fixture.snapshot()
        #expect(after.last30DaysTokens == before.last30DaysTokens)
        #expect(try abs(#require(after.last30DaysCostUSD) - 0.00075) < 1e-12)
        #expect(after.daily.first?.modelBreakdowns?.first?.priorityTokens == 110)
    }

    @Test(arguments: ["GMT", "Pacific/Kiritimati", "America/Los_Angeles"])
    func `native scanner daily transport uses receiver timezone and keeps priority pricing`(zone: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createDatabase()
        try fixture.insert(turn: "priority", priority: true)
        try fixture.insert(turn: "standard", priority: false)
        try fixture.writeSessions()
        try fixture.savePrices()
        let calendar = try CodexCostDailySummary.calendar(bucketTimeZone: zone)
        let snapshot = try await fixture.snapshot(calendar: calendar)
        let payload = try CodexCostDailySummary(snapshot: snapshot, calendar: calendar)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let wire = try #require(String(data: encoder.encode([payload]), encoding: .utf8))
        let fetcher = RemoteCodexCostFetcher { _, _ in wire }
        let received = try await fetcher.fetchDaily(host: "qa-linux", historyDays: 1, bucketTimeZone: zone)
        let restored = try received.tokenSnapshot()
        #expect(restored.daily.first?.date == (zone == "Pacific/Kiritimati" ? "2026-05-11" : "2026-05-10"))
        #expect(restored.daily.first?.totalTokens == 220)
        #expect(try abs(#require(restored.sessionCostUSD) - 0.00075) < 1e-12)
        #expect(restored.daily.first?.coverageCounts == snapshot.daily.first?.coverageCounts)
        #expect(restored.updatedAt == snapshot.updatedAt)
        #expect(restored.costProvenance == .listPriceEstimate)
        #expect(!wire.contains("gpt-5.4") && !wire.contains("priority-session"))
        #expect(!wire.contains(fixture.root.path))
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let sessions: URL
        let cache: URL
        let now = Date(timeIntervalSince1970: 1_778_414_400) // 2026-05-10 12:00 UTC.
        var calendar: Calendar {
            var value = Calendar(identifier: .gregorian)
            value.timeZone = .gmt
            return value
        }

        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.database = self.root.appendingPathComponent("logs_2.sqlite")
            self.sessions = self.root.appendingPathComponent("sessions")
            self.cache = self.root.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: self.sessions, withIntermediateDirectories: true)
        }

        func cleanup() {
            CostUsageScanner.dropCodexPriorityTurnsMemo(databaseURL: self.database)
            try? FileManager.default.removeItem(at: self.root)
        }

        func withDatabase(_ body: (OpaquePointer) throws -> Void) throws {
            var handle: OpaquePointer?
            let status = sqlite3_open(self.database.path, &handle)
            defer { sqlite3_close(handle) }
            try #require(status == SQLITE_OK)
            try body(#require(handle))
        }

        func createDatabase() throws {
            try self.withDatabase { db in
                let schema = """
                CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, feedback_log_body TEXT);
                CREATE INDEX idx_logs_ts ON logs(ts DESC, id DESC);
                """
                try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
            }
        }

        func insert(turn: String, priority: Bool) throws {
            let body = "thread_id=\(turn)-session turn.id=\(turn) websocket request: "
                + "{\"type\":\"response.create\",\"model\":\"gpt-5.4\","
                + "\"service_tier\":\"\(priority ? "priority" : "default")\"}"
            try self.withDatabase { db in
                var statement: OpaquePointer?
                try #require(sqlite3_prepare_v2(
                    db, "INSERT INTO logs(ts, feedback_log_body) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK)
                defer { sqlite3_finalize(statement) }
                try #require(sqlite3_bind_int64(statement, 1, Int64(self.now.timeIntervalSince1970)) == SQLITE_OK)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                try #require(sqlite3_bind_text(statement, 2, body, -1, transient) == SQLITE_OK)
                try #require(sqlite3_step(statement) == SQLITE_DONE)
            }
        }

        func writeSessions() throws {
            for turn in ["priority", "standard"] {
                let timestamp = ISO8601DateFormatter().string(from: self.now)
                let lines = """
                {"type":"session_meta","timestamp":"\(timestamp)","payload":{"id":"\(turn)-session"}}
                {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-5.4"}}
                {"type":"event_msg","timestamp":"\(timestamp)",\
                "payload":{"type":"token_count","turn_id":"\(turn)","info":{"model":"gpt-5.4",\
                "total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
                """
                try Data((lines + "\n").utf8).write(to: self.sessions.appendingPathComponent("\(turn).jsonl"))
            }
        }

        func savePrices() throws {
            let json = #"{"openai":{"id":"openai","models":{"gpt-5.4":{"id":"gpt-5.4","cost":{"#
                + #""input":2,"output":8,"cache_read":0.5}}}}}"#
            let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
            try #require(ModelsDevCache.save(catalog: catalog, fetchedAt: self.now, cacheRoot: self.cache))
        }

        func snapshot(calendar: Calendar? = nil) async throws -> CostUsageTokenSnapshot {
            var options = CostUsageScanner.Options()
            options.codexSessionsRoot = self.sessions
            options.codexTraceDatabaseURL = self.database
            options.cacheRoot = self.cache
            options.calendar = calendar ?? self.calendar
            options.refreshMinIntervalSeconds = 0
            return try await CostUsageFetcher(scannerOptions: options).loadTokenSnapshot(
                provider: .codex,
                environment: [:],
                now: self.now,
                codexHomePath: self.root.path,
                historyDays: 1,
                allowPricingRefresh: false,
                refreshPricingInBackground: false,
                includePiSessions: false)
        }
    }
}
