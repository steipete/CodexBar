import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

@Suite(.serialized)
struct CodexCombinedCostTests {
    @Test
    func `identical copy is counted once with frozen custom pricing`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let records = fixture.records(id: "shared")
        try fixture.write(records, root: fixture.localSessions)
        try fixture.write(records, root: fixture.remoteArchived)
        let context = CodexCombinedPricingContext.freeze(request: fixture.request)
        try Data(#"{"gpt-5.2-codex":{"input":999,"output":999,"cacheRead":999}}"#.utf8)
            .write(to: fixture.pricingRoot.appendingPathComponent(CostUsageCustomPricing.fileName))
        let snapshot = try fixture.scan(pricing: context)
        let database = fixture.root.appendingPathComponent("work/cache/cost-usage/cost-usage.sqlite")
        let permissions = try FileManager.default.attributesOfItem(atPath: database.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let cacheDirectory = database.deletingLastPathComponent()
        #expect(try FileManager.default
            .attributesOfItem(atPath: cacheDirectory.path)[.posixPermissions] as? Int == 0o700)
        let ready = fixture.root.appendingPathComponent("work/ready")
        let contents = try #require(FileManager.default.enumerator(at: ready, includingPropertiesForKeys: nil))
        #expect(contents.compactMap { $0 as? URL }.allSatisfy { $0.pathExtension != "jsonl" })
        #expect(snapshot.last30DaysTokens == 110)
        #expect(abs((snapshot.last30DaysCostUSD ?? -1) - 0.00025) < 0.000000001)
        #expect(snapshot.projects.isEmpty && snapshot.sessions.isEmpty)
        print("combined A: tokens=\(snapshot.last30DaysTokens ?? -1), cost=\(snapshot.last30DaysCostUSD ?? -1)")
    }

