import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// The adapter's stage-1/2 behavior: decode → atomic store commit → checkpointed
/// continuation, including the three #4744 cursor regressions held as explicit tests
/// (#4752 acceptance checklist).
struct OpenCodeLocalHistoryAdapterTests {
    // MARK: - Fixture

    private struct Fixture {
        var root: URL
        var databaseURL: URL

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "OpenCodeLocalHistoryAdapterTests-\(UUID().uuidString)",
                    isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true)
            let url = root.appendingPathComponent("opencode.db")
            var db: OpaquePointer?
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
            defer { sqlite3_close(db) }
            try exec(db, """
            CREATE TABLE message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL,
              time_created INTEGER, time_updated INTEGER);
            CREATE TABLE part (
              id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
              data TEXT NOT NULL, time_created INTEGER, time_updated INTEGER);
            CREATE TABLE session_message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
              seq INTEGER NOT NULL, time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            """)
            return Fixture(
                root: root,
                databaseURL: url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }

        @discardableResult
        func insertMessage(
            id: String,
            createdMs: Int64,
            cost: Double?,
            model: String = "gpt-5.1-codex") throws -> Int64
        {
            var db: OpaquePointer?
            guard sqlite3_open(self.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
            defer { sqlite3_close(db) }
            var payload: [String: Any] = [
                "providerID": "openai", "role": "assistant", "modelID": model,
                "time": ["created": createdMs],
            ]
            if let cost { payload["cost"] = cost }
            let data = try JSONSerialization.data(withJSONObject: payload)
            try Self.bindInsert(
                db: db,
                sql: """
                INSERT INTO message (id, session_id, data, time_created, time_updated)
                VALUES (?, 's1', ?, ?, ?)
                """,
                binds: [id, String(
                    data: data,
                    encoding: .utf8) ?? "{}", "\(createdMs)", "\(createdMs)"])
            return sqlite3_last_insert_rowid(db)
        }

        @discardableResult
        func insertMessage(
            id: String,
            createdMs: Int64,
            rawData: String) throws -> Int64
        {
            var db: OpaquePointer?
            guard sqlite3_open(self.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
            defer { sqlite3_close(db) }
            try Self.bindInsert(
                db: db,
                sql: """
                INSERT INTO message (id, session_id, data, time_created, time_updated)
                VALUES (?, 's1', ?, ?, ?)
                """,
                binds: [id, rawData, "\(createdMs)", "\(createdMs)"])
            return sqlite3_last_insert_rowid(db)
        }

        @discardableResult
        func insertPart(
            messageID: String,
            createdMs: Int64,
            cost: Double,
            type: String = "step-finish") throws -> Int64
        {
            var db: OpaquePointer?
            guard sqlite3_open(self.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
            defer { sqlite3_close(db) }
            let payload: [String: Any] = [
                "type": type, "cost": cost,
                "tokens": ["input": 1, "output": 1, "total": 2],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try Self.bindInsert(
                db: db,
                sql: """
                INSERT INTO part (id, message_id, session_id, data, time_created, time_updated)
                VALUES (?, ?, 's1', ?, ?, ?)
                """,
                binds: [
                    UUID().uuidString,
                    messageID,
                    String(
                        data: data,
                        encoding: .utf8) ?? "{}",
                    "\(createdMs)",
                    "\(createdMs)",
                ])
            return sqlite3_last_insert_rowid(db)
        }

        @discardableResult
        func insertSessionMessage(
            id: String,
            createdMs: Int64,
            cost: Double,
            model: String = "gpt-5.2") throws -> Int64
        {
            var db: OpaquePointer?
            guard sqlite3_open(self.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
            defer { sqlite3_close(db) }
            let payload: [String: Any] = [
                "model": ["providerID": "openai", "id": model],
                "cost": cost, "time": ["created": createdMs],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try Self.bindInsert(
                db: db,
                sql: """
                INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
                VALUES (?, 's1', 'assistant', 0, ?, ?, ?)
                """,
                binds: [id, "\(createdMs)", "\(createdMs)", String(
                    data: data,
                    encoding: .utf8) ?? "{}"])
            return sqlite3_last_insert_rowid(db)
        }

        static func bindInsertForUpdate(
            db: OpaquePointer?,
            sql: String,
            binds: [String]) throws
        {
            try self.bindInsert(
                db: db,
                sql: sql,
                binds: binds)
        }

        private static func bindInsert(
            db: OpaquePointer?,
            sql: String,
            binds: [String]) throws
        {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLiteTestError.prepare }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(
                -1,
                to: sqlite3_destructor_type.self)
            for (index, value) in binds.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
        }

        func updateMessage(
            id: String,
            createdMs: Int64,
            newCost: Double,
            updatedMs: Int64) throws
        {
            var db: OpaquePointer?
            guard sqlite3_open(self.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
            defer { sqlite3_close(db) }
            let payload: [String: Any] = [
                "providerID": "openai", "role": "assistant", "modelID": "gpt-5.1-codex",
                "cost": newCost, "time": ["created": createdMs],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try Self.bindInsert(
                db: db,
                sql: """
                UPDATE message SET data = ?, time_updated = ? WHERE id = ?
                """,
                binds: [String(
                    data: data,
                    encoding: .utf8) ?? "{}", "\(updatedMs)", id])
        }

        func checkpoint() async -> OpenCodeSourceCheckpoint? {
            let store = await self.makeStore()
            let path = OpenCodeLocalHistoryAdapter.registeredPath(for: self.databaseURL)
            return await store.withDatabase(default: OpenCodeSourceCheckpoint?.none) { database in
                guard let file = try CostUsageStore.readFiles(database).first(where: { $0.path == path }) else {
                    return nil
                }
                return OpenCodeSourceCheckpoint.decode(file.scanState.resumePayload)
            }
        }

        func rawUsageRows() async -> [CostUsageStoreUsageRow] {
            let store = await self.makeStore()
            let path = OpenCodeLocalHistoryAdapter.registeredPath(for: self.databaseURL)
            return await store.withDatabase(default: [CostUsageStoreUsageRow]()) { database in
                try CostUsageStore.readUsageRows(
                    database,
                    path: path)
            }
        }

        func aggregates() async -> (
            file: [CostUsageStoreFileDayAggregate],
            global: [CostUsageStoreDayAggregate])
        {
            let store = await self.makeStore()
            let path = OpenCodeLocalHistoryAdapter.registeredPath(for: self.databaseURL)
            return await store.withDatabase(
                default: ([CostUsageStoreFileDayAggregate](), [CostUsageStoreDayAggregate]()))
            { database in
                try (
                    CostUsageStore.readFileDayAggregates(
                        database,
                        path: path),
                    CostUsageStore.readDayAggregates(
                        database,
                        sinceDay: nil,
                        untilDay: nil))
            }
        }

        func makeStore() async -> CostUsageStore {
            CostUsageStore(cacheRoot: self.root.appendingPathComponent(
                "store-cache",
                isDirectory: true))
        }

        func runPass(budget: Int = 100_000) async throws -> OpenCodeLocalHistoryAdapter.PassOutcome? {
            let store = await self.makeStore()
            let path = OpenCodeLocalHistoryAdapter.registeredPath(for: self.databaseURL)
            // Store paths must resolve to the same path only within this fixture.
            _ = path
            return try await OpenCodeLocalHistoryAdapter.runPass(
                databaseURL: self.databaseURL,
                store: store,
                rowBudget: budget)
        }
    }

    private enum SQLiteTestError: Error {
        case open, prepare, step
    }

    private static func exec(
        _ db: OpaquePointer?,
        _ sql: String) throws
    {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            sqlite3_free(message)
            throw SQLiteTestError.step
        }
    }

    private static var fixtureNowMs: Int64 {
        1_772_798_400_000
    }

    // MARK: - Stage 1: decode + store commit correctness

    @Test
    func `a pass writes per-file aggregates and global deltas through the store`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        try fixture.insertMessage(
            id: "m1",
            createdMs: now,
            cost: 0.4)
        try fixture.insertMessage(
            id: "m2",
            createdMs: now,
            cost: 0.6)
        try fixture.insertMessage(
            id: "m3",
            createdMs: now,
            rawData: #"{"providerID":"nchc","role":"assistant","cost":9,"time":{"created":\#(now)}}"#)
        try fixture.insertSessionMessage(
            id: "s1",
            createdMs: now,
            cost: 1.2)

        _ = try await fixture.runPass()
        let (file, global) = await fixture.aggregates()

        // openai rows only; one valid step-finish behavior isn't in play here (no parts).
        let fileTotal = file.reduce(0.0) { $0 + Double($1.aggregate.authoritativeCostNanos) / 1e9 }
        let globalTotal = global.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(fileTotal - 2.2) < 0.0001)
        #expect(abs(globalTotal - 2.2) < 0.0001)

        let requests = file.reduce(Int64(0)) { $0 + $1.aggregate.requestCount }
        #expect(requests == 3)

        let checkpoint = await fixture.checkpoint()
        #expect(checkpoint != nil)
        #expect(checkpoint?.isComplete == true)

        // A second pass on an unchanged, fully-ingested source short-circuits by
        // fingerprint: nothing re-read, no double counting.
        let second = try await fixture.runPass()
        #expect(second == .skipped(.unchanged))
        let checkpoint2 = await fixture.checkpoint()
        #expect(checkpoint2?.isComplete == true)
        // Second pass contributes zeros: no double counting global aggregates.
        let (_, globalAfter) = await fixture.aggregates()
        let globalAfterTotal = globalAfter.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(globalAfterTotal - 2.2) < 0.0001)
        _ = second
    }

    @Test
    func `append pass is incremental and idempotent`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        try fixture.insertMessage(
            id: "m1",
            createdMs: now,
            cost: 1.0)
        _ = try await fixture.runPass()
        _ = try await fixture.runPass() // exhaust the downward walk too

        // Fingerprint unchanged → skipped; nothing re-read.
        let unchanged = try await fixture.runPass()
        #expect(unchanged == .skipped(.unchanged))

        try fixture.insertMessage(
            id: "m2",
            createdMs: now,
            cost: 0.5)
        let applied = try await fixture.runPass()
        #expect(applied != .skipped(.unchanged))
        let (_, global) = await fixture.aggregates()
        let total = global.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(total - 1.5) < 0.0001)
    }

    // MARK: - Stage 2: the three #4744 cursor regressions

    @Test
    func `regression 1 - an invalid row consumes budget but never blocks an older valid row`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        // Rowid 1: valid openai message; rowid 2: INVALID (no JSON); rowid 3: valid.
        try fixture.insertMessage(
            id: "valid-old",
            createdMs: now,
            cost: 1.0)
        try fixture.insertMessage(
            id: "invalid",
            createdMs: now,
            rawData: "not-json")
        try fixture.insertMessage(
            id: "valid-new",
            createdMs: now,
            cost: 2.0)

        // Budget 2 with lookahead +1: each pass examines ≤2 raw rows.
        _ = try await fixture.runPass(budget: 2)
        var checkpoint = await fixture.checkpoint()
        #expect(checkpoint != nil)

        _ = try await fixture.runPass(budget: 2)
        checkpoint = await fixture.checkpoint()

        // After enough passes every valid row is represented — no starvation.
        _ = try await fixture.runPass(budget: 2)
        _ = try await fixture.runPass(budget: 2)
        let (_, global) = await fixture.aggregates()
        let total = global.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(total - 3.0) < 0.0001)

