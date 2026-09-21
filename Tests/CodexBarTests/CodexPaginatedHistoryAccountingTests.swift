import Foundation
import Testing
@testable import CodexBarCore

struct CodexPaginatedHistoryAccountingTests {
    private typealias Usage = (input: Int, cached: Int, output: Int)

    @Test
    func `paginated continuation does not bill the original ancestor's whole thread`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 16)
        let timestamp = env.isoString(for: day)
        let model = "openai/gpt-5.4"
        // Shape taken from Codex Desktop paginated rollouts: same session id, original
        // forked_from_id, history_base pointing at the previous page, and a cumulative
        // total already in the hundreds of millions. The ancestor snapshot is ~1.5M,
        // so totals-only fork accounting used to attribute ~756M to this file.
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-thread-session_page-two.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": [
                        "id": "thread-session",
                        "session_id": "thread-session",
                        "forked_from_id": "original-ancestor",
                        "timestamp": timestamp,
                        "history_mode": "paginated",
                        "history_base": [
                            "thread_id": "thread-session",
                            "end_ordinal_exclusive": 38505,
                            "end_byte_offset": 1_149_737_650,
                        ],
                    ],
                ],
                self.turnContext(timestamp: timestamp, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 740_012_153, cached: 725_510_144, output: 1_564_472),
                    last: (input: 188_393, cached: 188_288, output: 1616)),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 757_818_385, cached: 742_942_720, output: 1_616_068),
                    last: (input: 138_824, cached: 136_192, output: 1200)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            inheritedTotalsResolver: { parentSessionId, _ in
                #expect(parentSessionId == "original-ancestor")
                return .resolved(.init(input: 1_539_046, cached: 1_500_000, output: 20000))
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        // Owned suffix is last total minus (first total - first last).
        #expect(parsed.days[dayKey]?[normalized] == [17_994_625, 17_620_864, 53212])
    }

    @Test
    func `true fork still subtracts the parent snapshot when first total-last matches it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 16)
        let timestamp = env.isoString(for: day)
        let model = "openai/gpt-5.4"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-child-session.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "timestamp": timestamp,
                    ],
                ],
                self.turnContext(timestamp: timestamp, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 1100, cached: 920, output: 110),
                    last: (input: 100, cached: 20, output: 10)),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1250, cached: 940, output: 125),
                    last: (input: 150, cached: 20, output: 15)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            inheritedTotalsResolver: { parentSessionId, _ in
                #expect(parentSessionId == "parent-session")
                return .resolved(.init(input: 1000, cached: 900, output: 100))
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        #expect(parsed.days[dayKey]?[normalized] == [250, 40, 25])
    }

    @Test
    func `ordinary fork keeps totals-derived deltas that exceed last`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 16)
        let timestamp = env.isoString(for: day)
        let model = "openai/gpt-5.4"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-ordinary-fork.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "timestamp": timestamp,
                    ],
                ],
                self.turnContext(timestamp: timestamp, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 1100, cached: 920, output: 110),
                    last: (input: 40, cached: 20, output: 5)),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1200, cached: 940, output: 120),
                    last: (input: 50, cached: 20, output: 10)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            inheritedTotalsResolver: { _, _ in
                .resolved(.init(input: 1000, cached: 900, output: 100))
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        #expect(parsed.days[dayKey]?[normalized] == [200, 40, 20])
    }

    @Test
    func `first paginated page pointing history_base at the fork parent keeps the snapshot`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 16)
        let timestamp = env.isoString(for: day)
        let model = "openai/gpt-5.4"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-first-page.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": [
                        "id": "thread-session",
                        "forked_from_id": "original-ancestor",
                        "timestamp": timestamp,
                        "history_mode": "paginated",
                        "history_base": [
                            "thread_id": "original-ancestor",
                            "end_ordinal_exclusive": 214,
                            "end_byte_offset": 1_051_670,
                        ],
                    ],
                ],
                self.turnContext(timestamp: timestamp, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 1100, cached: 920, output: 110),
                    last: (input: 40, cached: 20, output: 5)),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1200, cached: 940, output: 120),
                    last: (input: 50, cached: 20, output: 10)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            inheritedTotalsResolver: { _, _ in
                .resolved(.init(input: 1000, cached: 900, output: 100))
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        #expect(parsed.days[dayKey]?[normalized] == [200, 40, 20])
    }

    @Test(arguments: [false, true], [false, true])
    func `paginated pages of the same thread do not double-count lifetime totals`(
        bounded: Bool,
        totalsOnlyTail: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 16)
        let timestamp = env.isoString(for: day)
        let model = "openai/gpt-5.4"
        let ancestorID = "original-ancestor"
        let threadID = "thread-session"

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-\(ancestorID).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": [
                        "id": ancestorID,
                        "timestamp": timestamp,
                    ],
                ],
                self.turnContext(timestamp: timestamp, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 50, cached: 40, output: 5),
                    last: (input: 50, cached: 40, output: 5)),
            ]))

        let pageOneFork = env.isoString(for: day.addingTimeInterval(2))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-\(threadID).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": pageOneFork,
                    "payload": [
                        "id": threadID,
                        "forked_from_id": ancestorID,
                        "timestamp": pageOneFork,
                        "history_mode": "paginated",
                        "history_base": [
                            "thread_id": ancestorID,
                            "end_ordinal_exclusive": 214,
                            "end_byte_offset": 1_051_670,
                        ],
                    ],
                ],
                self.turnContext(timestamp: pageOneFork, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 150, cached: 120, output: 15),
                    last: (input: 100, cached: 80, output: 10)),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(4)),
                    model: model,
                    total: (input: 1000, cached: 800, output: 80),
                    last: (input: 200, cached: 100, output: 20)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        if bounded {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: day, now: day, options: options)
        }
        let pageTwoStarted = env.isoString(for: day.addingTimeInterval(5))
        let pageTwoFile = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-\(threadID)_page-two.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": pageTwoStarted,
                    "payload": [
                        "id": threadID,
                        "session_id": threadID,
                        "forked_from_id": ancestorID,
                        "timestamp": pageTwoStarted,
                        "history_mode": "paginated",
                        "history_base": [
                            "thread_id": threadID,
                            "end_ordinal_exclusive": 400,
                            "end_byte_offset": 50000,
                        ],
                    ],
                ],
                self.turnContext(timestamp: pageTwoStarted, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(6)),
                    model: model,
                    total: (input: 1100, cached: 880, output: 90),
                    last: (input: 100, cached: 80, output: 10)),
                [
                    "type": "session_meta",
                    "timestamp": pageTwoStarted,
                    "payload": ["id": ancestorID, "timestamp": timestamp],
                ],
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(7)),
                    model: model,
                    total: (input: 1300, cached: 1000, output: 110),
                    last: totalsOnlyTail ? nil : (input: 150, cached: 90, output: 15)),
            ]))

        if bounded {
            let lines = try String(contentsOf: pageTwoFile, encoding: .utf8).split(separator: "\n")
            options.maxCodexSessionFileBytes = Int64((lines.prefix(3).joined(separator: "\n") + "\n").utf8.count)
            options.maxCodexScanBytesPerRefresh = options.maxCodexSessionFileBytes
        }

        var report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        if bounded {
            try self.checkpointContinuationAfterFirstEvent(
                env: env,
                day: day,
                file: pageTwoFile,
                sessionID: threadID,
                options: &options)
        }
        for pass in 201...220 {
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            if reopened.codexScanCatchUpPending != true { break }
            report = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: day, now: day.addingTimeInterval(Double(pass)), options: options)
        }

        // Final cumulative total of the continued thread, plus the ancestor's own 50,
        // with each page owning only its suffix: 50 + 950 + 300 = 1,300.
        #expect(self.inputTokens(report) == 1300)
        #expect(report.data.map(\.outputTokens).reduce(0) { $0 + ($1 ?? 0) } == 110)
        let completed = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(completed.files[pageTwoFile.path]?.codexRows?.map(\.input) == [100, 200])
        #expect(completed.files[pageTwoFile.path]?.codexScanComplete == true)
        #expect(completed.codexScanCatchUpPending != true)
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let unchanged = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(240), options: options)
        #expect(self.inputTokens(unchanged) == 1300)
        #expect(recorder.snapshot().usageRowsProcessed == 0)
    }

    @Test
    func `stale parser revision reparses an inflated continuation without forceRescan`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 16)
        let timestamp = env.isoString(for: day)
        let model = "openai/gpt-5.4"
        let ancestorID = "original-ancestor"
        let threadID = "thread-session"

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-\(ancestorID).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": ["id": ancestorID, "timestamp": timestamp],
                ],
                self.turnContext(timestamp: timestamp, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 50, cached: 40, output: 5),
                    last: (input: 50, cached: 40, output: 5)),
            ]))

        let pageOneFork = env.isoString(for: day.addingTimeInterval(2))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-\(threadID).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": pageOneFork,
                    "payload": [
                        "id": threadID,
                        "forked_from_id": ancestorID,
                        "timestamp": pageOneFork,
                        "history_mode": "paginated",
                        "history_base": [
                            "thread_id": ancestorID,
                            "end_ordinal_exclusive": 214,
                            "end_byte_offset": 1_051_670,
                        ],
                    ],
                ],
                self.turnContext(timestamp: pageOneFork, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 150, cached: 120, output: 15),
                    last: (input: 100, cached: 80, output: 10)),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(4)),
                    model: model,
                    total: (input: 1000, cached: 800, output: 80),
                    last: (input: 200, cached: 100, output: 20)),
            ]))

        let pageTwoStarted = env.isoString(for: day.addingTimeInterval(5))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-\(threadID)_page-two.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": pageTwoStarted,
                    "payload": [
                        "id": threadID,
                        "session_id": threadID,
                        "forked_from_id": ancestorID,
                        "timestamp": pageTwoStarted,
                        "history_mode": "paginated",
                        "history_base": [
                            "thread_id": threadID,
                            "end_ordinal_exclusive": 400,
                            "end_byte_offset": 50000,
                        ],
                    ],
                ],
                self.turnContext(timestamp: pageTwoStarted, model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(6)),
                    model: model,
                    total: (input: 1100, cached: 880, output: 90),
                    last: (input: 100, cached: 80, output: 10)),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(7)),
                    model: model,
                    total: (input: 1300, cached: 1000, output: 110),
                    last: (input: 150, cached: 90, output: 15)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(self.inputTokens(cold) == 1300)

        var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let pageTwoPath = try #require(legacy.files.keys.first { $0.contains("_page-two") })
        var pageTwo = try #require(legacy.files[pageTwoPath])
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        pageTwo.days = [dayKey: [normalized: [1250, 960, 105]]]
        pageTwo.codexParserRevision = CostUsageFileUsage.currentCodexParserRevision - 1
        legacy.files[pageTwoPath] = pageTwo
        legacy.days = [dayKey: [normalized: [2250, 1760, 185]]]
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy)

        options.forceRescan = false
        let warm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(60),
            options: options)
        #expect(self.inputTokens(warm) == 1300)
        #expect(
            CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[pageTwoPath]?.hasCurrentCodexParser
                == true)
    }

    private func checkpointContinuationAfterFirstEvent(
        env: CostUsageTestEnvironment,
        day: Date,
        file: URL,
        sessionID: String,
        options: inout CostUsageScanner.Options) throws
    {
        var partial = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(partial.files[file.path]?.hasBufferedCodexUnresolvedForkLines == true)
        let byteLimit = options.maxCodexSessionFileBytes
        // Hydration resolves the parent on a later refresh; stop immediately after replaying the first event.
        options.maxCodexSessionFileBytes = 16
        options.maxCodexScanBytesPerRefresh = 16
        for pass in 1...100 where partial.files[file.path]?.codexRows?.isEmpty != false {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(Double(pass)),
                options: options)
            partial = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        }
        options.maxCodexSessionFileBytes = 1
        options.maxCodexScanBytesPerRefresh = 1
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(200), options: options)
        partial = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let page = try #require(partial.files[file.path])
        #expect(page.codexScanComplete == false)
        #expect(page.codexRows?.map(\.input) == [100])
        #expect(try #require(page.parsedBytes) < #require(page.codexScanTargetSize))
        #expect(page.codexJSONLResumeState != nil)
        #expect(page.codexForkAccountingState?.inheritedTotals?.input == 1000)
        #expect(page.codexForkAccountingState?.metadata.sessionId == sessionID)
        #expect(!page.hasBufferedCodexUnresolvedForkLines)
        options.maxCodexSessionFileBytes = byteLimit
        options.maxCodexScanBytesPerRefresh = byteLimit
    }

    private func inputTokens(_ report: CostUsageDailyReport) -> Int {
        report.data.map(\.inputTokens).reduce(0) { $0 + ($1 ?? 0) }
    }

    private func turnContext(timestamp: String, model: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": [
                "model": model,
            ],
        ]
    }

    private func tokenCount(
        timestamp: String,
        model: String,
        total: Usage,
        last: Usage?) -> [String: Any]
    {
        var info: [String: Any] = [
            "model": model,
            "total_token_usage": [
                "input_tokens": total.input,
                "cached_input_tokens": total.cached,
                "output_tokens": total.output,
            ],
        ]
        if let last {
            info["last_token_usage"] = [
                "input_tokens": last.input,
                "cached_input_tokens": last.cached,
                "output_tokens": last.output,
            ]
        }
        return [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": info,
            ],
        ]
    }
}
