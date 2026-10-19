import Foundation
import Testing
@testable import CodexBarCore

struct CodexResumedCounterResetTests {
    private static let model = "openai/gpt-5.5"
    private static let sessionID = "resumed-session"
    /// Ten 1,000-token requests before the resume and six 1,100-token requests after it.
    private static let resumedSessionInput = 16600

    @Test
    func `resumed legacy session counts requests after its counter restarts`() throws {
        let parsed = try Self.parse(Self.resumedSessionEvents)

        #expect(parsed.input == Self.resumedSessionInput)
        #expect(parsed.rows == 16)
    }

    @Test
    func `counter drop without a resume boundary stays contained`() throws {
        let parsed = try Self.parse { next in
            // Interleaved lineages are indistinguishable from a reset without a resume boundary.
            (1...10).map { Self.tokenCount(timestamp: next(), total: $0 * 1000, last: 1000) }
                + (1...6).map { Self.tokenCount(timestamp: next(), total: $0 * 1100, last: 1100) }
        }

        #expect(parsed.input == 10000)
        #expect(parsed.hasInterleavedTotals)
    }

    @Test
    func `resumed session that continues its counter is counted once`() throws {
        let parsed = try Self.parse { next in
            (1...10).map { Self.tokenCount(timestamp: next(), total: $0 * 1000, last: 1000) }
                + [Self.sessionMeta(timestamp: next())]
                + (11...14).map { Self.tokenCount(timestamp: next(), total: $0 * 1000, last: 1000) }
        }

        #expect(parsed.input == 14000)
        #expect(parsed.rows == 14)
    }

    /// 65 and 200 requests evict the first snapshot from the tracker's 64-entry seen window.
    @Test(arguments: [10, 65, 200])
    func `replayed pre-resume snapshot cannot start a new counter epoch`(requests: Int) throws {
        let parsed = try Self.parse { next in
            // An exact copy of the first snapshot also has total == last; it must stay a replay.
            (1...requests).map { Self.tokenCount(timestamp: next(), total: $0 * 1000, last: 1000) }
                + [Self.sessionMeta(timestamp: next())]
                + (1...3).map { Self.tokenCount(timestamp: next(), total: $0 * 1000, last: 1000) }
        }

        #expect(parsed.input == requests * 1000)
    }

    @Test
    func `resumed fork keeps its inherited baseline accounting`() throws {
        let parsed = try Self.parse(forkedFrom: "parent-session") { next in
            (1...10).map { Self.tokenCount(timestamp: next(), total: $0 * 1000, last: 1000) }
                + [Self.sessionMeta(timestamp: next(), forkedFrom: "parent-session")]
                + (1...6).map { Self.tokenCount(timestamp: next(), total: $0 * 1100, last: 1100) }
        }

        #expect(parsed.input == 10000)
    }

    @Test
    func `byte budget cut at the resume boundary keeps the restarted counter`() throws {
        var lostBudgets: [Int: Int] = [:]
        // The step is far smaller than the resume window, so some budget multiple lands inside it.
        for budget in stride(from: 150, through: 2600, by: 47) {
            let env = try CostUsageTestEnvironment()
            defer { env.cleanup() }
            let day = try Self.writeResumedSession(env: env)
            var options = Self.scanOptions(env: env)
            options.maxCodexScanBytesPerRefresh = Int64(budget)

            let input = Self.scanUntilComplete(env: env, day: day, options: options)
            if input != Self.resumedSessionInput {
                lostBudgets[budget] = input
            }
        }

        #expect(lostBudgets.isEmpty)
    }

    @Test
    func `previous parser revision recovers a truncated resumed tail`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try Self.writeResumedSession(env: env)
        let options = Self.scanOptions(env: env)
        #expect(Self.scanUntilComplete(env: env, day: day, options: options) == Self.resumedSessionInput)

