import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

@Suite(.serialized)
struct CodexCombinedPriorityTests {
    private typealias Fixture = CodexCombinedCostTests.Fixture

    @Test(arguments: [false, true])
    func `retained Fast rows survive identical copies and remote suffixes without trace`(suffix: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let records = Self.records(fixture, id: "shared")
        try fixture.write(records, root: fixture.localSessions)
        try fixture.write(records + (suffix ? [Self.event(fixture, input: 200)] : []), root: fixture.remoteSessions)
        try fixture.write(Self.records(fixture, id: "independent"), root: fixture.remoteArchived)
        try Self.seedPriorityLedger(fixture)
        let db = fixture.localCache.appendingPathComponent("cost-usage/cost-usage.sqlite")
        let before = try Data(contentsOf: db)
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == (suffix ? 330 : 220))
        #expect(abs((result.last30DaysCostUSD ?? -1) - (suffix ? 0.001 : 0.00075)) < 1e-9)
        let modes = try #require(result.daily.first?.modelBreakdowns?.first)
        #expect(modes.priorityTokens == 110)
        #expect(modes.standardTokens == (suffix ? 220 : 110))
        #expect(try Data(contentsOf: db) == before)
        let repeated = try fixture.scan(name: "repeat", reverse: true)
        #expect(repeated.daily == result.daily)
    }

    @Test
    func `retained row identity mismatch still fails closed`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(Self.records(fixture, id: "local"), root: fixture.localSessions)
        try Self.seedPriorityLedger(fixture, changeIdentity: true)
        #expect(throws: CodexCombinedCostError.pricingEvidence) { try fixture.scan() }
    }

    @Test
    func `unknown retained Fast price remains unknown`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(
            Self.records(fixture, id: "local", model: "codex-fictitious-unpriced"),
            root: fixture.localSessions)
        try Self.seedPriorityLedger(fixture, pricingModel: "codex-fictitious-unpriced")
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == 110)
        #expect(result.last30DaysCostUSD == nil)
    }

    @Test
    func `pricing reconciliation preserves cancellation`() throws {
        #expect(throws: CancellationError.self) {
            var cache = CostUsageCache()
            cache.files["synthetic"] = CostUsageFileUsage(mtimeUnixMs: 0, size: 0, days: [:])
            _ = try CodexCombinedPriorityEvidence().applying(
                to: cache,
                range: .init(since: Date(), until: Date()),
                checkCancellation: { throw CancellationError() })
        }
    }

    #if canImport(SQLite3)
    @Test
    func `native Fast ledger survives combined scan before and after trace removal`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let prefix = Self.records(fixture, id: "shared")
        try fixture.write(prefix, root: fixture.localSessions)
        try fixture.write(prefix + [Self.event(fixture, input: 200)], root: fixture.remoteSessions)
        try fixture.writeTrace(thread: "shared", turn: "fast-turn", model: "gpt-5.4")
        let trace = fixture.localHome.appendingPathComponent("logs_2.sqlite")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: fixture.localSessions, cacheRoot: fixture.localCache,
            codexTraceDatabaseURL: trace, calendar: fixture.calendar)
        options.codexFrozenPricing = CodexCombinedPricingContext.freeze(request: fixture.request)
        let local = CostUsageScanner.loadDailyReport(
            provider: .codex, since: fixture.now, until: fixture.now, now: fixture.now, options: options)
        #expect(abs((local.summary?.totalCostUSD ?? -1) - 0.0005) < 1e-9)
        let db = fixture.localCache.appendingPathComponent("cost-usage/cost-usage.sqlite")
        let before = try Data(contentsOf: db)
        #expect(try abs((fixture.scan().last30DaysCostUSD ?? -1) - 0.001) < 1e-9)
        #expect(try Data(contentsOf: db) == before)
        try FileManager.default.removeItem(at: trace)
        #expect(try abs((fixture.scan(name: "no-trace").last30DaysCostUSD ?? -1) - 0.00075) < 1e-9)
        #expect(try Data(contentsOf: db) == before)
    }

    @Test(arguments: [false, true])
    func `trace prices only its session across prefix suffix and window boundaries`(oldRequest: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let prefix = Self.records(fixture, id: "shared")
        try fixture.write(prefix, root: fixture.localSessions)
        try fixture.write(prefix + [Self.event(fixture, input: 200)], root: fixture.remoteSessions)
        try fixture.writeTrace(thread: "shared", turn: "fast-turn", model: "gpt-5.4")
        let db = fixture.localHome.appendingPathComponent("logs_2.sqlite")
        if oldRequest {
            try Self.withDatabase(db) { database in
                try #require(sqlite3_exec(database, "UPDATE logs SET ts = ts - 691200", nil, nil, nil) == SQLITE_OK)
            }
        }
        let before = try Data(contentsOf: db)
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == 220)
        #expect(abs((result.last30DaysCostUSD ?? -1) - 0.001) < 1e-9)
        #expect(result.daily.first?.modelBreakdowns?.first?.priorityTokens == 220)
        #expect(try Data(contentsOf: db) == before)
    }

    @Test(arguments: [false, true])
    func `threadless and foreign request collisions fail in both orders`(foreignFirst: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(Self.records(fixture, id: "local"), root: fixture.localSessions)
        try fixture.writeTrace(thread: foreignFirst ? "foreign" : nil, turn: "fast-turn", model: "gpt-5.4")
        let prefix = foreignFirst ? "" : "thread_id=foreign "
        try Self.appendTrace(
            fixture,
            body: prefix + "turn.id=fast-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.4","service_tier":"priority"}"#)
        #expect(throws: CodexCombinedCostError.pricingEvidence) { try fixture.scan() }
    }

    @Test(arguments: ["local", "foreign", "missing"])
    func `completion model override requires the same trace owner`(owner: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(Self.records(fixture, id: "local", model: "gpt-5.2-codex"), root: fixture.localSessions)
        try fixture.writeTrace(thread: "local", turn: "fast-turn", model: "gpt-5.2-codex")
        let prefix = owner == "missing" ? "" : "thread_id=\(owner) "
        try Self.appendTrace(
            fixture,
            body: prefix + "turn.id=fast-turn websocket event: "
                + #"{"type":"response.completed","response":{"model":"gpt-5.4"}}"#)
        if owner == "local" {
            let result = try fixture.scan()
            #expect(abs((result.last30DaysCostUSD ?? -1) - 0.0005) < 1e-9)
        } else {
            #expect(throws: CodexCombinedCostError.pricingEvidence) { try fixture.scan() }
        }
    }

    @Test
    func `model free priority submission preserves retained Fast pricing model`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(Self.records(fixture, id: "local", model: "gpt-5.2-codex"), root: fixture.localSessions)
        try Self.seedPriorityLedger(fixture)
        try Self.appendTrace(
            fixture,
            body: "session_loop{thread_id=local}: Submission sub=Submission { "
                +
                #"id: "fast-turn", thread_settings: ThreadSettingsOverrides { service_tier: Some(Some("priority")) }"#)
        #expect(try abs((fixture.scan().last30DaysCostUSD ?? -1) - 0.0005) < 1e-9)
    }

    @Test(arguments: [false, true])
    func `trace with skipped task identity never silently becomes standard`(oldRequest: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var records = fixture.records(id: "local", model: "gpt-5.4")
        records.insert(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "fast-turn"]], at: 2)
        try fixture.write(records, root: fixture.localSessions)
        try fixture.writeTrace(thread: "local", turn: "fast-turn", model: "gpt-5.4")
        if oldRequest {
            try Self.withDatabase(fixture.localHome.appendingPathComponent("logs_2.sqlite")) { database in
                try #require(sqlite3_exec(database, "UPDATE logs SET ts = ts - 691200", nil, nil, nil) == SQLITE_OK)
            }
        }
        #expect(throws: CodexCombinedCostError.unsupportedOverlap) { try fixture.scan() }
    }

    private static func appendTrace(_ fixture: Fixture, body: String) throws {
        try self.withDatabase(fixture.localHome.appendingPathComponent("logs_2.sqlite")) { database in
            try #require(sqlite3_exec(
                database,
                "CREATE TABLE IF NOT EXISTS logs(id INTEGER PRIMARY KEY, ts INTEGER, feedback_log_body TEXT)",
                nil,
                nil,
                nil) == SQLITE_OK)
            var prepared: OpaquePointer?
            try #require(sqlite3_prepare_v2(
                database,
                "INSERT INTO logs(ts, feedback_log_body) VALUES (?,?)",
                -1,
                &prepared,
                nil) ==
                SQLITE_OK)
            let statement = try #require(prepared)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(fixture.now.timeIntervalSince1970))
            _ = body.withCString {
                sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            try #require(sqlite3_step(statement) == SQLITE_DONE)
        }
    }
    #endif

    private static func records(_ fixture: Fixture, id: String, model: String = "gpt-5.4") -> [[String: Any]] {
        var records = fixture.records(id: id, model: model)
        records[2] = self.event(fixture, model: model)
        return records
    }

    private static func event(_ fixture: Fixture, input: Int = 100, model: String = "gpt-5.4") -> [String: Any] {
        var event = fixture.event(input: input, cached: input / 5, output: input / 10, model: model)
        var payload = event["payload"] as? [String: Any] ?? [:]
        payload["turn_id"] = "fast-turn"
        event["payload"] = payload
        return event
    }

    /// Seed the native ledger, then emulate retained trace pricing after the trace source has disappeared.
    /// The row and both aggregate tables must agree; a separate test covers aggregate-only corruption.
    private static func seedPriorityLedger(
        _ fixture: Fixture, pricingModel: String = "gpt-5.4", changeIdentity: Bool = false) throws
    {
        try fixture.seedLedger(home: fixture.localHome)
        let url = fixture.localCache.appendingPathComponent("cost-usage/cost-usage.sqlite")
        try self.withDatabase(url) { database in
            let stored = try #require(CostUsageStore.readUsageRows(database, path: nil).first)
            var row = try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: stored.payload)
            row.pricingMode = "priority"
            row.pricingModel = pricingModel
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            if changeIdentity { object["eventIndex"] = 999 }
            let data = try JSONSerialization.data(withJSONObject: object)
            var prepared: OpaquePointer?
            try #require(sqlite3_prepare_v2(database, "UPDATE usage_rows SET payload = ?", -1, &prepared, nil) ==
                SQLITE_OK)
            let statement = try #require(prepared)
            defer { sqlite3_finalize(statement) }
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(
                    statement,
                    1,
                    $0.baseAddress,
                    Int32(data.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            try #require(sqlite3_step(statement) == SQLITE_DONE)
            try #require(sqlite3_changes(database) == 1)
            for table in ["file_day_aggregates", "day_aggregates"] {
                let sql = "UPDATE \(table) SET priority_tokens=110, priority_input_tokens=100, "
                    + "priority_cached_tokens=20, priority_output_tokens=10, standard_tokens=0, "
                    + "standard_input_tokens=0, standard_cached_tokens=0, standard_output_tokens=0"
                try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
                try #require(sqlite3_changes(database) == 1)
            }
            try #require(sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK)
        }
    }

    private static func withDatabase(_ url: URL, body: (OpaquePointer) throws -> Void) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open(url.path, &opened)
        defer { if let opened { sqlite3_close(opened) } }
        try #require(result == SQLITE_OK)
        let database = try #require(opened)
        try #require(sqlite3_busy_timeout(database, 5000) == SQLITE_OK)
        try body(database)
    }
}
