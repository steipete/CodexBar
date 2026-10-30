import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageCodexRequestLedgerTests {
    /// After a resume, Codex's token_count counter can run behind the thread counter while both events still describe
    /// the same response a few milliseconds apart. Adjacent same-turn observations with identical usage inside the
    /// mirror window are one request; beyond it they stay distinct.
    @Test(arguments: [false, true], [2, 4900, 5000, 5001, 5100])
    func `adjacent offset counters pair only inside the mirror window`(ledgerFirst: Bool, gapMs: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let pair = try Self.mirrorPair(
            usage: [87275, 4864, 1200, 0],
            thread: [2_241_749, 1_900_000, 30000, 0],
            total: [2_001_969, 1_675_776, 26000, 0],
            gap: gapMs,
            ledgerFirst: ledgerFirst)
        let result = try Self.parse(Self.header() + [pair[0]] + pair, env: env)
        #expect(result.rows.count == (gapMs <= 5000 ? 1 : 2))
        #expect(result.rows.reduce(0) { $0 + $1.input } == (gapMs <= 5000 ? 87275 : 174_550))
        #expect(result.rows.compactMap(\.responseID) == ["one"])
    }

    @Test(arguments: [false, true], ["different", "missing"])
    func `drift pairing requires the same known turn`(ledgerFirst: Bool, turn: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var pair = try Self.mirrorPair(ledgerFirst: ledgerFirst)
        let index = turn == "different" ? (ledgerFirst ? 1 : 0) : (ledgerFirst ? 0 : 1)
        var payload = try #require(pair[index]["payload"] as? [String: Any])
        payload["turn_id"] = turn == "different" ? "other-turn" : nil
        pair[index]["payload"] = payload
        let header = turn == "different" ? Self.header() : [Self.header()[0]]
        let result = try Self.parse(header + pair, env: env)
        #expect(result.rows.count == 2)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    /// Revision 8 stored the offset-counter mirror as a second row. The revision 9 reparse drops it and keeps the
    /// ledger row's saved pricing, without rebuilding the store.
    enum SavedMirrorPricing: CaseIterable, Sendable {
        case priced, unpriced, ledgerUnpriced
    }

    @Test(arguments: SavedMirrorPricing.allCases, [false, true])
    func `revision 8 duplicate mirror rows are removed by the reparse`(
        pricing: SavedMirrorPricing, bounded: Bool) throws
    {
        let unpriced = pricing != .priced
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let usage = [1000, 200, 100, 40]
        let mirrorAt = try Self.timestamp(Self.timestampA, plusMilliseconds: 2)
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "duplicate-mirror.jsonl",
            contents: env.jsonl(Self.header() + [
                Self.record(id: "one", usage: usage, total: [3000, 600, 300, 120], turnTotal: [2000, 400, 200, 80]),
                Self.legacy(timestamp: mirrorAt, usage: usage, total: [1500, 300, 150, 60]),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        func report(_ now: Date) -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: start, until: end, now: now, options: options)
        }
        func load() -> CostUsageFileUsage? {
            CostUsageStore(cacheRoot: env.cacheRoot, home: env.codexStoreHome).syncLoadCodexCache(calendar: calendar)
                .files[file.path]
        }
        #expect(report(end).summary?.totalTokens == 1100)

        // Recreate what revision 8 saved: the ledger row with Priority evidence plus the unpaired mirror row.
        var stored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, home: env.codexStoreHome, calendar: calendar)
        var usageFile = try #require(stored.files[file.path])
        var ledger = try #require(usageFile.codexRows?.first)
        ledger.pricingMode = "priority"
        let duplicate = CostUsageScanner.CodexUsageRow(
            day: ledger.day,
            model: ledger.model,
            rawModel: ledger.rawModel,
            turnID: ledger.turnID,
            eventIndex: (ledger.eventIndex ?? 0) + 1,
            timestampUnixMs: Int64((start.timeIntervalSince1970 * 1000).rounded()) + 2,
            input: ledger.input,
            cached: ledger.cached,
            output: ledger.output,
            reasoning: ledger.reasoning,
            pricingModel: ledger.pricingModel,
            pricingMode: "standard")
        var duplicateRow = duplicate
        if unpriced {
            // A fully marked file has no saved price to retain; its rows must stay unknown, not current-priced.
            ledger.unpricedTokens = 1100
            if pricing == .unpriced { duplicateRow.unpricedTokens = 1100 }
        }
        if bounded { options.maxCodexScanBytesPerRefresh = usageFile.size / 2 }
        usageFile.codexRows = [ledger, duplicateRow]
        usageFile.codexParserRevision = 8
        stored.files[file.path] = usageFile
        #expect(!CostUsageStoreAccess.replace(
            cacheRoot: env.cacheRoot,
            home: env.codexStoreHome,
            cache: stored,
            calendar: calendar)
            .catchUpRequired)
        #expect(load()?.codexRows?.count == 2)

        var migrated: CostUsageFileUsage?
        for pass in 1...20 {
            _ = report(end.addingTimeInterval(Double(pass)))
            migrated = load()
            if migrated?.hasCurrentCodexParser == true, migrated?.codexScanComplete == true { break }
        }
        let rows = try #require(migrated?.codexRows)
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(rows.count == 1)
        #expect(rows.first?.responseID == "one")
        // Saved Priority evidence is retained for priced rows; an unpriced row has no price to carry.
        if !unpriced {
            #expect(rows.first?.pricingMode == "priority")
        }
        #expect(rows.first?.unpricedTokens == (unpriced ? 1100 : nil))
        let migratedReport = report(end.addingTimeInterval(30))
        #expect(migratedReport.summary?.totalTokens == 1100)
        if unpriced {
            #expect(migratedReport.summary?.totalCostUSD == nil)
        }
    }

    /// A tool can delay the mirror. Matching advances in both counters still identify the pending response;
    /// an extra advance in the token_count counter proves intervening usage.
    @Test(arguments: [false, true], [false, true])
    func `delayed mirrors require ledger first order and exact counter advances`(
        ledgerFirst: Bool, continuous: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let lines = try Self.header() + [Self.taskStarted("synthetic-turn")] + Self.mirrorPair()
            + Self.mirrorPair(
                id: "two",
                usage: [60, 20, 6, 3],
                thread: [1160, 240, 116, 47],
                total: continuous ? [920, 192, 92, 37] : [925, 192, 92, 37],
                at: 10,
                gap: 29990,
                ledgerFirst: ledgerFirst)
        let result = try Self.parse(lines, env: env)
        #expect(result.rows.count == (ledgerFirst && continuous ? 2 : 3))
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == (ledgerFirst && continuous ? 176 : 242))
        #expect(result.rows.compactMap(\.responseID) == ["one", "two"])
    }

    /// A resumed session and a counted bare usage line both separate observations, so they cannot be one request.
    @Test(arguments: [false, true], ["resume", "bare usage", "task started", "turn context"])
    func `task context resume and bare usage separate pending observations`(
        ledgerFirst: Bool,
        separator: String) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var pair = try Self.mirrorPair(gap: 2000, ledgerFirst: ledgerFirst)
        let between = try Self.timestamp(Self.timestampA, plusMilliseconds: 1000)
        let separatorLine: [String: Any] = switch separator {
        case "resume": ["type": "session_meta", "timestamp": between, "payload": ["id": "synthetic-thread"]]
        case "bare usage": ["timestamp": between, "usage": ["prompt_tokens": 10, "completion_tokens": 1]]
        case "task started": Self.taskStarted("synthetic-turn")
        default: Self.header()[1]
        }
        pair.insert(separatorLine, at: 1)
        let result = try Self.parse(Self.header() + pair, env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == (separator == "bare usage" ? 231 : 220))
    }

    /// A replayed response is already counted; it must not claim a different legacy request of equal size nearby.
    @Test(arguments: [false, true], [false, true])
    func `a replay does not pair with a different legacy request inside the mirror window`(
        replayFirst: Bool, verbatim: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let first = try Self.mirrorPair()
        var replay = try Self.mirrorPair(total: [960, 192, 96, 38], at: 4000, gap: 500, ledgerFirst: replayFirst)
        if verbatim { replay[replayFirst ? 0 : 1] = first[0] }
        let result = try Self.parse(Self.header() + [Self.taskStarted("synthetic-turn")] + first + replay, env: env)
        #expect(result.rows.count == 2)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    /// A bounded pass that stops after a bare usage line resumes with the same pairing rule as a full parse. In a
    /// subagent file the ledger record is still buffered, so the state saved after the bare line is otherwise empty.
    @Test(arguments: [true, false])
    func `bare usage gives the same pairing across a bounded pass`(subagent: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var header = Self.header()
        let bare: [String: Any] = try [
            "timestamp": Self.timestamp(Self.timestampA, plusMilliseconds: 1000),
            "usage": ["prompt_tokens": 10, "completion_tokens": 1],
        ]
        var pair = try Self.mirrorPair(at: subagent ? 0 : 1998, gap: subagent ? 2000 : 2)
        if subagent {
            header[0]["payload"] = [
                "id": "synthetic-thread", "session_id": "execution-session",
                "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]],
            ]
            var payload = try #require(pair[0]["payload"] as? [String: Any])
            payload["session_id"] = "execution-session"
            pair[0]["payload"] = payload
        }
        let prefix = try env.jsonl(header + (subagent ? [pair[0], bare] : [bare]))
        let suffix = try env.jsonl(subagent ? [pair[1]] : pair)
        let file = env.root.appendingPathComponent("bounded-bare.jsonl")
        try (prefix + suffix).write(to: file, atomically: false, encoding: .utf8)
        let day = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)
        let partial = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, maxBytesToRead: Int64(prefix.utf8.count))
        let resumed = try Self.resume(file, range: range, first: partial)
        let cold = try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range)
        let expected = subagent ? 231 : 121
        #expect((partial.rows + resumed.rows).reduce(0) { $0 + $1.input + $1.output } == expected)
        #expect(cold.rows.reduce(0) { $0 + $1.input + $1.output } == expected)
    }

    /// A fork processes lines when read even while its parent is unresolved, so a bare line there separates the first
    /// observations without disabling near pairing. A parse that resolves the parent later matches a cold parse.
    @Test(arguments: [false, true])
    func `fork bare usage keeps later drifted pairs when the parent resolves late`(legacyFirst: Bool) throws {
        var body = try Self.mirrorPair(at: 1000, gap: 1000)
        try body.insert([
            "timestamp": Self.timestamp(Self.timestampA, plusMilliseconds: 1500),
            "usage": ["prompt_tokens": 10, "completion_tokens": 1],
        ], at: 1)
        body += try Self.mirrorPair(
            id: "two",
            usage: [60, 20, 6, 3],
            thread: [1160, 240, 116, 47],
            total: [920, 192, 92, 37],
            at: 10000,
            ledgerFirst: !legacyFirst)
        try Self.assertForkReplay(
            body: body, parent: .init(input: 760, cached: 152, output: 76), expectedTokens: 297)
    }

    @Test(arguments: [false, true])
    func `a counter that advances past its usage keeps equal requests distinct`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let pair = try Self.mirrorPair(
            id: "two",
            thread: ledgerFirst ? [200, 40, 20, 8] : [300, 60, 30, 12],
            total: ledgerFirst ? [300, 60, 30, 12] : [200, 40, 20, 8],
            at: 1000,
            ledgerFirst: ledgerFirst)
        let result = try Self.parse(
            Self.header() + Self.mirrorPair(thread: usage, total: usage) + pair, env: env)
        #expect(result.rows.count == 3)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 330)
    }

    /// Regression shape contributed by @kcharlan: compaction has a ledger-only request and a zero-delta mirror.
    @Test(arguments: [49, 5023, 20049])
    func `first post compaction response with a delayed mirror counts once`(gapMs: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let lines = try Self.header()
            + Self.mirrorPair(
                id: "r1",
                usage: [1000, 200, 100, 0],
                thread: [1000, 200, 100, 0],
                total: [1000, 200, 100, 0],
                gap: 0)
            + [
                Self.record(
                    id: "r2",
                    timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 1000),
                    usage: [5000, 0, 400, 0],
                    total: [6000, 200, 500, 0]),
                [
                    "type": "compacted",
                    "timestamp": Self.timestamp(Self.timestampA, plusMilliseconds: 1002),
                    "payload": ["message": ""],
                ],
                Self.header()[1],
                Self.realLegacy(
                    timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 1004),
                    usage: [0, 0, 0, 0],
                    total: [1000, 200, 100, 0]),
            ] + Self.mirrorPair(
                id: "r3",
                usage: [300, 100, 30, 0],
                thread: [6300, 300, 530, 0],
                total: [1300, 300, 130, 0],
                at: 2000,
                gap: gapMs)
        let result = try Self.parse(lines, env: env)
        #expect(result.rows.compactMap(\.responseID) == ["r1", "r2", "r3"])
        #expect(result.rows.count == 3)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 6830)
    }

    @Test(arguments: [false, true], [
        (fork: false, pairs: 3, totalOnly: false), (fork: true, pairs: 3, totalOnly: false),
        (fork: false, pairs: 71, totalOnly: false), (fork: true, pairs: 71, totalOnly: false),
        (fork: false, pairs: 3, totalOnly: true), (fork: true, pairs: 3, totalOnly: true),
        (fork: false, pairs: 71, totalOnly: true), (fork: true, pairs: 71, totalOnly: true),
    ])
    func `owned legacy replays preserve continuity after counter history eviction`(
        delayed: Bool, scenario: (fork: Bool, pairs: Int, totalOnly: Bool)) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var pairs: [[[String: Any]]] = []
        for index in 0..<scenario.pairs {
            let thread: [Int] = [1100 + index * 100, 220 + index * 20, 110 + index * 10, 44 + index * 4]
            let total: [Int] = [900 + index * 100, 180 + index * 20, 90 + index * 10, 36 + index * 4]
            let gap: Int = delayed && index == scenario.pairs - 1 ? 20000 : 2
            let pair: [[String: Any]] = try Self.mirrorPair(
                id: String(index),
                thread: thread,
                total: total,
                at: index * 30000,
                gap: gap)
            pairs.append(pair)
        }
        if scenario.totalOnly {
            var payload = try #require(pairs[0][1]["payload"] as? [String: Any])
            payload["info"] = ["total_token_usage": Self.tokens([900, 180, 90, 36])]
            pairs[0][1]["payload"] = payload
        }
        let replay = pairs[0][1]
        let last = pairs.removeLast()
        let baseline = Self.realLegacy(
            timestamp: Self.timestampA, usage: [0, 0, 0, 0], total: [800, 160, 80, 32])
        var body: [[String: Any]] = [baseline]
        for pair in pairs {
            body.append(contentsOf: pair)
        }
        body.append(contentsOf: [replay, last[0], last[0], replay, last[1]])
        let expectedTokens: Int = scenario.pairs * 110
        if scenario.fork {
            try Self.assertForkReplay(body: body, expectedTokens: expectedTokens)
        } else {
            let result = try Self.parse(Self.header() + body, env: env)
            let responseIDs: [String] = result.rows.compactMap(\CostUsageScanner.CodexUsageRow.responseID)
            let expectedResponseIDs: [String] = (0..<scenario.pairs).map { String($0) }
            let totalTokens: Int = result.rows.reduce(0) { $0 + $1.input + $1.output }
            #expect(responseIDs == expectedResponseIDs)
            #expect(result.rows.count == scenario.pairs)
            #expect(totalTokens == expectedTokens)
        }
    }

    @Test
    func `owned responses can reset a counter to a previously seen total`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let events = [(100, 900, 2), (100, 1000, 2), (100, 900, 2), (50, 950, 20000), (100, 1050, 20000)]
        var lines = Self.header()
        var threadTotal = 1000
        func totals(_ input: Int) -> [Int] { [input, input / 5, input / 10, 0] }
        for (index, event) in events.enumerated() {
            let (input, legacyTotal, gap) = event
            threadTotal += input
            lines += try Self.mirrorPair(
                id: "reset-\(index)",
                usage: totals(input),
                thread: totals(threadTotal),
                total: totals(legacyTotal),
                at: index * 30000,
                gap: gap)
        }
        let result = try Self.parse(lines, env: env)
        #expect(result.rows.count == 5)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 495)
    }

    @Test
    func `zero usage observations retain continuity across a bounded resume`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let prefix = try env.jsonl([
            Self.header()[0], Self.taskStarted("synthetic-turn"),
            ["type": "turn_context", "timestamp": Self.timestampA, "payload": ["model": "gpt-5.4"]],
            Self.realLegacy(timestamp: Self.timestampA, usage: [0, 0, 0, 0], total: [100, 0, 0, 0]),
        ])
        let suffix = try env.jsonl(Self.mirrorPair(thread: [1100, 20, 10, 4], total: [300, 20, 10, 4], at: 1000))
        let file = env.root.appendingPathComponent("zero-prefix.jsonl")
        try (prefix + suffix).write(to: file, atomically: false, encoding: .utf8)
        let day = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let first = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, maxBytesToRead: Int64(prefix.utf8.count))
        #expect(first.rows.isEmpty)
        let resumed = try Self.resume(file, range: range, first: first)
        let cold = try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range)
        #expect(cold.rows.count == 2)
        #expect(resumed.rows == cold.rows)
    }

    @Test(arguments: [false, true])
    func `fork replay preserves continuity for an appended delayed mirror`(unpairedStale: Bool) throws {
        var prefixLines = try Self.mirrorPair(total: [900, 180, 90, 36])
            + Self.mirrorPair(id: "two", thread: [1200, 240, 120, 48], total: [1000, 200, 100, 40], at: 1000)
        if unpairedStale {
            try prefixLines.append(Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 1500),
                usage: [50, 10, 5, 2],
                total: [950, 190, 95, 38]))
        }
        let suffix = try Self.mirrorPair(
            id: "three", thread: [1300, 260, 130, 52], total: [1100, 220, 110, 44], at: 2000, gap: 20000)
        try Self.assertForkReplay(body: prefixLines + suffix, prefixCount: prefixLines.count, expectedTokens: 330)
    }

    @Test
    func `fork replay retains a pending original ledger mirror`() throws {
        let pair = try Self.mirrorPair(
            id: "two", thread: [1200, 240, 120, 48], total: [1000, 200, 100, 40], at: 1000, gap: 20000)
        try Self.assertForkReplay(
            body: Self.mirrorPair(total: [900, 180, 90, 36]) + pair, prefixCount: 3, expectedTokens: 220)
    }

    @Test(arguments: [false, true], [0, 80, 100])
    func `total only fork mirrors match after parent resolution`(ledgerFirst: Bool, input: Int) throws {
        let pair: [[String: Any]] = try [
            Self.record(id: "one", usage: [100, 0, 10, 0], total: [1100, 0, 110, 0]),
            ["type": "event_msg", "timestamp": Self.timestamp(Self.timestampA, plusMilliseconds: 2), "payload": [
                "type": "token_count", "info": ["total_token_usage": Self.tokens([800 + input, 0, 80 + input / 10, 0])],
            ]],
        ]
        let ordered = ledgerFirst ? pair : Array(pair.reversed())
        try Self.assertForkReplay(
            body: [ordered[0]] + ordered,
            parent: .init(input: 800, cached: 0, output: 80),
            expectedTokens: input == 100 ? 110 : 110 + input + input / 10)
    }

    @Test(arguments: [false, true])
    func `total only deferred replays cannot claim a new legacy request`(ledgerFirst: Bool) throws {
        let replay: [[String: Any]] = try [
            Self.record(
                id: "one",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 1000),
                usage: [100, 20, 10, 4],
                total: [1200, 240, 120, 48]),
            ["type": "event_msg", "timestamp": Self.timestamp(Self.timestampA, plusMilliseconds: 1002), "payload": [
                "type": "token_count", "info": ["total_token_usage": Self.tokens([1000, 200, 100, 40])],
            ]],
        ]
        try Self.assertForkReplay(
            body: Self.mirrorPair(total: [900, 180, 90, 36]) + (ledgerFirst ? replay : Array(replay.reversed())),
            expectedTokens: 220)
    }

    @Test(arguments: [false, true], [
        (duplicateLedger: false, exact: false), (duplicateLedger: true, exact: false),
        (duplicateLedger: false, exact: true), (duplicateLedger: true, exact: true),
    ])
    func `fork resolution preserves the preceding mirror before later equal usage`(
        totalOnly: Bool, scenario: (duplicateLedger: Bool, exact: Bool)) throws
    {
        var before = Self.realLegacy(
            timestamp: Self.timestampA, usage: [100, 20, 10, 4], total: [900, 180, 90, 36])
        if totalOnly {
            var payload = try #require(before["payload"] as? [String: Any])
            payload["info"] = ["total_token_usage": Self.tokens([900, 180, 90, 36])]
            before["payload"] = payload
        }
        let ledger = try Self.record(
            id: "one",
            timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: scenario.exact ? 0 : 2),
            usage: [100, 20, 10, 4],
            total: scenario.exact ? [900, 180, 90, 36] : [1100, 220, 110, 44])
        let after = try Self.realLegacy(
            timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 4),
            usage: [100, 20, 10, 4],
            total: [1000, 200, 100, 40])
        try Self.assertForkReplay(
            body: [before, ledger] + (scenario.duplicateLedger ? [ledger] : []) + [after], expectedTokens: 220)
    }

    private static func assertForkReplay(
        body: [[String: Any]],
        parent: CostUsageCodexTotals = .init(input: 800, cached: 160, output: 80, reasoning: 32),
        prefixCount: Int? = nil,
        expectedTokens: Int) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var header = Self.header()
        header[0]["payload"] = ["id": "synthetic-thread", "forked_from_id": "parent", "timestamp": Self.timestampA]
        let file = env.root.appendingPathComponent("deferred-fork.jsonl")
        try env.jsonl(header + body).write(to: file, atomically: false, encoding: .utf8)
        let limit = try prefixCount.map { try Int64(env.jsonl(header + body.prefix($0)).utf8.count) }
        let day = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let first = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, maxBytesToRead: limit, inheritedTotalsResolver: { _, _ in .unresolved })
        #expect(first.bufferedUnresolvedForkLines?.isEmpty == false)
        // Persist and retry without a parent once, before resolving. No replay may change the owned ledger rows.
        let retried = try Self.resume(file, range: range, first: first, maxBytes: 0)
        #expect(retried.rows.isEmpty)
        let resumed = try Self.resume(file, range: range, first: retried, parent: parent, retainedRows: first.rows)
        let cold = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, inheritedTotalsResolver: { _, _ in .resolved(parent) })
        let kept = first.rows.filter { !resumed.replacedLegacyRowIndices.contains($0.eventIndex ?? -1) }
        let combinedRows: [CostUsageScanner.CodexUsageRow] = kept + resumed.rows
        let coldTokens: Int = cold.rows.reduce(0) { $0 + $1.input + $1.output }
        let resumedTokens: Int = combinedRows.reduce(0) { $0 + $1.input + $1.output }
        let coldResponseIDs: [String] = cold.rows.compactMap(\CostUsageScanner.CodexUsageRow.responseID)
        let resumedResponseIDs: [String] = combinedRows.compactMap(\CostUsageScanner.CodexUsageRow.responseID)
        #expect(coldTokens == expectedTokens)
        #expect(resumedTokens == expectedTokens)
        #expect(resumedResponseIDs == coldResponseIDs)
    }

    private static func resume(
        _ file: URL,
        range: CostUsageScanner.CostUsageDayRange,
        first: CostUsageScanner.CodexParseResult,
        parent: CostUsageCodexTotals? = nil,
        maxBytes: Int64? = nil,
        retainedRows: [CostUsageScanner.CodexUsageRow]? = nil) throws
        -> CostUsageScanner.CodexParseResult
    {
        func persisted<T: Codable>(_ value: T) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        }
        return try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: first.parsedBytes,
            initialModel: first.lastModel,
            initialSessionID: first.sessionId,
            initialTotals: first.lastCountedTotals,
            initialRawTotalsBaseline: first.lastRawTotalsBaseline,
            initialRawTotalsWatermark: first.lastRawTotalsWatermark,
            initialSeenRawTotals: first.seenRawTotals,
            initialHasDivergentTotals: first.hasDivergentTotals,
            initialHasInterleavedTotals: first.hasInterleavedTotals,
            initialCodexTurnID: first.lastCodexTurnID,
            initialCodexUsageRowIndex: first.nextUsageRowIndex,
            initialBufferedSubagentLines: persisted(first.bufferedSubagentLines),
            initialBufferedUnresolvedForkLines: persisted(first.bufferedUnresolvedForkLines),
            initialJSONLResumeState: first.jsonlResumeState,
            initialForkAccountingState: first.forkAccountingState,
            initialRequestLedgerState: persisted(first.requestLedgerState),
            initialRequestLedgerRows: retainedRows ?? first.rows,
            maxBytesToRead: maxBytes,
            inheritedTotalsResolver: { _, _ in parent.map(CostUsageScanner.CodexForkBaseline.resolved) ?? .unresolved })
    }

    private static func mirrorPair(
        id: String = "one",
        usage: [Int] = [100, 20, 10, 4],
        thread: [Int] = [1100, 220, 110, 44],
        total: [Int] = [860, 172, 86, 34],
        at milliseconds: Int = 0,
        gap: Int = 2,
        ledgerFirst: Bool = true) throws -> [[String: Any]]
    {
        let ledger = try self.record(
            id: id,
            timestamp: self.timestamp(
                self.timestampA,
                plusMilliseconds: milliseconds + (ledgerFirst ? 0 : gap)),
            usage: usage,
            total: thread)
        let legacy = try self.realLegacy(
            timestamp: self.timestamp(self.timestampA, plusMilliseconds: milliseconds + (ledgerFirst ? gap : 0)),
            usage: usage,
            total: total)
        return ledgerFirst ? [ledger, legacy] : [legacy, ledger]
    }

    static func taskStarted(_ turnID: String) -> [String: Any] {
        ["type": "event_msg", "timestamp": self.timestampA, "payload": ["type": "task_started", "turn_id": turnID]]
    }

    /// The token_count shape Codex writes: no turn_id in the payload.
    static func realLegacy(timestamp: String, usage: [Int], total: [Int]) -> [String: Any] {
        ["type": "event_msg", "timestamp": timestamp, "payload": [
            "type": "token_count", "info": [
                "last_token_usage": self.tokens(usage), "total_token_usage": self.tokens(total),
            ],
        ]]
    }
}