        // Rebuild the state an older parser stored: complete, but without the post-resume rows.
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let path = try #require(cache.files.keys.first)
        var usage = try #require(cache.files[path])
        let truncatedRows = try Array(#require(usage.codexRows).prefix(10))
        usage.codexRows = truncatedRows
        usage.days = CostUsageScanner.codexFileDays(rows: truncatedRows)
        usage.codexParserRevision = CostUsageFileUsage.currentCodexParserRevision - 1
        cache.files[path] = usage
        // The only file owns every global day aggregate.
        cache.days = usage.days
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)
        let stale = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[path])
        #expect(!stale.hasCurrentCodexParser)
        #expect(stale.codexRows?.count == 10)

        #expect(Self.scanUntilComplete(env: env, day: day, options: options) == Self.resumedSessionInput)
        let recovered = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[path])
        #expect(recovered.hasCurrentCodexParser)
        #expect(recovered.codexRows?.count == 16)
    }

    @Test(arguments: [true, false])
    func `resume appended after a completed scan restarts only with recorded origins`(originsRecorded: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let lines = Self.sessionLines(env: env, day: day, events: Self.resumedSessionEvents)
        // Session metadata, turn context, and the ten pre-resume requests.
        let resumeIndex = 12
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(env.isoString(for: day))-appended.jsonl",
            contents: env.jsonl(Array(lines[..<resumeIndex])))
        let options = Self.scanOptions(env: env)
        #expect(Self.scanUntilComplete(env: env, day: day, options: options) == 10000)

        if !originsRecorded {
            // Earlier history parsed before origins were recorded cannot prove a restart is not a replay.
            var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            let path = try #require(cache.files.keys.first)
            cache.files[path]?.codexRequestLedgerState?.counterOrigins = nil
            CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl(Array(lines[resumeIndex...])).utf8))
        try handle.close()

        let expected = originsRecorded ? Self.resumedSessionInput : 10000
        #expect(Self.scanUntilComplete(env: env, day: day, options: options) == expected)
    }

    // MARK: - Fixtures

    private static func resumedSessionEvents(_ next: () -> String) -> [[String: Any]] {
        // `codex resume` appends to the same rollout and restarts the cumulative counter.
        (1...10).map { Self.tokenCount(timestamp: next(), total: $0 * 1000, last: 1000) }
            + [self.sessionMeta(timestamp: next()), self.turnContext(timestamp: next())]
            + (1...6).map { Self.tokenCount(timestamp: next(), total: $0 * 1100, last: 1100) }
    }

    private static func sessionLines(
        env: CostUsageTestEnvironment,
        day: Date,
        forkedFrom parentID: String? = nil,
        events makeEvents: (() -> String) -> [[String: Any]]) -> [[String: Any]]
    {
        var seconds = 0.0
        func next() -> String {
            seconds += 1
            return env.isoString(for: day.addingTimeInterval(seconds))
        }
        return [
            Self.sessionMeta(timestamp: env.isoString(for: day), forkedFrom: parentID),
            Self.turnContext(timestamp: next()),
        ] + makeEvents(next)
    }

    private static func writeResumedSession(env: CostUsageTestEnvironment) throws -> Date {
        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(env.isoString(for: day))-resumed.jsonl",
            contents: env.jsonl(Self.sessionLines(env: env, day: day, events: Self.resumedSessionEvents)))
        return day
    }

    private static func sessionMeta(timestamp: String, forkedFrom parentID: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["id": Self.sessionID, "timestamp": timestamp]
        payload["forked_from_id"] = parentID
        return ["type": "session_meta", "timestamp": timestamp, "payload": payload]
    }

    private static func turnContext(timestamp: String) -> [String: Any] {
        ["type": "turn_context", "timestamp": timestamp, "payload": ["model": self.model]]
    }

    private static func tokenCount(timestamp: String, total: Int, last: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "model": self.model,
                    "total_token_usage": ["input_tokens": total, "cached_input_tokens": 0, "output_tokens": 0],
                    "last_token_usage": ["input_tokens": last, "cached_input_tokens": 0, "output_tokens": 0],
                ],
            ],
        ]
    }

    // MARK: - Scanning

    private static func parse(
        forkedFrom parentID: String? = nil,
        _ makeEvents: (() -> String) -> [[String: Any]]) throws
        -> (input: Int?, rows: Int, hasInterleavedTotals: Bool)
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(env.isoString(for: day))-parsed.jsonl",
            contents: env.jsonl(Self.sessionLines(env: env, day: day, forkedFrom: parentID, events: makeEvents)))
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        return (parsed.days[dayKey]?["gpt-5.5"]?[safe: 0], parsed.rows.count, parsed.hasInterleavedTotals)
    }

    private static func scanOptions(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func report(day: Date, options: CostUsageScanner.Options, now: Date) -> Int {
        let report = CostUsageControlledClockScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: now,
            options: options)
        return report.data.reduce(0) { $0 + ($1.inputTokens ?? 0) }
    }

    /// Refreshes until the bounded catch-up finishes and returns the day's reported input tokens.
    private static func scanUntilComplete(
        env: CostUsageTestEnvironment,
        day: Date,
        options: CostUsageScanner.Options) -> Int
    {
        var input = 0
        for refresh in 1...200 {
            input = Self.report(day: day, options: options, now: day.addingTimeInterval(Double(refresh)))
            let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            if cache.codexScanCatchUpPending != true, cache.codexActiveLookbackState == nil { break }
        }
        return input
    }
}