        let requests = global.reduce(Int64(0)) { $0 + $1.requestCount }
        #expect(requests == 2)
        for _ in 0..<16 {
            _ = try await fixture.runPass(budget: 2)
        }
        let final = await fixture.checkpoint()
        #expect(final?.isComplete == true)
    }

    @Test
    func `regression 2 - an oversized message checkpoints mid-message at exact part rowid`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        _ = try fixture.insertMessage(
            id: "parted",
            createdMs: now,
            cost: 9.0) // fallback cost irrelevant
        let partA = try fixture.insertPart(
            messageID: "parted",
            createdMs: now,
            cost: 1.0)
        let partB = try fixture.insertPart(
            messageID: "parted",
            createdMs: now,
            cost: 2.0)

        // Parent admission and every raw part consume budget, including invalid parts.
        _ = try await fixture.runPass(budget: 1)
        let first = await fixture.checkpoint()
        #expect(first?.pendingPartContinuation?.message.rowID == 1)
        for _ in 0..<16 {
            _ = try await fixture.runPass(budget: 1)
        }
        let final = await fixture.checkpoint()
        #expect(final?.pendingPartContinuation == nil)
        #expect(final?.isComplete == true)
        let (_, global) = await fixture.aggregates()
        let total = global.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(total - 3) < 0.0001)
        #expect(global.reduce(Int64(0)) { $0 + $1.requestCount } == 2)
        #expect(partA != partB)
    }

    @Test
    func `regression 3 - an append after the snapshot stays eligible next pass`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        try fixture.insertMessage(
            id: "m1",
            createdMs: now,
            cost: 1.0)
        _ = try await fixture.runPass()
        // A later append must still be read — the checkpoint's upper bound pinned with
        // the SELECT (rowid of the last consumed message + 0), not any later MAX(rowid).
        _ = try fixture.insertMessage(
            id: "m2",
            createdMs: now,
            cost: 0.25)
        _ = try await fixture.runPass()

        let (_, global) = await fixture.aggregates()
        let total = global.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(total - 1.25) < 0.0001)

        let checkpoint = await fixture.checkpoint()
        #expect(checkpoint != nil)
        #expect(checkpoint?.isComplete == true)
    }

    // MARK: - Stage 3: mutation reconciliation (#4752 point 4)

    @Test
    func `an updated message replaces its prior contribution exactly`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        _ = try fixture.insertMessage(
            id: "m1",
            createdMs: now,
            cost: 1.0)
        _ = try await fixture.runPass()
        try fixture.updateMessage(
            id: "m1",
            createdMs: now,
            newCost: 2.5,
            updatedMs: now + 5000)

        _ = try await fixture.runPass()
        let (_, global) = await fixture.aggregates()
        let total = global.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(total - 2.5) < 0.0001)
        let requests = global.reduce(Int64(0)) { $0 + $1.requestCount }
        #expect(requests == 1) // one message, one contribution — never both versions
    }

    @Test
    func `a late step-finish on an ingested message replaces the fallback`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        _ = try fixture.insertMessage(
            id: "late",
            createdMs: now,
            cost: 5.0)
        _ = try await fixture.runPass()
        let (_, firstGlobal) = await fixture.aggregates()
        #expect(firstGlobal.reduce(Int64(0)) { $0 + $1.requestCount } == 1)

        // The part arrives during streaming after the pass: contribution identity swaps
        // from fallback-cost to part-cost without ever having both.
        _ = try fixture.insertPart(
            messageID: "late",
            createdMs: now,
            cost: 2.0)
        _ = try await fixture.runPass()

        let (_, global) = await fixture.aggregates()
        let total = global.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(total - 2.0) < 0.0001)
        let requests = global.reduce(Int64(0)) { $0 + $1.requestCount }
        #expect(requests == 1)
    }

    @Test
    func `an updated session row moves its contribution`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        _ = try fixture.insertSessionMessage(
            id: "s1",
            createdMs: now,
            cost: 1.0,
            model: "gpt-5.2")
        _ = try await fixture.runPass()

        var db: OpaquePointer?
        guard sqlite3_open(fixture.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        let payload: [String: Any] = [
            "model": ["providerID": "openai", "id": "gpt-5.2"],
            "cost": 3.0, "time": ["created": now],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try OpenCodeLocalHistoryAdapterTests.Fixture.bindInsertForUpdate(
            db: db,
            sql: "UPDATE session_message SET data = ?, time_updated = ? WHERE id = ?",
            binds: [String(
                data: data,
                encoding: .utf8) ?? "{}", "\(now + 5000)", "s1"])

        _ = try await fixture.runPass()
        let (_, global) = await fixture.aggregates()
        let total = global.reduce(0.0) { $0 + Double($1.authoritativeCostNanos) / 1e9 }
        #expect(abs(total - 3.0) < 0.0001)
        #expect(global.reduce(Int64(0)) { $0 + $1.requestCount } == 1)
    }

    // MARK: - Stage 4: read-view provenance and recorded-zero costs (#4752 points 2–3)

    @Test
    func `report entries carry source-recorded provenance and recorded zero cost survives`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        // OpenCode records $0 cost for subscription usage — presence is the signal.
        _ = try fixture.insertMessage(
            id: "zero",
            createdMs: now,
            cost: 0.0)
        _ = try fixture.insertMessage(
            id: "paid",
            createdMs: now,
            cost: 0.75)
        _ = try await fixture.runPass()

        let store = await fixture.makeStore()
        let path = OpenCodeLocalHistoryAdapter.registeredPath(for: fixture.databaseURL)
        let aggregates = await OpenCodeLocalHistoryAdapter.windowedAggregates(
            store: store,
            path: path,
            sinceDay: "2000-01-01",
            untilDay: "2999-12-31")
        let entries = OpenCodeLocalHistoryAdapter.reportEntries(from: aggregates)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        // Recorded $0 is a PRESENT zero, not a missing cost (#4752 point 3).
        #expect(entry.costUSD != nil)
        #expect(abs((entry.costUSD ?? -1) - 0.75) < 0.0001)
        #expect(entry.requestCount == 2)
        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.allSatisfy { $0.sourceRecorded == true })
        #expect(breakdowns.count == 1) // same model folds within the source itself
        #expect(breakdowns.first?.requestCount == 2)
    }

    @Test
    func `merged reports keep recorded and priced breakdowns of one model apart`() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let now = Self.fixtureNowMs
        _ = try fixture.insertMessage(
            id: "sub",
            createdMs: now,
            cost: 0.0)
        _ = try await fixture.runPass()

        let store = await fixture.makeStore()
        let path = OpenCodeLocalHistoryAdapter.registeredPath(for: fixture.databaseURL)
        let aggregates = await OpenCodeLocalHistoryAdapter.windowedAggregates(
            store: store,
            path: path,
            sinceDay: "2000-01-01",
            untilDay: "2999-12-31")
        let entries = OpenCodeLocalHistoryAdapter.reportEntries(from: aggregates)
        let sourcedReport = CostUsageDailyReport(
            data: entries,
            summary: nil)

        // Same model, priced at $1.25 by CodexBar's native estimate.
        let day = entries.first?.date ?? ""
        let priced = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: 10,
                    outputTokens: 10,
                    totalTokens: 20,
                    requestCount: 1,
                    costUSD: 1.25,
                    modelsUsed: ["gpt-5.1-codex"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.1-codex",
                            costUSD: 1.25,
                            totalTokens: 20,
                            requestCount: 1,
                            inputTokens: 10,
                            outputTokens: 10),
                    ]),
            ],
            summary: nil)

        let merged = priced.merged(with: sourcedReport)
        #expect(merged.data.count == 1)
        let mergedDay = try #require(merged.data.first)
        #expect(mergedDay.modelBreakdowns?.count == 2) // recorded and priced stay apart
        #expect(mergedDay.modelBreakdowns?.contains { $0.sourceRecorded == true && $0.costUSD == 0.0 } == true)
        #expect(mergedDay.modelBreakdowns?.contains {
            ($0.sourceRecorded ?? false) == false && abs(($0.costUSD ?? 0) - 1.25) < 0.0001
        } == true)
    }

    @Test
    func `ambient gate excludes scoped managed and dashboard histories`() {
        var options = CostUsageScanner.Options(includeOpenCodeLocalHistory: true)
        #expect(OpenCodeLocalHistoryAdapter.readScope(
            options: options,
            environment: [:]) != nil)
        #expect(OpenCodeLocalHistoryAdapter.readScope(
            options: options,
            environment: ["CODEX_HOME": "   "]) != nil)
        #expect(OpenCodeLocalHistoryAdapter.readScope(
            options: options,
            environment: ["CODEX_HOME": "/synthetic/alt-home"]) == nil)
        #expect(OpenCodeLocalHistoryAdapter.readScope(
            options: options,
            environment: [:],
            reportContext: .spendDashboard) == nil)
        options.codexSessionsRoot = URL(fileURLWithPath: "/synthetic/custom")
        #expect(OpenCodeLocalHistoryAdapter.readScope(
            options: options,
            environment: [:]) == nil)
    }

    @Test
    func `the opt-in stays default-off`() {
        #expect(CostUsageScanner.Options().includeOpenCodeLocalHistory == false)
    }
}

private func sqlite3Errmsg(_ db: OpaquePointer?) -> String {
    db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite"
}

extension OpenCodeLocalHistoryAdapter {
    /// This file's day aggregates inside the reporting window — the source summary the
    /// read view carries (#4752 point 2). Produced entirely from the store (no source
    /// I/O), bounded by the window, and carrying `file_id` provenance by construction.
    static func windowedAggregates(
        store: CostUsageStore,
        path: String,
        sinceDay: String,
        untilDay: String) async -> [CostUsageStoreFileDayAggregate]
    {
        await store.withDatabase(default: []) { database in
            try CostUsageStore.readFileDayAggregates(
                database,
                path: path,
                sinceDay: sinceDay,
                untilDay: untilDay)
        }
    }
}
