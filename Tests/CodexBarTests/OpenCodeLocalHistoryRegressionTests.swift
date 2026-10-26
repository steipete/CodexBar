import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct OpenCodeLocalHistoryRegressionTests {
    private static let timestamp: Int64 = 1_772_798_400_000

    private struct Fixture {
        let root: URL
        let url: URL

        init() throws {
            self
                .root = URL(fileURLWithPath: ProcessInfo.processInfo
                    .environment["CFFIXED_USER_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: self.root,
                withIntermediateDirectories: true)
            self.url = self.root.appendingPathComponent("source.db")
            try self.sql("""
            CREATE TABLE message(id TEXT PRIMARY KEY, data TEXT, time_created INTEGER, time_updated INTEGER);
            CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, data TEXT,
              time_created INTEGER, time_updated INTEGER);
            CREATE INDEX part_message ON part(message_id);
            CREATE TABLE session_message(id TEXT PRIMARY KEY, type TEXT, data TEXT,
              time_created INTEGER, time_updated INTEGER);
            """)
        }

        func sql(_ sql: String) throws {
            let previousModification = (try? FileManager.default
                .attributesOfItem(atPath: self.url.path)[.modificationDate])
                as? Date ?? Date()
            var database: OpaquePointer?
            #expect(sqlite3_open(self.url.path, &database) == SQLITE_OK)
            defer {
                sqlite3_close(database)
                try? FileManager.default.setAttributes(
                    [.modificationDate: previousModification.addingTimeInterval(1)],
                    ofItemAtPath: self.url.path)
            }
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }

        func message(
            _ id: String,
            cost: Int) throws
        {
            try self.sql("""
            INSERT INTO message VALUES ('\(id)',
              '{"providerID":"openai","role":"assistant","modelID":"fixture-model","cost":\(cost)}',
              \(OpenCodeLocalHistoryRegressionTests.timestamp), \(OpenCodeLocalHistoryRegressionTests.timestamp));
            """)
        }

        func part(
            _ id: String,
            type: String = "step-finish",
            cost: Int) throws
        {
            try self.sql("""
            INSERT INTO part VALUES ('\(id)', 'm', '{"type":"\(type)","cost":\(cost)}',
              \(OpenCodeLocalHistoryRegressionTests.timestamp),
              \(OpenCodeLocalHistoryRegressionTests.timestamp + 1000));
            """)
        }

        func session(
            _ id: String,
            cost: Int) throws
        {
            try self.sql("""
            INSERT INTO session_message VALUES ('\(id)', 'assistant',
              '{"model":{"providerID":"openai","id":"fixture-model"},"cost":\(cost)}',
              \(OpenCodeLocalHistoryRegressionTests.timestamp), \(OpenCodeLocalHistoryRegressionTests.timestamp));
            """)
        }

        func store() -> CostUsageStore { CostUsageStore(cacheRoot: self.root.appendingPathComponent("cache")) }

        func pass(_ budget: Int = 100) async throws -> OpenCodeLocalHistoryAdapter.PassOutcome? {
            try await OpenCodeLocalHistoryAdapter.runPass(
                databaseURL: self.url,
                store: self.store(),
                rowBudget: budget)
        }

        func total() async -> Double {
            let aggregates = await OpenCodeLocalHistoryAdapter.windowedAggregates(
                store: self.store(),
                path: self.url.path,
                sinceDay: "2000-01-01",
                untilDay: "2999-12-31")
            return aggregates.reduce(0) { $0 + Double($1.aggregate.authoritativeCostNanos) / 1e9 }
        }

        func remove() { try? FileManager.default.removeItem(at: self.root) }
    }

    @Test
    func `append overflow remains pending until every row is committed`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(
            "first",
            cost: 1)
        _ = try await fixture.pass()
        for index in 1...3 {
            try fixture.session(
                "append-\(index)",
                cost: 1)
        }
        for _ in 0..<5 {
            _ = try await fixture.pass(1)
        }
        let actualTotal = await fixture.total()
        #expect(actualTotal == 4)
    }

    @Test
    func `an append inside the read snapshot stays eligible on retry`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sql("PRAGMA journal_mode=WAL")
        try fixture.message(
            "before-snapshot",
            cost: 1)
        var appended = false
        _ = try await OpenCodeLocalHistoryAdapter.runPass(
            databaseURL: fixture.url,
            store: fixture.store(),
            checkCancellation: {
                guard !appended else { return }
                appended = true
                try fixture.message(
                    "inside-snapshot",
                    cost: 2)
            })
        _ = try await fixture.pass()
        let actualTotal = await fixture.total()
        #expect(actualTotal == 3)
    }

    @Test
    func `resuming past an invalid last part does not add message fallback`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.message(
            "m",
            cost: 9)
        try fixture.part(
            "valid",
            cost: 1)
        try fixture.part(
            "invalid",
            type: "text",
            cost: 0)
        _ = try await fixture.pass(1)
        _ = try await fixture.pass(1)
        let actualTotal = await fixture.total()
        #expect(actualTotal == 1)
    }

    @Test
    func `late parts exceeding the mutation budget replace the fallback completely`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.message(
            "m",
            cost: 5)
        _ = try await fixture.pass()
        for index in 1...3 {
            try fixture.part(
                "late-\(index)",
                cost: index)
        }
        for _ in 0..<5 {
            _ = try await fixture.pass(2)
        }
        let actualTotal = await fixture.total()
        #expect(actualTotal == 6)
    }

    @Test
    func `deleted source rows are removed by bounded subsequent passes`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(
            "deleted",
            cost: 3)
        _ = try await fixture.pass()
        try fixture.sql("DELETE FROM session_message WHERE id = 'deleted'")
        for _ in 0..<5 {
            _ = try await fixture.pass(2)
        }
        let actualTotal = await fixture.total()
        #expect(actualTotal == 0)
    }

    @Test
    func `recorded zero remains present when publishing stored aggregates without the source`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(
            "recorded-zero",
            cost: 0)
        try fixture.sql("""
        INSERT INTO session_message VALUES ('boolean-cost', 'assistant',
          '{"model":{"providerID":"openai","id":"fixture-model"},"cost":false}',
          \(Self.timestamp), \(Self.timestamp))
        """)
        _ = try await fixture.pass()
        try FileManager.default.removeItem(at: fixture.url)
        let day = OpenCodeLocalHistoryAdapter.dayKey(fromUnixMs: Self.timestamp)
        let aggregates = await OpenCodeLocalHistoryAdapter.windowedAggregates(
            store: fixture.store(),
            path: fixture.url.path,
            sinceDay: day,
            untilDay: day)
        let entries = OpenCodeLocalHistoryAdapter.reportEntries(from: aggregates)
        #expect(entries.count == 1)
        #expect(entries.first?.costUSD == 0)
        #expect(entries.first?.requestCount == 1)
        #expect(entries.first?.modelBreakdowns?.first?.sourceRecorded == true)
    }

    @Test
    func `two updated parts do not reevaluate their parent twice`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.message(
            "m",
            cost: 9)
        try fixture.part(
            "first",
            cost: 1)
        try fixture.part(
            "second",
            cost: 1)
        _ = try await fixture.pass()
        try fixture.sql("""
        UPDATE part SET data = '{"type":"step-finish","cost":2}', time_updated = \(Self.timestamp + 2000);
        """)
        let outcome = try await fixture.pass()
        guard case let .applied(summary) = outcome else {
            Issue.record("Expected the updated parent and parts to be read once")
            return
        }
        #expect(summary.rawRowsRead == 3)
        let actualTotal = await fixture.total()
        #expect(actualTotal == 4)
    }

    @Test
    func `retention reclaims old usage rows while keeping recent source history`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(
            "old",
            cost: 1)
        try fixture.session(
            "recent",
            cost: 1)
        try fixture.sql("UPDATE session_message SET time_created = time_created - 86400000 WHERE id = 'old'")
        _ = try await fixture.pass()
        let day = OpenCodeLocalHistoryAdapter.dayKey(fromUnixMs: Self.timestamp)
        let store = fixture.store()
        _ = await store.retainDayWindow(
            sinceDay: day,
            untilDay: day)
        let rows = await store.withDatabase(default: [CostUsageStoreUsageRow]()) { database in
            try CostUsageStore.readUsageRows(
                database,
                path: fixture.url.path)
        }
        #expect(rows.count == 1)
        let retained = await store.readSnapshot()
        #expect(retained.files.first?.scanState.resumePayload == nil)
        _ = try await fixture.pass()
        #expect(await fixture.total() == 2)
    }

    @Test
    func `unrelated legacy rows do not suppress updated v2 messages`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.message(
            "unrelated",
            cost: 1)
        try fixture.session(
            "v2",
            cost: 2)
        _ = try await fixture.pass()
        try fixture.sql("""
        UPDATE session_message
        SET data = '{"model":{"providerID":"openai","id":"fixture-model"},"cost":3}',
            time_updated = \(Self.timestamp + 1000) WHERE id = 'v2';
        """)
        _ = try await fixture.pass()
        let actualTotal = await fixture.total()
        #expect(actualTotal == 4)
    }

    @Test
    func `updates sharing a timestamp converge across small raw row budgets`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 1...3 {
            try fixture.session(
                "session-\(index)",
                cost: 1)
        }
        _ = try await fixture.pass()
        try fixture.sql("""
        UPDATE session_message SET data = '{"model":{"providerID":"openai","id":"fixture-model"},"cost":2}',
          time_updated = \(Self.timestamp + 1000);
        """)
        for _ in 0..<16 {
            _ = try await fixture.pass(2)
        }
        let total = await fixture.total()
        #expect(total == 6)
    }

    @Test
    func `native scanner saves preserve the registered adapter source`() async throws {
        let native = try ReadWorkFixture(
            fileCount: 1,
            rowsPerFile: 1)
        defer { native.remove() }
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sql("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < 32)
        INSERT INTO session_message SELECT 'source-' || x, 'assistant',
          json_object('model', json_object('providerID', 'openai', 'id', 'fixture-source-' || x), 'cost', 1),
          \(Int64(native.now.timeIntervalSince1970 * 1000)), \(Self.timestamp) FROM n
        """)
        _ = try await OpenCodeLocalHistoryAdapter.runPass(
            databaseURL: fixture.url,
            store: native.store)
        let loaded = native.store.syncLoadCodexScan(calendar: native.calendar)
        defer { loaded.release() }
        var candidate = loaded.cache
        candidate.codexProjectMetadataVersion = 999
        let beforeWrites = await native.store.persistenceWriteMetricsForTesting()
        let saved = native.save(
            candidate,
            load: loaded)
        let afterWrites = await native.store.persistenceWriteMetricsForTesting()
        #expect(afterWrites.rows - beforeWrites.rows < 20)
        #expect(!saved.catchUpRequired)
        let snapshot = await native.store.readSnapshot()
        #expect(snapshot.fileDayAggregates.filter { $0.path == fixture.url.path }.count == 32)
        #expect(snapshot.files.contains { $0.path == fixture.url.path })
        #expect(snapshot.fileDayAggregates.reduce(0) { $0 + $1.aggregate.authoritativeCostNanos }
            == snapshot.dayAggregates.reduce(0) { $0 + $1.authoritativeCostNanos })
    }

    @Test
    func `database replacement at the same path invalidates old row windows`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(
            "old",
            cost: 3)
        _ = try await fixture.pass()
        try FileManager.default.removeItem(at: fixture.url)
        try fixture.sql("""
        CREATE TABLE session_message(id TEXT PRIMARY KEY, type TEXT, data TEXT,
              time_created INTEGER, time_updated INTEGER);
        """)
        try fixture.session(
            "replacement",
            cost: 2)
        for _ in 0..<3 {
            _ = try await fixture.pass(2)
        }
        let actualTotal = await fixture.total()
        #expect(actualTotal == 2)
    }

    @Test
    func `fixed raw budget has flat sqlite work at 1k 10k and 100k rows`() async throws {
        var measurements: [Int] = []
        for count in [1000, 10000, 100_000] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.message(
                "old-valid",
                cost: 1)
            try fixture.sql("""
            WITH RECURSIVE n(x) AS (VALUES(2) UNION ALL SELECT x+1 FROM n WHERE x < \(count))
            INSERT INTO message SELECT 'invalid-' || x, 'not-json', \(Self.timestamp), \(Self.timestamp) FROM n;
            """)
            let outcome = try await fixture.pass(2)
            guard case let .applied(summary) = outcome else {
                Issue.record("Expected a bounded applied pass")
                return
            }
            print("[opencode-work] corpus=\(count) budget=2 rows=\(summary.rawRowsRead) "
                + "vm_steps=\(summary.sqliteSteps) bytes=\(summary.payloadBytes)"
                + " pages=\(summary.sqliteCacheMisses)")
            #expect(summary.rawRowsRead <= 2)
            #expect(!summary.complete)
            measurements.append(summary.sqliteSteps)
        }
        #expect((measurements.max() ?? 0) - (measurements.min() ?? 0) <= 200)
    }

    @Test
    func `oversized source payloads are capped and never claim complete coverage`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.message("large", cost: 1)
        _ = try await fixture.pass()
        let text = String(
            repeating: "x",
            count: 8 * 1024 * 1024)
        try fixture.sql("""
        UPDATE message SET data =
          '{"providerID":"openai","role":"assistant","cost":1,"text":"\(text)"}',
          time_updated = \(Self.timestamp + 1000) WHERE id = 'large';
        """)
        let outcome = try await fixture.pass(2)
        guard case let .applied(summary) = outcome else {
            Issue.record("Expected a bounded applied pass")
            return
        }
        #expect(summary.payloadBytes <= OpenCodeLocalHistoryAdapter.maximumPassBytes)
        #expect(summary.sqliteCacheMisses <= 8)
        #expect(!summary.complete)
        #expect(await fixture.total() == 0)
        print("[opencode-work] oversized=8388608 bytes=\(summary.payloadBytes) "
            + "vm_steps=\(summary.sqliteSteps) pages=\(summary.sqliteCacheMisses)")
    }

    @Test
    func `calendar changes reconcile buckets without mixing old and new days`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(
            "midnight",
            cost: 2)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-03-06T00:30:00Z"))
        try fixture.sql("UPDATE session_message SET time_created = \(Int64(date.timeIntervalSince1970 * 1000))")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let store = fixture.store()
        _ = try await OpenCodeLocalHistoryAdapter.runPass(
            databaseURL: fixture.url,
            store: store,
            calendar: calendar)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        for _ in 0..<12 {
            _ = try await OpenCodeLocalHistoryAdapter.runPass(
                databaseURL: fixture.url,
                store: store,
                rowBudget: 1,
                calendar: calendar)
        }
        let snapshot = await store.readSnapshot()
        #expect(snapshot.fileDayAggregates.map(\.aggregate.day) == ["2026-03-05"])
        #expect(snapshot.dayAggregates.map(\.authoritativeCostNanos) == [2_000_000_000])
        let file = try #require(snapshot.files.first)
        #expect(file.scanState.isComplete)
        #expect(OpenCodeSourceCheckpoint.decode(file.scanState.resumePayload)?.rebuilding == false)
    }

    @Test
    func `unreadable refresh invalidates cached completeness but keeps recorded spend`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(
            "cached",
            cost: 3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let scope = OpenCodeLocalHistoryAdapter.ReadScope(
            path: fixture.url.path,
            roots: [],
            timeZoneIdentifier: calendar.timeZone.identifier)
        let cacheRoot = fixture.root.appendingPathComponent("cache")
        #expect(try await OpenCodeLocalHistoryAdapter.refresh(
            scope: scope,
            cacheRoot: cacheRoot,
            calendar: calendar))
        try Data("not a database".utf8).write(to: fixture.url)
        #expect(try await !OpenCodeLocalHistoryAdapter.refresh(
            scope: scope,
            cacheRoot: cacheRoot,
            calendar: calendar))
        let summary = try #require(await fixture.store()
            .withDatabase(default: OpenCodeLocalHistoryAdapter.StoredSummary?.none) {
                try OpenCodeLocalHistoryAdapter.StoredSummary.read(
                    $0,
                    scope: scope,
                    purpose: .report)
            })
        #expect(summary.file?.scanState.isComplete == false)
        #expect(summary.hasPendingWork)
        #expect(summary.aggregates.reduce(0) { $0 + $1.aggregate.authoritativeCostNanos } == 3_000_000_000)
    }

    @Test
    func `sqlite work stops at instruction and cancellation boundaries`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OpenCodeLocalHistoryAdapter.Source(
            databaseURL: fixture.url,
            rowBudget: 1,
            checkCancellation: nil)
        defer { source.close() }
        let code = sqlite3_exec(
            source.database,
            """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < 1000000) SELECT sum(x) FROM n
            """,
            nil,
            nil,
            nil)
        #expect(code == SQLITE_INTERRUPT)
        #expect(source.budget.failure is OpenCodeLocalHistoryAdapter.ReadBudget.Limit)
        #expect(throws: CancellationError.self) {
            let cancelled = try OpenCodeLocalHistoryAdapter.Source(
                databaseURL: fixture.url,
                rowBudget: 1,
                checkCancellation: { throw CancellationError() })
            defer { cancelled.close() }
            _ = try cancelled.row(table: .message)
        }
    }

    @Test
    func `native baseline excludes source payloads and aggregates`() async throws {
        let native = try ReadWorkFixture(
            fileCount: 1,
            rowsPerFile: 1)
        defer { native.remove() }
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(
            "external",
            cost: 7)
        _ = try await OpenCodeLocalHistoryAdapter.runPass(
            databaseURL: fixture.url,
            store: native.store)
        let snapshot = try #require(await native.store.withDatabase(default: CostUsageStoreSnapshot?.none) {
            try CostUsageStore.readSnapshot(
                $0,
                loadTokenSnapshots: false,
                loadUsageRows: false,
                nativeOnly: true,
                recorder: nil)
        })
        #expect(snapshot.dayAggregates.isEmpty)
        #expect(snapshot.fileDayAggregates.allSatisfy { $0.path != fixture.url.path })
        _ = await native.store.withDatabase(default: ()) { database in
            try CostUsageStore.execute(database, """
            UPDATE file_day_aggregates SET input_tokens = 0, cached_tokens = 0, output_tokens = 0
            WHERE file_id IN (SELECT id FROM files WHERE path != '\(fixture.url.path)')
            """)
        }
        let load = native.store.syncLoadCodexScan(calendar: native.calendar)
        defer { load.release() }
        #expect(load.cache.files[fixture.url.path] == nil)
        #expect(load.cache.files.count == 1)
        #expect(!load.cache.days.isEmpty)
        #expect(load.cache.days.values.flatMap(\.values).allSatisfy { $0 == [0, 0, 0] })
    }

    @Test
    func `task cancellation cannot publish a source checkpoint`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session("cancelled", cost: 3)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.pass()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let snapshot = await fixture.store().readSnapshot()
        #expect(snapshot.files.isEmpty)
    }

    @Test
    func `sqlite progress handler honors the wall clock deadline`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OpenCodeLocalHistoryAdapter.Source(
            databaseURL: fixture.url, rowBudget: 1, checkCancellation: nil)
        defer { source.close() }
        try await Task.sleep(for: .milliseconds(600))
        let code = sqlite3_exec(
            source.database,
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < 1000000) SELECT sum(x) FROM n",
            nil,
            nil,
            nil)
        #expect(code == SQLITE_INTERRUPT)
        guard let limit = source.budget.failure as? OpenCodeLocalHistoryAdapter.ReadBudget.Limit,
              case .deadline = limit
        else {
            Issue.record("Expected the SQL deadline to interrupt work")
            return
        }
    }

    @Test
    func `changing parent revisions cannot starve a one row part continuation`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.message("m", cost: 9)
        for index in 1...3 {
            try fixture.part("part-\(index)", cost: index)
        }
        _ = try await fixture.pass(1)
        for index in 1...8 {
            try fixture.sql("UPDATE message SET time_updated = \(Self.timestamp + Int64(index) * 1000)")
            _ = try await fixture.pass(1)
        }
        #expect(await fixture.total() == 6)
        for _ in 0..<20 {
            _ = try await fixture.pass(1)
        }
        #expect(await fixture.total() == 6)
        let snapshot = await fixture.store().readSnapshot()
        #expect(snapshot.files.first?.scanState.isComplete == true)
    }

    @Test
    func `composite part indexes cannot make fixed budget SQL work scale with history`() async throws {
        var measurements: [Int] = []
        for count in [1000, 10000, 100_000] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.message("m", cost: 9)
            try fixture.sql("""
            DROP INDEX part_message;
            CREATE INDEX part_message_time ON part(message_id, time_created);
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < \(count))
            INSERT INTO part SELECT 'part-' || x, 'm', '{"type":"step-finish","cost":1}',
              \(Self.timestamp) + \(count) - x, \(Self.timestamp) FROM n;
            """)
            let outcome = try await fixture.pass(2)
            guard case let .applied(summary) = outcome else {
                Issue.record("Expected a bounded part pass")
                return
            }
            print("[opencode-work] kind=composite-part-index corpus=\(count) budget=2 "
                + "rows=\(summary.rawRowsRead) vm_steps=\(summary.sqliteSteps) bytes=\(summary.payloadBytes)"
                + " pages=\(summary.sqliteCacheMisses)")
            #expect(summary.rawRowsRead == 2)
            #expect(!summary.complete)
            #expect(await fixture.total() == 1)
            measurements.append(summary.sqliteSteps)
        }
        #expect((measurements.max() ?? 0) - (measurements.min() ?? 0) <= 200)
    }

    @Test
    func `parent validation alone is visible as catch up progress`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.message("m", cost: 9)
        try fixture.part("first", cost: 1)
        try fixture.part("second", cost: 1)
        let scope = OpenCodeLocalHistoryAdapter.ReadScope(
            path: fixture.url.path, roots: [], timeZoneIdentifier: Calendar.current.timeZone.identifier)
        func progress() async -> String? {
            await fixture.store().withDatabase(default: String?.none) { database in
                try OpenCodeLocalHistoryAdapter.StoredSummary.read(database, scope: scope, purpose: .status).progressKey
            }
        }
        _ = try await fixture.pass(1)
        _ = try await fixture.pass(1)
        let before = try #require(await progress())
        _ = try await fixture.pass(1)
        let after = try #require(await progress())
        #expect(after != before)
        _ = try await fixture.pass(1)
        #expect(await fixture.total() == 2)
    }

    @Test
    func `partial sweeps retain cached costs and unknown token counts`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session("unknown-counters", cost: 2)
        _ = try await fixture.pass()
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: Double(Self.timestamp) / 1000)
        let range = CostUsageScanner.CostUsageDayRange(since: date, until: date, calendar: calendar)
        let scope = OpenCodeLocalHistoryAdapter.ReadScope(
            path: OpenCodeLocalHistoryAdapter.registeredPath(for: fixture.url),
            roots: [],
            timeZoneIdentifier: calendar.timeZone.identifier,
            sinceDay: range.sinceKey,
            untilDay: range.untilKey)
        func summary() async -> OpenCodeLocalHistoryAdapter.StoredSummary? {
            await fixture.store().withDatabase(default: OpenCodeLocalHistoryAdapter.StoredSummary?.none) { database in
                try OpenCodeLocalHistoryAdapter.StoredSummary.read(database, scope: scope, purpose: .activity)
            }
        }
        let complete = try #require(await summary())
        #expect(complete.report(range).data.first?.costUSD == 2)
        #expect(complete.report(range).data.first?.totalTokens == nil)

        try fixture.sql("UPDATE session_message SET time_updated = time_updated + 1")
        _ = try await fixture.pass(1)
        let updating = try #require(await summary())
        #expect(!updating.covers(range))
        #expect(updating.report(range).data.first?.costUSD == 2)
        #expect(updating.report(range).data.first?.totalTokens == nil)
        _ = try await fixture.pass()

        _ = try await OpenCodeLocalHistoryAdapter.runPass(
            databaseURL: fixture.url,
            store: fixture.store(),
            rowBudget: 1,
            calendar: calendar,
            sinceDay: range.sinceKey,
            untilDay: range.untilKey)
        let resized = try #require(await summary())
        #expect(!resized.covers(range))
        #expect(resized.report(range).data.first?.costUSD == 2)
        #expect(resized.report(range).data.first?.totalTokens == nil)
    }
}
