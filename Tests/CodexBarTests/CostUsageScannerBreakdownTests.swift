import Foundation
import Testing
@testable import CodexBarCore

// swiftlint:disable file_length
// swiftlint:disable type_body_length
struct CostUsageScannerBreakdownTests {
    private typealias Usage = (input: Int, cached: Int, output: Int)

    private func codexTurnContext(timestamp: String, model: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": [
                "model": model,
            ],
        ]
    }

    private func codexTokenCount(
        timestamp: String,
        model: String,
        total: Usage? = nil,
        last: Usage? = nil) -> [String: Any]
    {
        var info: [String: Any] = [
            "model": model,
        ]
        if let total {
            info["total_token_usage"] = [
                "input_tokens": total.input,
                "cached_input_tokens": total.cached,
                "output_tokens": total.output,
            ]
        }
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

    private func codexTokenCountWithoutModel(timestamp: String, last: Usage) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": last.input,
                        "cached_input_tokens": last.cached,
                        "output_tokens": last.output,
                    ],
                ],
            ],
        ]
    }

    private func oversizedCodexTurnContextLine(timestamp: String, model: String) -> String {
        let largeInstructions = String(repeating: "x", count: 300 * 1024)
        return #"{"type":"turn_context","timestamp":""#
            + timestamp
            + #"","payload":{"model":""#
            + model
            + #"","instructions":""#
            + largeInstructions
            + #""}}"#
    }

    private func oversizedCodexTurnContextInfoModelLine(timestamp: String, model: String) -> String {
        let largeInstructions = String(repeating: "x", count: 300 * 1024)
        return #"{"type":"turn_context","timestamp":""#
            + timestamp
            + #"","payload":{"empty":"","info":{"model":""#
            + model
            + #""},"instructions":""#
            + largeInstructions
            + #""}}"#
    }

    private func oversizedCodexTurnContextPromptOnlyLine(timestamp: String, promptModel: String) -> String {
        let prompt = #"example: {\"type\":\"turn_context\",\"payload\":{\"model\":\"\#(promptModel)\"}}"#
            + String(repeating: "x", count: 300 * 1024)
        return #"{"type":"turn_context","timestamp":""#
            + timestamp
            + #"","payload":{"instructions":""#
            + prompt
            + #""}}"#
    }

    @Test
    func `codex daily report parses token counts and caches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
        let firstTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                    "model": model,
                ],
            ],
        ]

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)
        #expect(first.data[0].modelsUsed == ["gpt-5.2-codex"])
        #expect(first.data[0].modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "gpt-5.2-codex",
                costUSD: first.data[0].costUSD,
                totalTokens: 110),
        ])
        #expect(first.data[0].totalTokens == 110)
        #expect((first.data[0].costUSD ?? 0) > 0)

        let secondTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 40,
                        "output_tokens": 16,
                    ],
                    "model": model,
                ],
            ],
        ]
        try env.jsonl([turnContext, firstTokenCount, secondTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(second.data.count == 1)
        #expect(second.data[0].modelsUsed == ["gpt-5.2-codex"])
        #expect(second.data[0].totalTokens == 176)
        #expect((second.data[0].costUSD ?? 0) > (first.data[0].costUSD ?? 0))
    }

    @Test
    func `codex long turn context preserves model attribution`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
                "instructions": String(repeating: "x", count: 40 * 1024),
            ],
        ]
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 40,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "long-turn-context.jsonl",
            contents: env.jsonl([turnContext, tokenCount]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [100, 40, 10])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    @Test
    func `codex oversized turn context prefix preserves model attribution`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let turnContextLine = self.oversizedCodexTurnContextLine(timestamp: iso0, model: model)
        let tokenCountLine = try env.jsonl([
            self.codexTokenCountWithoutModel(timestamp: iso1, last: (input: 120, cached: 30, output: 12)),
        ])

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "oversized-turn-context.jsonl",
            contents: turnContextLine + "\n" + tokenCountLine)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [120, 30, 12])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    @Test
    func `codex oversized turn context prefix supports nested info model`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let turnContextLine = self.oversizedCodexTurnContextInfoModelLine(timestamp: iso0, model: model)
        let tokenCountLine = try env.jsonl([
            self.codexTokenCountWithoutModel(timestamp: iso1, last: (input: 120, cached: 30, output: 12)),
        ])

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "oversized-turn-context-info-model.jsonl",
            contents: turnContextLine + "\n" + tokenCountLine)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [120, 30, 12])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    @Test
    func `codex oversized turn context ignores prompt model examples`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let turnContextLine = self.oversizedCodexTurnContextPromptOnlyLine(
            timestamp: iso1,
            promptModel: "openai/gpt-5.5")
        let tokenCountLine = try env.jsonl([
            self.codexTokenCountWithoutModel(timestamp: iso2, last: (input: 120, cached: 30, output: 12)),
        ])

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "oversized-turn-context-prompt-example.jsonl",
            contents: env.jsonl([self.codexTurnContext(timestamp: iso0, model: "openai/gpt-5.4")])
                + turnContextLine + "\n" + tokenCountLine)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.4"] == [120, 30, 12])
        #expect(parsed.days[dayKey]?["gpt-5.5"] == nil)
    }

    @Test
    func `codex token count model applies without turn context model`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)

        let contents = try env.jsonl([
            self.codexTokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: "openai/gpt-5.5",
                last: (input: 50, cached: 10, output: 5)),
        ])
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "token-count-model.jsonl",
            contents: contents)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [50, 10, 5])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    @Test
    func `codex daily report writes corrected cache artifact for oversized turn context`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let turnContextLine = self.oversizedCodexTurnContextLine(timestamp: iso0, model: model)
        let tokenCountLine = try env.jsonl([
            self.codexTokenCountWithoutModel(timestamp: iso1, last: (input: 120, cached: 30, output: 12)),
        ])

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "cached-oversized-turn-context.jsonl",
            contents: turnContextLine + "\n" + tokenCountLine)

        let oldCacheDir = env.cacheRoot.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: oldCacheDir, withIntermediateDirectories: true)
        let oldCacheURL = oldCacheDir.appendingPathComponent("codex-v7.json", isDirectory: false)
        let oldCache = #"{"version":1,"lastScanUnixMs":9999999999999,"files":{},"days":{"\#(dayKey)":"#
            + #"{"gpt-5":[999,0,0]}}}"#
        try oldCache.write(to: oldCacheURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)
        #expect(first.data[0].modelsUsed == ["gpt-5.5"])
        #expect(first.data[0].modelBreakdowns?.map(\.modelName) == ["gpt-5.5"])
        #expect(first.data[0].totalTokens == 132)

        let newCacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(newCacheURL.lastPathComponent == "codex-v8.json")
        #expect(FileManager.default.fileExists(atPath: newCacheURL.path))
        #expect(FileManager.default.fileExists(atPath: oldCacheURL.path))

        try FileManager.default.removeItem(at: fileURL)
        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(60),
            options: options)
        #expect(second.data.count == 1)
        #expect(second.data[0].modelsUsed == ["gpt-5.5"])
        #expect(second.data[0].totalTokens == 132)
    }

    @Test
    func `codex daily report prefers last token usage over divergent totals`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let iso0 = env.isoString(for: day)
        let model = "openai/gpt-5.5"
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([
                turnContext,
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 20, output: 10),
                    last: (input: 100, cached: 20, output: 10)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 160, cached: 40, output: 16),
                    last: (input: 60, cached: 20, output: 6)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1000, cached: 900, output: 100),
                    last: (input: 40, cached: 30, output: 5)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(4)),
                    model: model,
                    total: (input: 1050, cached: 930, output: 110),
                    last: (input: 50, cached: 30, output: 10)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 250,
            cachedInputTokens: 100,
            outputTokens: 31)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 250)
        #expect(report.data[0].outputTokens == 31)
        #expect(report.data[0].totalTokens == 281)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex total only after divergent totals uses raw delta when it continues`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "mixed-raw-continuing.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 0, output: 0),
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1000, cached: 0, output: 0),
                    last: (input: 40, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1050, cached: 0, output: 0)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 190)
        #expect(parsed.lastTotals == nil)
    }

    @Test
    func `codex total only after divergent totals preserves zero raw dimensions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "mixed-stale-dimension.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 0, output: 0),
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1000, cached: 900, output: 0),
                    last: (input: 40, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1050, cached: 900, output: 0)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 190)
        #expect(packed[safe: 1] == 0)
        #expect(parsed.lastTotals == nil)
    }

    @Test
    func `codex total only after divergent totals can resume from counted baseline`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "mixed-counted-resume.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 0, output: 0),
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1000, cached: 0, output: 0),
                    last: (input: 40, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 180, cached: 0, output: 0)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 180)
        #expect(parsed.lastTotals?.input == 180)
    }

    @Test
    func `codex total only after last only counts from last based baseline`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "last-then-total.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 150, cached: 0, output: 0)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 150)
        #expect(parsed.lastTotals?.input == 150)
    }

    @Test
    func `codex daily report includes archived sessions and dedupes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 22)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "openai/gpt-5.2-codex"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "session_id": "sess-archived-1",
            ],
        ]
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                    "model": model,
                ],
            ],
        ]

        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        let archivedName = "rollout-\(dayKey)T12-00-00-archived.jsonl"
        let contents = try env.jsonl([sessionMeta, turnContext, tokenCount])
        _ = try env.writeCodexArchivedSessionFile(filename: archivedName, contents: contents)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)
        #expect(first.data[0].totalTokens == 110)

        _ = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: contents)
        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(second.data.count == 1)
        #expect(second.data[0].totalTokens == 110)
    }

    @Test
    func `codex daily report includes long lived sessions stored under older date partitions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let fileDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"

        _ = try env.writeCodexSessionFile(
            day: fileDay,
            filename: "rollout-2026-02-27T11-29-28-cross-day.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": "cross-day-session",
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 100)
        #expect(report.data[0].outputTokens == 10)
        #expect(report.data[0].totalTokens == 110)
    }

    @Test
    func `codex forked child subtracts parent totals at fork timestamp`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let parentTs0 = env.isoString(for: parentDay)
        let parentTs1 = env.isoString(for: parentDay.addingTimeInterval(1))
        let parentTs2 = env.isoString(for: parentDay.addingTimeInterval(2))
        let parentTs3 = env.isoString(for: parentDay.addingTimeInterval(3))
        let childForkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))
        let childTs1 = env.isoString(for: childDay.addingTimeInterval(1))
        let childTs2 = env.isoString(for: childDay.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent"
        let childSessionId = "sess-child"

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": parentTs0,
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs3,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 8,
                                "output_tokens": 3,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": childForkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": childDay.ISO8601Format(),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 27,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child inherits counted parent totals when totals diverge`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-diverged"
        let childSessionId = "sess-child-diverged"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                self.codexTurnContext(timestamp: env.isoString(for: parentDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: parentDay.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 0, output: 0),
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: parentDay.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1000, cached: 0, output: 0),
                    last: (input: 40, cached: 0, output: 0)),
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                self.codexTurnContext(timestamp: env.isoString(for: childDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: childDay.addingTimeInterval(1)),
                    model: model,
                    total: (input: 140, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: childDay.addingTimeInterval(2)),
                    model: model,
                    total: (input: 170, cached: 0, output: 0)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 30)
        #expect(report.data[0].totalTokens == 30)
    }

    @Test
    func `codex forked child subtracts inherited replay from last token usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let parentTs0 = env.isoString(for: parentDay)
        let parentTs1 = env.isoString(for: parentDay.addingTimeInterval(1))
        let parentTs2 = env.isoString(for: parentDay.addingTimeInterval(2))
        let childTs1 = env.isoString(for: childDay.addingTimeInterval(1))
        let childTs2 = env.isoString(for: childDay.addingTimeInterval(2))
        let childTs3 = env.isoString(for: childDay.addingTimeInterval(3))

        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-last"
        let childSessionId = "sess-child-last"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": parentTs0,
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": childDay.ISO8601Format(),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 3,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs3,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child ignores replayed parent prefix sequence`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-prefix"
        let childSessionId = "sess-child-prefix"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(5))

        let parentEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl(parentEvents))

        let childEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": childSessionId,
                    "forked_from_id": parentSessionId,
                    "timestamp": forkTs,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: childDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(4)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(5)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 35,
                            "cached_input_tokens": 9,
                            "output_tokens": 4,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(6)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 42,
                            "cached_input_tokens": 11,
                            "output_tokens": 5,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl(childEvents))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child subtracts inherited replay even when session meta appears late`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-late-meta"
        let childSessionId = "sess-child-late-meta"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(5))

        let parentEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl(parentEvents))

        let childEvents: [[String: Any]] = [
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: childDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "session_meta",
                "payload": [
                    "id": childSessionId,
                    "forked_from_id": parentSessionId,
                    "timestamp": forkTs,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(4)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 35,
                            "cached_input_tokens": 9,
                            "output_tokens": 4,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(5)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 42,
                            "cached_input_tokens": 11,
                            "output_tokens": 5,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl(childEvents))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child resolves parent when parent session file is a symlink`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-symlink"
        let childSessionId = "sess-child-symlink"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(3))

        let parentContents = try env.jsonl([
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ])

        let parentTarget = env.root.appendingPathComponent("parent-target.jsonl", isDirectory: false)
        try parentContents.write(to: parentTarget, atomically: true, encoding: .utf8)

        let comps = Calendar.current.dateComponents([.year, .month, .day], from: parentDay)
        let parentDir = env.codexSessionsRoot
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let parentLink = parentDir.appendingPathComponent(
            "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            isDirectory: false)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: parentTarget)

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 27,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child resolves parent by exact session meta id`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let wantedParentSessionId = "sess-parent-exact"
        let wrongParentSessionId = "sess-parent-exact-extra"
        let childSessionId = "sess-child-exact"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(3))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(wrongParentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": wrongParentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: parentDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 1000,
                                "cached_input_tokens": 100,
                                "output_tokens": 100,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-29-\(wantedParentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": wantedParentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: parentDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 8,
                                "output_tokens": 3,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": wantedParentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 35,
                                "cached_input_tokens": 9,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 42,
                                "cached_input_tokens": 11,
                                "output_tokens": 5,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child compares parent snapshots by parsed timestamp`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-timestamp"
        let childSessionId = "sess-child-timestamp"

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": "2026-02-27T23:59:58Z",
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": "2026-02-27T23:59:59Z",
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": "2026-02-28T00:00:01Z",
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": "2026-02-28T08:00:00+08:00",
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 25,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 10,
                                "output_tokens": 6,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 10,
            cachedInputTokens: 5,
            outputTokens: 4)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 10)
        #expect(report.data[0].outputTokens == 4)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex first refresh keeps unrelated archived sessions out of cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let archivedDay = try env.makeLocalNoon(year: 2025, month: 1, day: 1)
        let model = "openai/gpt-5.2-codex"

        _ = try env.writeCodexSessionFile(
            day: reportDay,
            filename: "rollout-2026-03-11T11-30-27-session-recent.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        let archivedURL = try env.writeCodexArchivedSessionFile(
            filename: "rollout-2025-01-01T12-00-00-session-archived.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: archivedDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: archivedDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 10,
                                "output_tokens": 5,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: options)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(report.data.count == 1)
        #expect(cache.files.keys.contains { $0.hasSuffix("session-recent.jsonl") })
        #expect(!cache.files.keys.contains(archivedURL.path))
    }

    @Test
    func `codex root switch reloads long lived sessions from older partitions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        func writeSessionFile(
            root: URL,
            day: Date,
            filename: String,
            contents: String) throws -> URL
        {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
            let dir = root
                .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(filename, isDirectory: false)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let fileDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let otherSessionsRoot = env.root
            .appendingPathComponent("other-codex-home", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: otherSessionsRoot, withIntermediateDirectories: true)

        let oldRootURL = try env.writeCodexSessionFile(
            day: reportDay,
            filename: "rollout-2026-03-11T11-30-27-session-old-root.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try writeSessionFile(
            root: otherSessionsRoot,
            day: fileDay,
            filename: "rollout-2026-02-27T11-30-27-session-new-root.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 5,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var firstOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        firstOptions.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: firstOptions)

        var secondOptions = CostUsageScanner.Options(
            codexSessionsRoot: otherSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        secondOptions.refreshMinIntervalSeconds = 0

        let secondReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: secondOptions)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(secondReport.data.count == 1)
        #expect(secondReport.data[0].inputTokens == 10)
        #expect(secondReport.data[0].outputTokens == 4)
        #expect(secondReport.data[0].totalTokens == 14)
        #expect(!cache.files.keys.contains(oldRootURL.path))
    }

    @Test
    func `claude daily report parses usage and caches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)

        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([assistant]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.count == 1)
        #expect(report.data[0].modelsUsed == ["claude-sonnet-4-20250514"])
        #expect(report.data[0].inputTokens == 200)
        #expect(report.data[0].cacheCreationTokens == 50)
        #expect(report.data[0].cacheReadTokens == 25)
        #expect(report.data[0].outputTokens == 80)
        #expect(report.data[0].totalTokens == 355)
        #expect(report.data[0].modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "claude-sonnet-4-20250514",
                costUSD: report.data[0].costUSD,
                totalTokens: 355),
        ])
        #expect((report.data[0].costUSD ?? 0) > 0)
    }

    @Test
    func `codex daily report preserves full sorted model breakdowns`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))
        let iso4 = env.isoString(for: day.addingTimeInterval(4))
        let iso5 = env.isoString(for: day.addingTimeInterval(5))
        let iso6 = env.isoString(for: day.addingTimeInterval(6))
        let iso7 = env.isoString(for: day.addingTimeInterval(7))

        let events: [[String: Any]] = [
            [
                "type": "turn_context",
                "timestamp": iso0,
                "payload": ["model": "openai/gpt-5.2-pro"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso1,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 100,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso2,
                "payload": ["model": "openai/gpt-5.3-codex"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso3,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso4,
                "payload": ["model": "openai/gpt-5.2-codex"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso5,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso6,
                "payload": ["model": "openai/gpt-5.3-codex-spark"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso7,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 0,
                            "output_tokens": 5,
                        ],
                    ],
                ],
            ],
        ]

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl(events))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].modelBreakdowns?.map(\.modelName) == [
            "gpt-5.2-pro",
            "gpt-5.3-codex",
            "gpt-5.2-codex",
            "gpt-5.3-codex-spark",
        ])
        #expect(report.data[0].modelBreakdowns?.map(\.totalTokens) == [110, 40, 30, 15])
    }
}

// swiftlint:enable type_body_length