    @Test
    func `verified prefix retains suffix and equal vectors in different sessions`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let prefix = fixture.records(id: "shared")
        try fixture.write(prefix, root: fixture.localSessions)
        try fixture.write(prefix + [fixture.event(input: 200, cached: 40, output: 20)], root: fixture.remoteSessions)
        try fixture.write(fixture.records(id: "distinct"), root: fixture.remoteArchived)
        let first = try fixture.scan()
        #expect(first.last30DaysTokens == 330)
        #expect(abs((first.last30DaysCostUSD ?? -1) - 0.00075) < 0.000000001)
        let repeated = try fixture.scan(name: "second", reverse: true)
        #expect(repeated.last30DaysTokens == first.last30DaysTokens)
        #expect(repeated.last30DaysCostUSD == first.last30DaysCostUSD)
        print("combined B+C+order: tokens=\(first.last30DaysTokens ?? -1), cost=\(first.last30DaysCostUSD ?? -1)")
    }

    @Test
    func `conflicting non usage records reordered and cropped logs fail closed`() throws {
        for variant in 0..<3 {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let prefix = fixture.records(id: "shared")
            let marker: [String: Any] = ["type": "response_item", "payload": ["text": "first"]]
            try fixture.write(prefix + [marker], root: fixture.localSessions)
            var conflicting = prefix + [marker]
            if variant == 0 { conflicting[3] = ["type": "response_item", "payload": ["text": "second"]] }
            if variant == 1 { conflicting.swapAt(1, 2) }
            if variant == 2 { conflicting.remove(at: 1) }
            try fixture.write(conflicting, root: fixture.remoteSessions)
            #expect(throws: CodexCombinedCostError.unsupportedOverlap) { try fixture.scan() }
        }
    }

    @Test
    func `remote only archived and old directory new record use the selected calendar`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(
            fixture.records(id: "remote"),
            root: fixture.remoteArchived.appendingPathComponent("2020/01/01"))
        let result = try fixture.scan()
        #expect(result.sessionTokens == 110)
        #expect(result.daily.map(\.date) == ["2026-09-16"])
    }

    @Test
    func `models dev only price remains available from a separate frozen catalog`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = "openai/codex-combined-fixture"
        let object: [String: Any] = ["openai": ["id": "openai", "models": ["codex-combined-fixture": [
            "id": "codex-combined-fixture", "cost": ["input": 3, "output": 12, "cache_read": 0.3],
        ]]]]
        let catalog = try JSONDecoder().decode(
            ModelsDevCatalog.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: fixture.now, cacheRoot: fixture.pricingRoot))
        try fixture.write(fixture.records(id: "remote", model: model), root: fixture.remoteSessions)
        let context = CodexCombinedPricingContext.freeze(request: fixture.request)
        try FileManager.default.removeItem(at: ModelsDevCache.cacheFileURL(cacheRoot: fixture.pricingRoot))
        let result = try fixture.scan(pricing: context)
        #expect(result.last30DaysTokens == 110)
        #expect(abs((result.last30DaysCostUSD ?? -1) - 0.000366) < 0.000000001)
        print(
            "combined models.dev-only: tokens=\(result.last30DaysTokens ?? -1), cost=\(result.last30DaysCostUSD ?? -1)")
    }

    @Test
    func `parent outside window is available across roots and missing parent is rejected`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parentTimestamp = "2026-09-01T12:00:00Z"
        let parent = fixture.records(id: "parent", timestamp: parentTimestamp)
        try fixture.write(parent, root: fixture.localSessions)
        let child: [[String: Any]] = [
            ["type": "session_meta", "timestamp": "2026-09-16T12:00:00Z", "payload": [
                "id": "child", "forked_from_id": "parent", "timestamp": parentTimestamp,
            ]],
            fixture.context(), fixture.event(input: 150, cached: 20, output: 15),
        ]
        try fixture.write(child, root: fixture.remoteSessions)
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == 55)
        try FileManager.default.removeItem(at: fixture.localSessions)
        #expect(throws: CodexCombinedCostError.missingAncestor) { try fixture.scan(name: "missing") }
    }

    @Test
    func `deleted local source retained in ledger causes fallback without database writes`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(fixture.records(id: "local"), root: fixture.localSessions)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: fixture.localSessions,
            cacheRoot: fixture.localCache,
            codexTraceDatabaseURL: fixture.root.appendingPathComponent("absent.sqlite"),
            calendar: fixture.calendar)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: fixture.now,
            until: fixture.now,
            now: fixture.now,
            options: options)
        #expect(report.summary?.totalTokens == 110)
        let db = fixture.localCache.appendingPathComponent("cost-usage/cost-usage.sqlite")
        let before = try Data(contentsOf: db)
        try FileManager.default.removeItem(at: fixture.localSessions)
        #expect(throws: CodexCombinedCostError.localCoverage) { try fixture.scan() }
        #expect(try Data(contentsOf: db) == before)
    }

    @Test
    func `retained priority evidence without trace cannot silently become standard`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(fixture.records(id: "local"), root: fixture.localSessions)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: fixture.localSessions,
            cacheRoot: fixture.localCache,
            codexTraceDatabaseURL: fixture.root.appendingPathComponent("absent.sqlite"),
            calendar: fixture.calendar)
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex, since: fixture.now, until: fixture.now, now: fixture.now, options: options)
        try #require(report.summary?.totalTokens == 110)
        let url = fixture.localCache.appendingPathComponent("cost-usage/cost-usage.sqlite")
        let priorityTokens: Int64 = try {
            var opened: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE, nil)
            defer { if let opened { sqlite3_close(opened) } }
            try #require(result == SQLITE_OK)
            let database = try #require(opened)
            // Scanner teardown may still briefly own the WAL lock. Match the existing SQLite test helper's bound.
            try #require(sqlite3_busy_timeout(database, 5000) == SQLITE_OK)
            try #require(sqlite3_exec(
                database,
                "UPDATE file_day_aggregates SET priority_tokens = 110",
                nil,
                nil,
                nil) ==
                SQLITE_OK)
            try #require(sqlite3_changes(database) == 1)
            var prepared: OpaquePointer?
            let prepare = sqlite3_prepare_v2(
                database, "SELECT SUM(priority_tokens) FROM file_day_aggregates", -1, &prepared, nil)
            defer { sqlite3_finalize(prepared) }
            try #require(prepare == SQLITE_OK)
            let statement = try #require(prepared)
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            let tokens = sqlite3_column_int64(statement, 0)
            try #require(tokens == 110)
            try #require(sqlite3_step(statement) == SQLITE_DONE)
            // Materialize setup writes before taking the read-only coverage check's byte-for-byte baseline.
            try #require(sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK)
            return tokens
        }()
        let before = try Data(contentsOf: url)
        try #require(throws: CodexCombinedCostError.pricingEvidence) { try fixture.scan() }
        try #require(try Data(contentsOf: url) == before)
        print(
            "retained priority fixture: baseline=110 priority=\(priorityTokens) fallback=pricingEvidence DB unchanged")
    }

    @Test
    func `one calendar buckets UTC midnight records into local Today`() throws {
        let fixture = try Fixture(timeZone: "Asia/Shanghai")
        defer { fixture.cleanup() }
        try fixture.write(
            fixture.records(id: "remote", timestamp: "2026-09-15T23:30:00Z"),
            root: fixture.remoteArchived)
        let result = try fixture.scan()
        #expect(result.sessionTokens == 110)
        #expect(result.daily.map(\.date) == ["2026-09-16"])
    }

    @Test
    func `changed calendar cannot hide deleted retained source on the adjacent day`() throws {
        let fixture = try Fixture(timeZone: "Asia/Shanghai")
        defer { fixture.cleanup() }
        try fixture.write(fixture.records(id: "local", timestamp: "2026-09-09T23:30:00Z"), root: fixture.localSessions)
        var oldCalendar = fixture.calendar
        oldCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let oldDate = try #require(ISO8601DateFormatter().date(from: "2026-09-09T12:00:00Z"))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: fixture.localSessions,
            cacheRoot: fixture.localCache,
            codexTraceDatabaseURL: fixture.root.appendingPathComponent("absent.sqlite"),
            calendar: oldCalendar)
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex, since: oldDate, until: fixture.now, now: fixture.now, options: options)
        #expect(report.summary?.totalTokens == 110)
        try FileManager.default.removeItem(at: fixture.localSessions)
        #expect(throws: CodexCombinedCostError.localCoverage) { try fixture.scan() }
    }

    @Test(arguments: [false, true])
    func `retained home alias coverage includes deleted leaves in both directions`(ledgerUsesAlias: Bool) throws {
        for deleteParent in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.write(fixture.records(id: "local"), root: fixture.localSessions)
            let alias = fixture.root.appendingPathComponent("home-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.localHome)
            try fixture.seedLedger(home: ledgerUsesAlias ? alias : fixture.localHome)
            let requestedHome = ledgerUsesAlias ? fixture.localHome : alias
            try fixture.validateCoverage(home: requestedHome)
            let database = fixture.localCache.appendingPathComponent("cost-usage/cost-usage.sqlite")
            let before = try Data(contentsOf: database)
            let deleted = deleteParent ? fixture.localSessions : fixture.localSessions
                .appendingPathComponent("rollout.jsonl")
            try FileManager.default.removeItem(at: deleted)
            #expect(throws: CodexCombinedCostError.localCoverage) {
                try fixture.validateCoverage(home: requestedHome)
            }
            #expect(try Data(contentsOf: database) == before)
        }
    }

    @Test(arguments: [false, true])
    func `retargeted home alias cannot discard retained old scope`(ledgerUsesAlias: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(fixture.records(id: "local"), root: fixture.localSessions)
        let alias = fixture.root.appendingPathComponent("home-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.localHome)
        try fixture.seedLedger(home: ledgerUsesAlias ? alias : fixture.localHome)
        let replacement = fixture.root.appendingPathComponent("new-home")
        try FileManager.default.copyItem(at: fixture.localHome, to: replacement)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        let database = fixture.localCache.appendingPathComponent("cost-usage/cost-usage.sqlite")
        let before = try Data(contentsOf: database)
        #expect(throws: CodexCombinedCostError.localCoverage) {
            try fixture.validateCoverage(home: alias)
        }
        #expect(throws: CodexCombinedCostError.localCoverage) {
            try fixture.validateCoverage(home: replacement)
        }
        // The original scope also cannot validate through a ledger whose alias now targets another home.
        if ledgerUsesAlias {
            #expect(throws: CodexCombinedCostError.localCoverage) {
                try fixture.validateCoverage(home: fixture.localHome)
            }
        }
        #expect(try Data(contentsOf: database) == before)
    }

    @Test
    func `unknown pricing remains unknown`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(
            fixture.records(id: "unknown", model: "openai/codex-no-price-fixture"),
            root: fixture.remoteSessions)
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == 110)
        #expect(result.last30DaysCostUSD == nil)
        #expect(result.daily.first?.costUSD == nil)
    }

    @Test
    func `E2E oracle uses one catalog for prefix union and remote history`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = "custom-codex-model"
        let catalogJSON = #"""
        {"openai":{"id":"openai","models":{"custom-codex-model":{
          "id":"custom-codex-model","cost":{"input":3,"output":12,"cache_read":0.3}
        }}}}
        """#
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(catalogJSON.utf8))
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: fixture.now, cacheRoot: fixture.pricingRoot))
        let prefix: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "shared"]], fixture.context(model: model),
            fixture.event(
                input: 100_000,
                cached: 20000,
                output: 10000,
                model: model,
                timestamp: "2026-09-15T12:00:00Z"),
            fixture.event(input: 300_000, cached: 60000, output: 30000, model: model),
        ]
        try fixture.write(prefix, root: fixture.localSessions)
        try fixture.write(
            prefix + [fixture.event(input: 600_000, cached: 120_000, output: 60000, model: model)],
            root: fixture.remoteSessions)
        try fixture.write([
            ["type": "session_meta", "payload": ["id": "remote-only"]], fixture.context(model: model),
            fixture.event(input: 50000, cached: 10000, output: 5000, model: model, timestamp: "2026-09-13T12:00:00Z"),
        ], root: fixture.remoteArchived)
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == 715_000)
        #expect(result.sessionTokens == 550_000)
        #expect(abs((result.last30DaysCostUSD ?? -1) - 2.379) < 0.00000001)
        #expect(abs((result.sessionCostUSD ?? -1) - 1.83) < 0.00000001)
        print(
            "combined E2E oracle: history=\(result.last30DaysTokens ?? -1)/$\(result.last30DaysCostUSD ?? -1)"
                + " today=\(result.sessionTokens ?? -1)/$\(result.sessionCostUSD ?? -1)")
    }

    @Test
    func `canonical root reversal and warm native scans have equal nonzero results`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let prefix = fixture.records(id: "shared")
        try fixture.write(prefix, root: fixture.localSessions)
        try fixture.write(prefix + [fixture.event(input: 200, cached: 40, output: 20)], root: fixture.remoteSessions)
        var totals: [Int?] = []
        var costs: [Double?] = []
        for reverse in [false, true] {
            let roots = reverse ? [fixture.remoteSessions, fixture.localSessions] : [
                fixture.localSessions,
                fixture.remoteSessions,
            ]
            let work = fixture.root.appendingPathComponent(reverse ? "reversed" : "ordered")
            let canonical = try CodexCombinedLogPreparation.prepare(
                roots: roots,
                destination: work.appendingPathComponent("canonical"),
                checkCancellation: {})
            var options = CostUsageScanner.Options(
                cacheRoot: work.appendingPathComponent("cache"),
                codexTraceDatabaseURL: work.appendingPathComponent("missing.sqlite"),
                calendar: fixture.calendar)
            options.codexExplicitSessionRoots = canonical.roots.reversed()
            options.codexFrozenPricing = CodexCombinedPricingContext.freeze(request: fixture.request)
            options.refreshMinIntervalSeconds = 0
            for _ in 0..<2 {
                let report = CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: fixture.now,
                    until: fixture.now,
                    now: fixture.now,
                    options: options)
                totals.append(report.summary?.totalTokens)
                costs.append(report.summary?.totalCostUSD)
            }
        }
        #expect(totals == [220, 220, 220, 220])
        #expect(costs.allSatisfy { abs(($0 ?? -1) - 0.0005) < 0.000000001 })
    }

    @Test(arguments: ["session_meta", "turn_context", "token_count", "task_started", "bare_usage"])
    func `oversized native usage and state records cannot publish complete zero`(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let padding = String(repeating: "x", count: CostUsageScanner.codexSessionMetadataMaxLineBytes + 1)
        var records = fixture.records(id: "remote")
        switch kind {
        case "session_meta": records[0]["padding"] = padding
        case "turn_context": records[1]["padding"] = padding
        case "task_started":
            records.insert([
                "type": "event_msg", "padding": padding,
                "payload": ["type": "task_started", "turn_id": "turn-fixture"],
            ], at: 2)
        case "bare_usage":
            records[2] = [
                "type": "response.completed", "timestamp": "2026-09-16T12:00:00Z", "padding": padding,
                "model": "gpt-5.2-codex", "usage": ["input_tokens": 100, "output_tokens": 10],
            ]
        default: records[2]["padding"] = padding
        }
        try fixture.write(records, root: fixture.remoteSessions)
        #expect(throws: CodexCombinedCostError.unsupportedOverlap) { try fixture.scan() }
    }

    @Test(arguments: [false, true])
    func `long conversation and maximum supported usage lines preserve nonzero totals`(atUsageLimit: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var records = fixture.records(id: "remote")
        let limit = CostUsageScanner.codexSessionMetadataMaxLineBytes
        if atUsageLimit {
            records[2]["padding"] = ""
            let base = try JSONSerialization.data(withJSONObject: records[2], options: [.sortedKeys]).count
            records[2]["padding"] = String(repeating: "x", count: limit - base)
            #expect(try JSONSerialization.data(withJSONObject: records[2], options: [.sortedKeys]).count == limit)
        } else {
            records.insert([
                "type": "response_item", "payload": ["content": String(repeating: "x", count: limit + 1)],
            ], at: 2)
        }
        try fixture.write(records, root: fixture.remoteSessions)
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == 110)
        #expect(abs((result.last30DaysCostUSD ?? -1) - 0.00025) < 0.000000001)
    }

    @Test(arguments: ["payload.id", "id", "payload.session_id", "payload.sessionId", "session_id", "sessionId"])
    func `native session identity aliases count identical copies once`(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var records = fixture.records(id: "shared")
        let parts = field.split(separator: ".")
        if parts.count == 2 {
            records[0] = ["type": "session_meta", "payload": [String(parts[1]): "shared"]]
        } else {
            records[0] = ["type": "session_meta", field: "shared"]
        }
        try fixture.write(records, root: fixture.localSessions)
        try fixture.write(records, root: fixture.remoteSessions)
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == 110)
        #expect(abs((result.last30DaysCostUSD ?? -1) - 0.00025) < 0.000000001)
    }

    @Test
    func `native top level rollout ID rejects conflicting payload tree views`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for (tree, root, amount) in [
            ("tree-one", fixture.localSessions, 100),
            ("tree-two", fixture.remoteSessions, 200),
        ] {
            try fixture.write([
                ["type": "session_meta", "id": "same-native-id", "payload": ["session_id": tree]],
                fixture.context(), fixture.event(input: amount, cached: 0, output: 0),
            ], root: root)
        }
        #expect(throws: CodexCombinedCostError.unsupportedOverlap) { try fixture.scan() }
    }

    @Test(arguments: ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"])
    func `native parent aliases share the same validated ancestry`(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let timestamp = "2026-09-01T12:00:00Z"
        try fixture.write(fixture.records(id: "parent", timestamp: timestamp), root: fixture.localSessions)
        try fixture.write([
            ["type": "session_meta", "payload": ["id": "child", field: "parent", "timestamp": timestamp]],
            fixture.context(), fixture.event(input: 150, cached: 20, output: 15),
        ], root: fixture.remoteSessions)
        #expect(try fixture.scan().last30DaysTokens == 55)
        try FileManager.default.removeItem(at: fixture.localSessions)
        #expect(throws: CodexCombinedCostError.missingAncestor) { try fixture.scan(name: "missing") }
    }

    @Test(arguments: [0, 1, 2])
    func `unparseable fork cutoff is rejected before native lexical fallback`(variant: Int) throws {
        let timestamp = ["PRIVATE_CONTENT_CANARY", "", "missing"][variant]
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(fixture.records(id: "parent"), root: fixture.localSessions)
        var metadata: [String: Any] = ["id": "child", "forked_from_id": "parent"]
        if timestamp != "missing" { metadata["timestamp"] = timestamp }
        try fixture.write([
            ["type": "session_meta", "payload": metadata],
            fixture.context(), fixture.event(input: 200, cached: 0, output: 0),
        ], root: fixture.remoteSessions)
        #expect(throws: CodexCombinedCostError.missingAncestor) { try fixture.scan() }
    }

    @Test(arguments: [0, 1])
    func `invalid parent token timestamp is rejected before ancestry logging`(variant: Int) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var parent = fixture.records(id: "parent")
        parent[2] = fixture.event(timestamp: variant == 0 ? "PRIVATE_CONTENT_CANARY" : "")
        try fixture.write(parent, root: fixture.localSessions)
        try fixture.write([
            ["type": "session_meta", "payload": [
                "id": "child", "forked_from_id": "parent", "timestamp": "2026-09-16T12:00:00Z",
            ]],
            fixture.context(), fixture.event(input: 200, cached: 0, output: 0),
        ], root: fixture.remoteSessions)
        #expect(throws: CodexCombinedCostError.unsupportedOverlap) { try fixture.scan() }
    }

    #if canImport(SQLite3)
    @Test
    func `local Fast trace survives combined scan without pricing unrelated remote turns`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var records = fixture.records(id: "local", model: "gpt-5.4")
        records.insert(
            ["type": "event_msg", "timestamp": "2026-09-16T12:00:00Z", "payload": [
                "type": "task_started",
                "turn_id": "fast-turn",
            ]],
            at: 2)
        try fixture.write(records, root: fixture.localSessions)
        var remote = fixture.records(id: "remote", model: "gpt-5.4")
        remote.insert(
            ["type": "event_msg", "timestamp": "2026-09-16T12:00:00Z", "payload": [
                "type": "task_started",
                "turn_id": "fast-turn",
            ]],
            at: 2)
        try fixture.write(remote, root: fixture.remoteSessions)
        try fixture.writeTrace(thread: "local", turn: "fast-turn", model: "gpt-5.4")
        let result = try fixture.scan()
        #expect(result.last30DaysTokens == 220)
        // Custom Standard is $0.00025; gpt-5.4 API Fast is 2x, only for the local session.
        #expect(abs((result.last30DaysCostUSD ?? -1) - 0.00075) < 0.000000001)
        let breakdown = try #require(result.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.priorityTokens == 110)
        #expect(breakdown.standardTokens == 110)
    }

    @Test(arguments: ["turn_id", "turnId", "id", "info.turn_id", "info.turnId", "info.id"])
    func `native turn aliases retain local trace evidence without a thread ID`(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var records = fixture.records(id: "local")
        var event = fixture.event()
        var payload = try #require(event["payload"] as? [String: Any])
        let key = field.replacingOccurrences(of: "info.", with: "")
        if field.hasPrefix("info.") {
            var info = try #require(payload["info"] as? [String: Any])
            info[key] = "turn-alias"
            payload["info"] = info
        } else {
            payload[key] = "turn-alias"
        }
        event["payload"] = payload
        records[2] = event
        try fixture.write(records, root: fixture.localSessions)
        let url = fixture.localHome.appendingPathComponent("logs_2.sqlite")
        var opened: OpaquePointer?
        #expect(sqlite3_open(url.path, &opened) == SQLITE_OK)
        let database = try #require(opened)
        #expect(sqlite3_exec(
            database,
            "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, feedback_log_body TEXT)",
            nil,
            nil,
            nil) == SQLITE_OK)
        let body = "turn.id=turn-alias websocket request: "
            + #"{"type":"response.create","model":"gpt-5.2-codex","service_tier":"priority"}"#
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            database,
            "INSERT INTO logs(ts, feedback_log_body) VALUES (?,?)",
            -1,
            &statement,
            nil) == SQLITE_OK)
        let row = try #require(statement)
        sqlite3_bind_int64(row, 1, Int64(fixture.now.timeIntervalSince1970))
        _ = body.withCString { sqlite3_bind_text(row, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(row) == SQLITE_DONE)
        sqlite3_finalize(row)
        sqlite3_close(database)
        #expect(try fixture.scan().last30DaysTokens == 110)
    }
    #endif

    @Test(arguments: ["service_tier", "serviceTier", "pricing_mode", "pricingMode"])
    func `explicit inline priority evidence fails closed`(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var records = fixture.records(id: "remote")
        records[1] = ["type": "turn_context", "payload": ["model": "gpt-5.2-codex", field: "priority"]]
        try fixture.write(records, root: fixture.remoteSessions)
        #expect(throws: CodexCombinedCostError.pricingEvidence) { try fixture.scan() }
    }

    #if canImport(SQLite3)
    @Test
    func `only relevant local priority trace evidence blocks combined estimates`() throws {
        for mode in 0..<3 {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.write(fixture.records(id: "local"), root: fixture.localSessions)
            try fixture.write(fixture.records(id: "remote"), root: fixture.remoteSessions)
            let url = fixture.localHome.appendingPathComponent("logs_2.sqlite")
            var database: OpaquePointer?
            #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
            let db = try #require(database)
            #expect(sqlite3_exec(
                db,
                "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, feedback_log_body TEXT)",
                nil,
                nil,
                nil) == SQLITE_OK)
            if mode > 0 {
                let thread = mode == 1 ? "unrelated" : "local"
                let body = "thread_id=\(thread) turn.id=other-turn websocket request: "
                    + #"{"type":"response.create","model":"gpt-5.2-codex","service_tier":"priority"}"#
                var statement: OpaquePointer?
                #expect(sqlite3_prepare_v2(
                    db,
                    "INSERT INTO logs(ts, feedback_log_body) VALUES (?,?)",
                    -1,
                    &statement,
                    nil) == SQLITE_OK)
                let row = try #require(statement)
                sqlite3_bind_int64(row, 1, Int64(fixture.now.timeIntervalSince1970))
                _ = body.withCString { sqlite3_bind_text(
                    row,
                    2,
                    $0,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                #expect(sqlite3_step(row) == SQLITE_DONE)
                sqlite3_finalize(row)
            }
            sqlite3_close(db)
            let before = try Data(contentsOf: url)
            if mode == 2 {
                #expect(throws: CodexCombinedCostError.pricingEvidence) { try fixture.scan() }
            } else {
                #expect(try fixture.scan().last30DaysTokens == 220)
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }
    #endif

    struct Fixture {
        let root: URL
        let calendar: Calendar
        let now: Date
        var localHome: URL {
            self.root.appendingPathComponent("local")
        }

        var localSessions: URL {
            self.localHome.appendingPathComponent("sessions")
        }

        var remoteSessions: URL {
            self.root.appendingPathComponent("remote/sessions")
        }

        var remoteArchived: URL {
            self.root.appendingPathComponent("remote/archived_sessions")
        }

        var pricingRoot: URL {
            self.root.appendingPathComponent("pricing")
        }

        var localCache: URL {
            self.root.appendingPathComponent("local-cache")
        }

        var request: CodexCombinedCostRequest {
            .init(
                source: .init(host: "fixture"),
                localCodexHome: self.localHome,
                historyDays: 7,
                calendar: self.calendar,
                now: self.now,
                pricingCacheRoot: self.pricingRoot,
                localCostCacheRoot: self.localCache)
        }

        init(timeZone: String = "UTC") throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("combined-cost-\(UUID().uuidString)")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZone)!
            self.calendar = calendar
            self.now = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
            try FileManager.default.createDirectory(at: self.pricingRoot, withIntermediateDirectories: true)
            let prices = Data(
                #"{"gpt-5.2-codex":{"input":2,"output":8,"cacheRead":0.5},"gpt-5.4":{"input":2,"output":8,"cacheRead":0.5}}"#
                    .utf8)
            try prices.write(to: self.pricingRoot.appendingPathComponent(CostUsageCustomPricing.fileName))
        }

        func seedLedger(home: URL) throws {
            let options = CostUsageScanner.Options(
                codexSessionsRoot: home.appendingPathComponent("sessions"),
                cacheRoot: self.localCache,
                codexTraceDatabaseURL: self.root.appendingPathComponent("absent.sqlite"),
                calendar: self.calendar)
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex, since: self.now, until: self.now, now: self.now, options: options)
            #expect(report.summary?.totalTokens == 110)
        }

        #if canImport(SQLite3)
        func writeTrace(thread: String?, turn: String, model: String) throws {
            let url = self.localHome.appendingPathComponent("logs_2.sqlite")
            var opened: OpaquePointer?
            try #require(sqlite3_open(url.path, &opened) == SQLITE_OK)
            let database = try #require(opened)
            defer { sqlite3_close(database) }
            try #require(sqlite3_exec(
                database,
                "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, feedback_log_body TEXT)",
                nil,
                nil,
                nil) == SQLITE_OK)
            let body = (thread.map { "thread_id=\($0) " } ?? "") + "turn.id=\(turn) websocket request: "
                + "{\"type\":\"response.create\",\"model\":\"\(model)\",\"service_tier\":\"priority\"}"
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
            sqlite3_bind_int64(statement, 1, Int64(self.now.timeIntervalSince1970))
            _ = body.withCString {
                sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            try #require(sqlite3_step(statement) == SQLITE_DONE)
        }
        #endif

        func validateCoverage(home: URL) throws {
            let request = CodexCombinedCostRequest(
                source: .init(host: "fixture"),
                localCodexHome: home,
                historyDays: 7,
                calendar: self.calendar,
                now: self.now,
                pricingCacheRoot: self.pricingRoot,
                localCostCacheRoot: self.localCache)
            try CodexCombinedLocalCoverage.validate(request: request, since: self.now)
        }

        func cleanup() { try? FileManager.default.removeItem(at: self.root) }

        func context(model: String = "gpt-5.2-codex") -> [String: Any] {
            ["type": "turn_context", "payload": ["model": model, "turn_id": "turn-fixture"]]
        }

        func event(
            input: Int = 100,
            cached: Int = 20,
            output: Int = 10,
            model: String = "gpt-5.2-codex",
            timestamp: String = "2026-09-16T12:00:00Z") -> [String: Any]
        {
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "info": [
                "model": model, "total_token_usage": [
                    "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                ],
            ]]]
        }

        func records(
            id: String,
            model: String = "gpt-5.2-codex",
            timestamp: String = "2026-09-16T12:00:00Z") -> [[String: Any]]
        {
            [
                ["type": "session_meta", "timestamp": timestamp, "payload": ["id": id]], self.context(model: model),
                self.event(model: model, timestamp: timestamp),
            ]
        }

        func write(_ records: [[String: Any]], root: URL) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var data = Data()
            for record in records {
                try data.append(JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                data.append(10)
            }
            #expect(FileManager.default.createFile(
                atPath: root.appendingPathComponent("rollout.jsonl").path,
                contents: data,
                attributes: [.posixPermissions: 0o600]))
        }

        func scan(
            name: String = "work",
            reverse: Bool = false,
            pricing: CodexCombinedPricingContext? = nil) throws -> CostUsageTokenSnapshot
        {
            let work = self.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let roots = reverse ? [self.remoteArchived, self.remoteSessions] : [
                self.remoteSessions,
                self.remoteArchived,
            ]
            let ready = work.appendingPathComponent("ready")
            if FileManager.default.fileExists(atPath: ready.path) { try FileManager.default.removeItem(at: ready) }
            try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
            let copiedRoots = try roots.enumerated().map { index, source in
                let target = ready.appendingPathComponent("root-\(index)")
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: target)
                }
                return target
            }
            let remote = CodexRemoteLogSnapshot(
                roots: copiedRoots,
                workDirectory: work,
                scanCacheRoot: work.appendingPathComponent("cache"),
                capturedFrom: self.now,
                capturedTo: self.now)
            return try CodexCombinedCostFetcher.scan(
                request: self.request,
                remote: remote,
                pricing: pricing ?? CodexCombinedPricingContext.freeze(request: self.request),
                checkCancellation: {})
        }
    }
}
