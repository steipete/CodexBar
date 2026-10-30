import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexRequestLedgerTests {
    static let timestampA = "2026-08-29T15:59:00Z"
    static let timestampB = "2026-08-29T16:01:00Z"
    static let timestampC = "2026-08-29T16:01:05Z"

    @Test(arguments: [false, true], [false, true])
    func `request ledger recovers reset counters without counting both formats`(
        legacyFirst: Bool, spacedJSON: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var lines = Self.header()
        let requests: [(String, [Int], [Int], [Int])] = [
            (Self.timestampA, [1000, 200, 100, 40], [1000, 200, 100, 40], [1000, 200, 100, 40]),
            (Self.timestampB, [60, 20, 6, 3], [60, 20, 6, 3], [1060, 220, 106, 43]),
            (Self.timestampC, [60, 20, 6, 3], [120, 40, 12, 6], [1120, 240, 112, 46]),
        ]
        for (index, request) in requests.enumerated() {
            let (timestamp, usage, legacyTotal, threadTotal) = request
            let legacy = Self.legacy(timestamp: timestamp, usage: usage, total: legacyTotal)
            let ledger = Self.record(
                id: "response-\(index)",
                timestamp: timestamp,
                usage: usage,
                total: threadTotal,
                turnTotal: legacyTotal)
            lines += legacyFirst ? [legacy, ledger] : [ledger, legacy]
        }
        let result = try Self.parse(lines, env: env, spacedJSON: spacedJSON)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 1232)
        #expect(result.rows.filter { $0.day == "2026-08-30" }.reduce(0) { $0 + $1.input + $1.output } == 132)
        #expect(result.rows.reduce(0) { $0 + ($1.reasoning ?? 0) } == 46)
    }

    @Test
    func `ledger and legacy timestamps may differ`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.record(
                id: "one",
                timestamp: "2026-08-29T15:59:01Z",
                usage: [100, 20, 10, 4],
                total: [100, 20, 10, 4]),
        ], env: env)
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.responseID == "one")
        #expect(result.rows.first?.input == 100)
    }

    @Test(arguments: [false, true], [
        (sameWindow: false, drifted: false), (sameWindow: true, drifted: false),
        (sameWindow: false, drifted: true), (sameWindow: true, drifted: true),
    ])
    func `request accounting survives append and SQLite reopen`(
        legacyFirst: Bool, scenario: (sameWindow: Bool, drifted: Bool)) async throws
    {
        let (sameWindow, drifted) = scenario
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 2)
        let first = Self.record(
            id: "one",
            timestamp: drifted && legacyFirst ? later : Self.timestampA,
            usage: [1000, 200, 100, 40],
            total: drifted ? [3000, 600, 300, 120] : [1000, 200, 100, 40])
        let mirror = Self.legacy(
            timestamp: drifted && !legacyFirst ? later : Self.timestampA,
            usage: [1000, 200, 100, 40],
            total: drifted ? [1500, 300, 150, 60] : [1000, 200, 100, 40])
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "synthetic-ledger.jsonl",
            contents: env.jsonl(Self.header() + [legacyFirst ? mirror : first]))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        func fetch(_ now: Date) async throws -> CostUsageTokenSnapshot {
            try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                environment: [:],
                now: now,
                forceRefresh: true,
                historyDays: 30,
                allowPricingRefresh: false,
                includePiSessions: false,
                scannerOptions: options)
        }
        let initial = try await fetch(sameWindow ? end : start)
        #expect(initial.sessionTokens == (sameWindow ? 0 : 1100))
        _ = await CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome).readSnapshot()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            legacyFirst ? first : mirror,
            Self.record(
                id: "two",
                timestamp: Self.timestampB,
                usage: [60, 20, 6, 3],
                total: [1060, 220, 106, 43],
                turnTotal: [60, 20, 6, 3]),
            Self.legacy(timestamp: Self.timestampB, usage: [60, 20, 6, 3], total: [60, 20, 6, 3]),
            Self.record(
                id: "three",
                timestamp: Self.timestampC,
                usage: [60, 20, 6, 3],
                total: [1120, 240, 112, 46],
                turnTotal: [120, 40, 12, 6]),
            Self.legacy(timestamp: Self.timestampC, usage: [60, 20, 6, 3], total: [120, 40, 12, 6]),
        ]).utf8))
        try handle.close()
        let resumed = try await fetch(end)
        #expect(resumed.sessionTokens == 132)
        let saved = await CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome).readSnapshot()
        #expect(saved.files.allSatisfy { $0.scanState.isComplete == true })
        #expect(saved.usageRows.count == 3)
        let stable = try await fetch(end.addingTimeInterval(120))
        #expect(stable.daily == resumed.daily)
        let reopened = await CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome).readSnapshot()
        #expect(reopened.usageRows == saved.usageRows)
    }

    @Test
    func `request identity suppresses replay even when replayed counters change`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [200, 40, 20, 8]),
            Self.record(id: "two", usage: [100, 20, 10, 4], total: [300, 60, 30, 12]),
        ], env: env)
        #expect(result.rows.count == 2)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    @Test(arguments: [false, true])
    func `replayed identities also suppress legacy mirrors with changed counters`(legacyFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let replay = Self.record(id: "one", usage: [100, 20, 10, 4], total: [200, 40, 20, 8])
        let mirror = Self.legacy(timestamp: Self.timestampB, usage: [100, 20, 10, 4], total: [200, 40, 20, 8])
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
        ] + (legacyFirst ? [mirror, replay] : [replay, mirror]), env: env)
        #expect(result.rows.count == 1)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 110)
    }

    @Test
    func `copied parent request records are not billed to a child`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "copied", owner: "parent", usage: [1000, 200, 100, 40], total: [1000, 200, 100, 40]),
            Self.record(id: "owned", usage: [60, 20, 6, 3], total: [1060, 220, 106, 43]),
        ], env: env)
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.input == 60)
        #expect(result.rows.first?.output == 6)
    }

    @Test
    func `legacy prefix remains when request records start later`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.legacy(timestamp: Self.timestampA, usage: [1000, 200, 100, 40], total: [1000, 200, 100, 40]),
            Self.record(id: "new", timestamp: Self.timestampB, usage: [60, 20, 6, 3], total: [1060, 220, 106, 43]),
            Self.legacy(timestamp: Self.timestampB, usage: [60, 20, 6, 3], total: [60, 20, 6, 3]),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 1166)
        #expect(result.rows.map(\.day) == ["2026-08-29", "2026-08-30"])
    }

    @Test
    func `legacy-only requests between ledger requests remain counted`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.legacy(timestamp: Self.timestampB, usage: [50, 10, 5, 2], total: [150, 30, 15, 6]),
            Self.record(
                id: "three",
                timestamp: Self.timestampC,
                usage: [60, 20, 6, 3],
                total: [210, 50, 21, 9]),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 231)
    }

    @Test
    func `archived copies deduplicate by response identity rather than page index`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
        ], env: env)
        var state = CostUsageScanner.CodexScanState()
        CostUsageScanner.rememberCodexRows(
            result.rows,
            sessionId: "synthetic-thread",
            fileIdentity: "page-one",
            state: &state)
        let duplicate = CostUsageScanner.CodexUsageRow(
            day: "2026-08-30",
            model: "gpt-5",
            turnID: "synthetic-turn",
            eventIndex: 42,
            input: 100,
            cached: 20,
            output: 10,
            responseID: "one")
        let unique = CostUsageScanner.uniqueCodexRows(
            rows: [duplicate],
            sessionId: "synthetic-thread",
            fileIdentity: "archive-copy",
            state: &state)
        #expect(unique.isEmpty)
        let anotherThread = CostUsageScanner.uniqueCodexRows(
            rows: [duplicate],
            sessionId: "another-thread",
            fileIdentity: "other",
            state: &state)
        #expect(anotherThread.count == 1)
    }

    @Test
    func `totals-only legacy requests retain their baseline after a ledger mirror`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            ["type": "event_msg", "timestamp": Self.timestampB, "payload": [
                "type": "token_count", "info": ["total_token_usage": Self.tokens([150, 30, 15, 6])],
            ]],
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 165)
    }

    @Test
    func `invalid ledger does not disable legacy accounting`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var invalid = Self.record(id: "invalid", usage: [100, 20, 10, 4], total: [100, 20, 10, 4])
        var payload = try #require(invalid["payload"] as? [String: Any])
        payload["usage"] = ["input_tokens": true, "cached_input_tokens": 20, "output_tokens": 10]
        invalid["payload"] = payload
        let result = try Self.parse(Self.header() + [
            invalid,
            Self.legacy(
                timestamp: Self.timestampA,
                usage: [100, 20, 10, 4],
                total: [100, 20, 10, 4]),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 110)
    }

    @Test(arguments: [false, true])
    func `ordinary cached tails retain ownership inside the same reporting window`(legacyFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let date = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let first = Self.record(id: "first", usage: [100, 20, 10, 4], total: [100, 20, 10, 4])
        let file = try env.writeCodexSessionFile(
            day: date, filename: "same-window.jsonl", contents: env.jsonl(Self.header() + [first, Self.legacy(
                timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4])]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        func fetch(_ cacheRoot: URL = env.cacheRoot) -> CostUsageDailyReport {
            var selected = options
            selected.cacheRoot = cacheRoot
            return CostUsageScanner.loadDailyReport(
                provider: .codex, since: date, until: date, now: date, options: selected)
        }
        #expect(fetch().summary?.totalTokens == 110)
        let prefix = try #require(CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: calendar).files[file.path])
        let record = Self.record(
            id: "second",
            timestamp: Self.timestampC,
            usage: [60, 20, 6, 3],
            total: [160, 40, 16, 7])
        let mirror = Self.legacy(timestamp: Self.timestampC, usage: [60, 20, 6, 3], total: [160, 40, 16, 7])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl(legacyFirst ? [mirror, record] : [record, mirror]).utf8))
        try handle.close()
        let delta = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: .init(since: date, until: date, calendar: calendar),
            startOffset: #require(prefix.parsedBytes),
            initialModel: prefix.lastModel,
            initialSessionID: prefix.sessionId,
            initialTotals: prefix.lastCountedTotals,
            initialRawTotalsBaseline: prefix.lastRawTotalsBaseline,
            initialRawTotalsWatermark: prefix.lastRawTotalsWatermark,
            initialSeenRawTotals: prefix.seenRawTotals ?? [],
            initialCodexTurnID: prefix.lastCodexTurnID,
            initialCodexUsageRowIndex: #require(prefix.codexNextUsageRowIndex),
            initialRequestLedgerState: prefix.codexRequestLedgerState,
            initialRequestLedgerRows: prefix.codexRows ?? [])
        #expect(delta.rows.compactMap(\.responseID) == ["second"])
        #expect(delta.rows.reduce(0) { $0 + $1.input + $1.output } == 66)
        let resumed = fetch()
        #expect(resumed.summary?.totalTokens == 176)
        let cache = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: calendar)
        #expect(cache.files[file.path]?.codexRows?.compactMap(\.responseID) == ["first", "second"])
        #expect(cache.files[file.path]?.codexRows?.count == 2)
        #expect(fetch().data == resumed.data)
        #expect(fetch(env.root.appendingPathComponent("cold-cache")).data == resumed.data)
    }

    @Test(arguments: ["standard", "priority", "known", "unpriced"], [false, true])
    func `cached legacy mirrors retain saved pricing after a separate append`(
        pricing: String, differentTotals: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let date = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        var header = Self.header()
        header[1]["payload"] = ["turn_id": "synthetic-turn", "model": "gpt-5.4"]
        let usage = [100_000, 20000, 10000, 4000]
        let file = try env.writeCodexSessionFile(
            day: date, filename: "saved-pricing.jsonl", contents: env.jsonl(header + [Self.legacy(
                timestamp: Self.timestampA, usage: usage, total: usage)]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        func fetch() -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(
                provider: .codex, since: date, until: date, now: date, options: options)
        }
        _ = fetch()
        var saved = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: calendar)
        var cached = try #require(saved.files[file.path])
        var rows = try #require(cached.codexRows)
        #expect(rows.count == 1)
        rows[0].pricingModel = "gpt-5.4"
        rows[0].pricingMode = pricing == "priority" ? "priority" : "standard"
        if pricing == "known" { rows[0].knownCostNanos = 123_000_000 }
        if pricing == "unpriced" { rows[0].unpricedTokens = 110_000 }
        cached.codexRows = rows
        saved.files[file.path] = cached
        #expect(!CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            home: env.codexStoreHome,
            cache: saved,
            calendar: calendar)
            .catchUpRequired)
        let expectedCost = CostUsageScanner.codexResolvedCostUSD(
            for: rows[0], modelsDevCatalog: nil, modelsDevCacheRoot: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([Self.record(
            id: "priced-response",
            usage: usage,
            total: differentTotals ? [200_000, 40000, 20000, 8000] : usage)]).utf8))
        try handle.close()
        let resumed = fetch()
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: calendar)
        let replaced = try #require(reopened.files[file.path]?.codexRows)
        #expect(replaced.count == 1)
        let row = try #require(replaced.first)
        #expect(row.responseID == "priced-response")
        #expect(row.pricingModel == rows[0].pricingModel)
        #expect(row.pricingMode == rows[0].pricingMode)
        #expect(row.knownCostNanos == rows[0].knownCostNanos)
        #expect(row.unpricedTokens == rows[0].unpricedTokens)
        #expect(CostUsageScanner.codexResolvedCostUSD(
            for: row, modelsDevCatalog: nil, modelsDevCacheRoot: nil) == expectedCost)
        #expect(resumed.summary?.totalTokens == 110_000)
        #expect(fetch().data == resumed.data)
    }

    @Test(arguments: [false, true])
    func `ledger ownership distinguishes thread identity from execution session identity`(subagent: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var header = Self.header()
        var metadata: [String: Any] = ["id": "synthetic-thread", "session_id": "execution-session"]
        if subagent {
            metadata["forked_from_id"] = "execution-session"
            metadata["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]
            metadata["subagent_history_start_ordinal"] = 10
        }
        header[0]["payload"] = metadata
        header[1]["ordinal"] = 10
        var owned = Self.record(id: "owned", usage: [60, 20, 6, 3], total: [60, 20, 6, 3])
        var payload = try #require(owned["payload"] as? [String: Any])
        payload["session_id"] = "execution-session"
        owned["payload"] = payload
        owned["ordinal"] = 11
        var wrongSession = owned
        payload["response_id"] = "wrong-session"
        payload["session_id"] = "another-execution"
        wrongSession["payload"] = payload
        wrongSession["ordinal"] = 12
        let result = try Self.parse(header + [owned, wrongSession], env: env)
        #expect(result.rows.compactMap(\.responseID) == ["owned"])
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 66)
    }

    @Test(arguments: [false, true])
    func `explicit subagent boundary excludes matching thread ledger rows in copied history`(
        hasOwnedSuffix: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var header = Self.header()
        header[0]["payload"] = [
            "id": "synthetic-thread",
            "subagent_history_start_ordinal": 10,
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]],
        ]
        header[1]["ordinal"] = 1
        var copied = Self.record(id: "copied", usage: [1000, 200, 100, 40], total: [1000, 200, 100, 40])
        copied["ordinal"] = 2
        var owned = Self.record(id: "owned", usage: [60, 20, 6, 3], total: [1060, 220, 106, 43])
        owned["ordinal"] = 11
        let result = try Self.parse(header + [copied] + (hasOwnedSuffix ? [owned] : []), env: env)
        #expect(result.rows.compactMap(\.responseID) == (hasOwnedSuffix ? ["owned"] : []))
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == (hasOwnedSuffix ? 66 : 0))
    }

    @Test
    func `bounded subagent ledger routing survives serialized replay buffers`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var header = Self.header()
        header[0]["payload"] = [
            "id": "synthetic-thread", "session_id": "execution-session", "subagent_history_start_ordinal": 10,
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]],
        ]
        header[1]["ordinal"] = 10
        func ownedRecord(_ id: String, ordinal: Int, input: Int) throws -> [String: Any] {
            var record = Self.record(id: id, usage: [input, 0, 0, 0], total: [input, 0, 0, 0])
            var payload = try #require(record["payload"] as? [String: Any])
            payload["session_id"] = "execution-session"
            record["payload"] = payload
            record["ordinal"] = ordinal
            return record
        }
        let prefix = try env.jsonl([header[0], ownedRecord("copied", ordinal: 2, input: 1000)])
        let suffix = try env.jsonl([header[1], ownedRecord("owned", ordinal: 11, input: 60)])
        let file = env.root.appendingPathComponent("buffered-ledger.jsonl")
        try (prefix + suffix).write(to: file, atomically: false, encoding: .utf8)
        let day = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: .current)
        let partial = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, maxBytesToRead: Int64(prefix.utf8.count))
        #expect(partial.rows.isEmpty)
        let buffer = try #require(partial.bufferedSubagentLines)
        #expect(buffer.contains {
            if case .tokenUsageRecord = $0.line {
                true
            } else {
                false
            }
        })
        let restored = try JSONDecoder().decode(
            [CostUsageScanner.CodexBufferedFastLine].self, from: JSONEncoder().encode(buffer))
        let resumed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: partial.parsedBytes,
            initialSessionID: partial.sessionId,
            initialBufferedSubagentLines: restored,
            initialJSONLResumeState: partial.jsonlResumeState,
            initialRequestLedgerState: partial.requestLedgerState)
        #expect(resumed.rows.compactMap(\.responseID) == ["owned"])
        #expect(resumed.rows.reduce(0) { $0 + $1.input + $1.output } == 60)
        #expect(resumed.bufferedSubagentLines == nil)
        let cold = try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range)
        #expect(resumed.rows == cold.rows)
    }

    @Test(arguments: [false, true])
    func `adjacent mirrors reconcile distinct cumulative domains once`(legacyFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let ledger = Self.record(id: "one", usage: [100, 20, 10, 4], total: [1100, 220, 110, 44])
        let legacy = Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4])
        let result = try Self.parse(Self.header() + (legacyFirst ? [legacy, ledger] : [ledger, legacy]) + [
            Self.legacy(timestamp: Self.timestampB, usage: [100, 20, 10, 4], total: [200, 40, 20, 8]),
            Self.record(id: "two", timestamp: Self.timestampC, usage: [60, 20, 6, 3], total: [1260, 260, 126, 51]),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 286)
        #expect(result.rows.compactMap(\.responseID) == ["one", "two"])
        #expect(result.rows.count == 3)
    }

    @Test
    func `typed records survive the JSON timestamp fallback`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(
            Self.header() + [
                Self.record(id: "escaped-timestamp", usage: [100, 20, 10, 4], total: [100, 20, 10, 4]),
            ],
            env: env,
            transform: { $0.replacingOccurrences(of: #""timestamp""#, with: #""time\u0073tamp""#) })
        #expect(result.rows.compactMap(\.responseID) == ["escaped-timestamp"])
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 110)
    }

    @Test
    func `repeated counter tuples do not replace an earlier legacy request`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let result = try Self.parse(Self.header() + [
            Self.legacy(timestamp: Self.timestampA, usage: usage, total: usage),
            Self.header()[1],
            Self.record(
                id: "after-reset",
                timestamp: Self.timestampB,
                usage: usage,
                total: [200, 40, 20, 8],
                turnTotal: usage),
            Self.legacy(timestamp: Self.timestampB, usage: usage, total: usage),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
        #expect(result.rows.map(\.day) == ["2026-08-29", "2026-08-30"])
    }

    @Test(arguments: [false, true], ["standard", "priority", "known", "unpriced"])
    func `owned response date and saved prices survive cross-file mirrors`(
        ledgerFirst: Bool, pricing: String) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let usage = [100, 20, 10, 4]
        let legacy = Self.legacy(timestamp: Self.timestampA, usage: usage, total: usage)
        let ledger = Self.record(id: "owned", timestamp: Self.timestampB, usage: usage, total: usage)
        let legacyFile = try env.writeCodexSessionFile(
            day: start,
            filename: ledgerFirst ? "z-page.jsonl" : "a-page.jsonl",
            contents: env.jsonl(Self.header() + [legacy]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        func fetch() -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: start, until: end, now: end, options: options)
        }
        _ = fetch()
        var cache = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: calendar)
        var file = try #require(cache.files[legacyFile.path])
        var savedPrice = try #require(file.codexRows?.first)
        savedPrice.pricingModel = "gpt-5.4"
        savedPrice.pricingMode = pricing == "priority" ? "priority" : "standard"
        if pricing == "known" { savedPrice.knownCostNanos = 123_000_000 }
        if pricing == "unpriced" { savedPrice.unpricedTokens = 110 }
        file.codexRows = [savedPrice]
        cache.files[legacyFile.path] = file
        #expect(!CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            home: env.codexStoreHome,
            cache: cache,
            calendar: calendar)
            .catchUpRequired)
        // The paired page proves which legacy observation mirrors this response across midnight.
        _ = try env.writeCodexSessionFile(
            day: start,
            filename: ledgerFirst ? "a-page.jsonl" : "z-page.jsonl",
            contents: env.jsonl(Self.header() + (ledgerFirst ? [ledger, legacy] : [legacy, ledger])))
        let report = fetch()
        #expect(report.summary?.totalTokens == 110)
        #expect(report.data.filter { ($0.totalTokens ?? 0) > 0 }.map(\.date) == ["2026-08-30"])
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: calendar)
        let rows = reopened.files.values.flatMap { $0.codexRows ?? [] }
        #expect(rows.compactMap(\.responseID) == ["owned"])
        let row = try #require(rows.first)
        #expect(row.knownCostNanos == savedPrice.knownCostNanos)
        #expect(row.unpricedTokens == savedPrice.unpricedTokens)
        #expect(row.pricingModel == savedPrice.pricingModel)
        #expect(row.pricingMode == savedPrice.pricingMode)
        #expect(fetch().data == report.data)
    }

    @Test(arguments: [false, true])
    func `adjacent equal usage without shared timestamp or totals remains distinct`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let total = [200, 40, 20, 8]
        let first = ledgerFirst
            ? Self.record(id: "first", usage: usage, total: usage)
            : Self.legacy(timestamp: Self.timestampA, usage: usage, total: usage)
        let second = ledgerFirst
            ? Self.legacy(timestamp: Self.timestampB, usage: usage, total: total)
            : Self.record(id: "second", timestamp: Self.timestampB, usage: usage, total: total)
        let result = try Self.parse(Self.header() + [first, second], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
        #expect(result.rows.map(\.day) == ["2026-08-29", "2026-08-30"])
    }

    @Test(arguments: [false, true], [false, true])
    func `partial legacy observations mirror a typed response once`(legacyFirst: Bool, lastOnly: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let legacy = try Self.partialLegacy(lastOnly: lastOnly)
        let ledger = Self.record(id: "partial", usage: [100, 20, 10, 4], total: [100, 20, 10, 4])
        let result = try Self.parse(Self.header() + (legacyFirst ? [legacy, ledger] : [ledger, legacy]), env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 110)
        #expect(result.rows.compactMap(\.responseID) == ["partial"])
    }

    @Test(arguments: [false, true])
    func `partial legacy observations reconcile across separate pages`(lastOnly: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let pages = try [
            [Self.partialLegacy(lastOnly: lastOnly)],
            [Self.record(id: "partial", usage: [100, 20, 10, 4], total: [100, 20, 10, 4])],
        ]
        for (index, page) in pages.enumerated() {
            _ = try env.writeCodexSessionFile(
                day: day, filename: "partial-\(index).jsonl", contents: env.jsonl(Self.header() + page))
        }
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day, options: options)
        #expect(report.summary?.totalTokens == 110)
        let cache = CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome)
            .syncLoadCodexCache(calendar: .current)
        let rows: [CostUsageScanner.CodexUsageRow] = cache.files.values.flatMap { $0.codexRows ?? [] }
        let responseIDs: [String] = rows.compactMap(\CostUsageScanner.CodexUsageRow.responseID)
        #expect(responseIDs == ["partial"])
    }

    private static func partialLegacy(lastOnly: Bool) throws -> [String: Any] {
        var row = Self.legacy(timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [100, 20, 10, 4])
        var payload = try #require(row["payload"] as? [String: Any])
        var info = try #require(payload["info"] as? [String: Any])
        info.removeValue(forKey: lastOnly ? "total_token_usage" : "last_token_usage")
        payload["info"] = info
        row["payload"] = payload
        return row
    }

    static func parse(
        _ lines: [[String: Any]],
        env: CostUsageTestEnvironment,
        spacedJSON: Bool = false,
        transform: (String) -> String = { $0 }) throws -> CostUsageScanner.CodexParseResult
    {
        let file = env.root.appendingPathComponent("synthetic.jsonl")
        let content = try transform(env.jsonl(lines))
        try (spacedJSON ? content.replacingOccurrences(of: "\":", with: "\": ") : content)
            .write(to: file, atomically: false, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        return CostUsageScanner.parseCodexFile(
            fileURL: file, range: .init(since: start, until: end, calendar: calendar))
    }

    static func header() -> [[String: Any]] {
        [
            ["type": "session_meta", "timestamp": self.timestampA, "payload": ["id": "synthetic-thread"]],
            [
                "type": "turn_context",
                "timestamp": self.timestampA,
                "payload": ["turn_id": "synthetic-turn", "model": "gpt-5"],
            ],
        ]
    }

    static func timestamp(_ base: String, plusMilliseconds milliseconds: Int) throws -> String {
        let formatter = ISO8601DateFormatter()
        let date = try #require(formatter.date(from: base)).addingTimeInterval(Double(milliseconds) / 1000)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func tokens(_ values: [Int]) -> [String: Int] {
        [
            "input_tokens": values[0],
            "cached_input_tokens": values[1],
            "output_tokens": values[2],
            "reasoning_output_tokens": values[3],
        ]
    }

    static func record(
        id: String,
        owner: String = "synthetic-thread",
        timestamp: String = timestampA,
        usage: [Int],
        total: [Int],
        turnTotal: [Int]? = nil) -> [String: Any]
    {
        ["type": "token_usage_record", "timestamp": timestamp, "payload": [
            "thread_id": owner, "session_id": owner, "turn_id": "synthetic-turn", "response_id": id,
            "usage": self.tokens(usage), "thread_token_usage": self.tokens(total),
            "turn_token_usage": self.tokens(turnTotal ?? total),
        ]]
    }

    static func legacy(timestamp: String, usage: [Int], total: [Int]) -> [String: Any] {
        ["type": "event_msg", "timestamp": timestamp, "payload": [
            "type": "token_count", "turn_id": "synthetic-turn", "info": [
                "last_token_usage": self.tokens(usage), "total_token_usage": self.tokens(total),
            ],
        ]]
    }
}
