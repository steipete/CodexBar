import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostScannerTests {
    @Test
    func `pi scanner maps assistant usage to codex and claude reports`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let codexDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let claudeDay = try env.makeLocalNoon(year: 2026, month: 4, day: 3)

        let codexEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: codexDay),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(codexDay.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 120,
                    "output": 30,
                    "cacheRead": 10,
                    "cacheWrite": 5,
                    "totalTokens": 165,
                ],
            ],
        ]
        let claudeEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: claudeDay),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "anthropic.foo.claude-sonnet-4-6-v1:0",
                "timestamp": Int(claudeDay.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 80,
                    "output": 20,
                    "cacheRead": 4,
                    "cacheWrite": 6,
                    "totalTokens": 110,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "nested/run-0/2026-04-02T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([codexEntry, claudeEntry]))

        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let codexReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: codexDay,
            until: claudeDay,
            now: claudeDay,
            options: options)
        let expectedCodexCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 135,
            cachedInputTokens: 10,
            outputTokens: 30)
        #expect(codexReport.data.count == 1)
        #expect(codexReport.data.first?.date == "2026-04-02")
        #expect(codexReport.data.first?.totalTokens == 165)
        #expect(abs((codexReport.data.first?.costUSD ?? 0) - (expectedCodexCost ?? 0)) < 0.000001)
        #expect(codexReport.data.first?.modelBreakdowns?.map(\.modelName) == ["gpt-5.4"])

        let claudeReport = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: codexDay,
            until: claudeDay,
            now: claudeDay,
            options: options)
        let expectedClaudeCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 80,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 6,
            outputTokens: 20)
        #expect(claudeReport.data.count == 1)
        #expect(claudeReport.data.first?.date == "2026-04-03")
        #expect(claudeReport.data.first?.totalTokens == 110)
        #expect(abs((claudeReport.data.first?.costUSD ?? 0) - (expectedClaudeCost ?? 0)) < 0.000001)
        #expect(claudeReport.data.first?.modelBreakdowns?.map(\.modelName) == ["claude-sonnet-4-6"])
    }

    @Test
    func `scanner merges omp sessions with pi sessions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 17)
        func session(_ id: String) -> [String: Any] {
            ["type": "session", "id": id, "timestamp": env.isoString(for: day)]
        }
        func assistant(input: Int, output: Int) -> [String: Any] {
            [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "api": "openai-codex-responses",
                    "provider": "openai-codex",
                    "model": "gpt-5.4",
                    "usage": [
                        "input": input,
                        "output": output,
                        "cacheRead": 0,
                        "cacheWrite": 0,
                        "totalTokens": input + output,
                    ],
                ],
            ]
        }

        _ = try env.writePiSessionFile(
            relativePath: "2026-07-17T10-00-00-000Z_pi.jsonl",
            contents: env.jsonl([session("pi-session"), assistant(input: 10, output: 5)]))
        let ompSessionsRoot = env.root.appendingPathComponent("omp-sessions", isDirectory: true)
        let ompSession = ompSessionsRoot.appendingPathComponent(
            "nested/2026-07-17T11-00-00-000Z_omp.jsonl",
            isDirectory: false)
        try FileManager.default.createDirectory(
            at: ompSession.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try env.jsonl([session("omp-session"), assistant(input: 20, output: 10)])
            .write(to: ompSession, atomically: true, encoding: .utf8)

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                ompSessionsRoot: ompSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 45)
        #expect(report.data.first?.inputTokens == 30)
        #expect(report.data.first?.outputTokens == 15)
    }

    @Test
    func `pi codex cache reads are billed once and use the true context size`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 4)
        let assistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 180_000,
                    "cacheRead": 60000,
                    "output": 0,
                    "totalTokens": 240_000,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "2026-04-04T10-00-00-000Z_cache-read.jsonl",
            contents: env.jsonl([assistant]))

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))
        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 240_000,
            cachedInputTokens: 60000,
            outputTokens: 0)

        #expect(report.data.count == 1)
        #expect(report.data.first?.inputTokens == 180_000)
        #expect(report.data.first?.cacheReadTokens == 60000)
        #expect(report.data.first?.totalTokens == 240_000)
        #expect(abs((report.data.first?.costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `pi scanner keeps ambiguous claude errors priced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let claudeEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-fable-5",
                "stopReason": "error",
                "errorMessage": "An unknown error occurred",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 100,
                    "output": 0,
                    "cacheRead": 20,
                    "cacheWrite": 10,
                    "totalTokens": 130,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "2026-06-09T10-00-00-000Z_refusal.jsonl",
            contents: env.jsonl([claudeEntry]))

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 130)
        let expectedCost = CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5",
            inputTokens: 100,
            cacheReadInputTokens: 20,
            cacheCreationInputTokens: 10,
            outputTokens: 0)

        #expect(abs((report.data.first?.costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `pi scanner uses model change fallback and assistant timestamp day`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let sessionStart = try env.makeLocalNoon(year: 2026, month: 4, day: 1)
        let assistantDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)

        let modelChange: [String: Any] = [
            "type": "model_change",
            "timestamp": env.isoString(for: sessionStart),
            "provider": "openai-codex",
            "modelId": "openai/gpt-5.3-codex",
        ]
        let assistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: sessionStart),
            "message": [
                "role": "assistant",
                "timestamp": Int(assistantDay.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 20,
                    "cacheRead": 2,
                    "output": 20,
                    "totalTokens": 42,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "2026-04-01T09-00-00-000Z_test.jsonl",
            contents: env.jsonl([modelChange, assistant]))

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: sessionStart,
            until: assistantDay,
            now: assistantDay,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.3-codex",
            inputTokens: 22,
            cachedInputTokens: 2,
            outputTokens: 20)
        #expect(report.data.count == 1)
        #expect(report.data.first?.date == "2026-04-02")
        #expect(report.data.first?.totalTokens == 42)
        #expect(abs((report.data.first?.costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
        #expect(report.data.first?.modelBreakdowns?.map(\.modelName) == ["gpt-5.3-codex"])
    }

    @Test
    func `pi scanner refreshes appended file without duplicating existing usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 4)
        let firstTimestamp = Int(day.timeIntervalSince1970 * 1000)
        let secondTimestamp = Int(day.addingTimeInterval(60).timeIntervalSince1970 * 1000)

        let firstAssistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": firstTimestamp,
                "usage": [
                    "input": 10,
                    "output": 5,
                    "totalTokens": 15,
                ],
            ],
        ]
        let secondAssistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": secondTimestamp,
                "usage": [
                    "input": 20,
                    "output": 10,
                    "totalTokens": 30,
                ],
            ],
        ]

        let url = try env.writePiSessionFile(
            relativePath: "2026-04-04T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([firstAssistant]))

        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let firstReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstExpectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5)
        #expect(firstReport.data.count == 1)
        #expect(firstReport.data.first?.totalTokens == 15)
        #expect(abs((firstReport.data.first?.costUSD ?? 0) - (firstExpectedCost ?? 0)) < 0.000001)

        try env.jsonl([firstAssistant, secondAssistant]).write(to: url, atomically: true, encoding: .utf8)

        let secondReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let secondExpectedCost = (firstExpectedCost ?? 0) + (CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 20,
            cachedInputTokens: 0,
            outputTokens: 10) ?? 0)
        #expect(secondReport.data.count == 1)
        #expect(secondReport.data.first?.totalTokens == 45)
        #expect(abs((secondReport.data.first?.costUSD ?? 0) - secondExpectedCost) < 0.000001)
    }

    @Test
    func `pi scanner ignores explicit unsupported provider even with fallback context`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 5)
        let modelChange: [String: Any] = [
            "type": "model_change",
            "timestamp": env.isoString(for: day),
            "provider": "openai-codex",
            "modelId": "gpt-5.4",
        ]
        let unsupportedAssistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openrouter",
                "model": "gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 99,
                    "output": 1,
                    "totalTokens": 100,
                ],
            ],
        ]
        let fallbackAssistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day.addingTimeInterval(60)),
            "message": [
                "role": "assistant",
                "timestamp": Int(day.addingTimeInterval(60).timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 10,
                    "output": 5,
                    "totalTokens": 15,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "2026-04-05T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([modelChange, unsupportedAssistant, fallbackAssistant]))

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 15)
        #expect(report.data.first?.modelBreakdowns?.map(\.modelName) == ["gpt-5.4"])
    }

    @Test
    func `pi scanner force rescan bypasses stale same size metadata cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 6)
        let assistantOne: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 10,
                    "output": 5,
                    "totalTokens": 15,
                ],
            ],
        ]
        let assistantTwo: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 20,
                    "output": 5,
                    "totalTokens": 25,
                ],
            ],
        ]

        let firstContents = try env.jsonl([assistantOne])
        let secondContents = try env.jsonl([assistantTwo])
        #expect(firstContents.utf8.count == secondContents.utf8.count)

        let url = try env.writePiSessionFile(
            relativePath: "2026-04-06T10-00-00-000Z_test.jsonl",
            contents: firstContents)
        let originalModifiedAt = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)

        let cachedOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let firstReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: cachedOptions)
        #expect(firstReport.data.first?.totalTokens == 15)

        try secondContents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: originalModifiedAt], ofItemAtPath: url.path)

        let staleReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: cachedOptions)
        #expect(staleReport.data.first?.totalTokens == 15)

        let refreshedReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                forceRescan: true))
        #expect(refreshedReport.data.first?.totalTokens == 25)
    }

    @Test
    func `pi scanner derives cost when explicit cost is absent`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 7)
        let assistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 70,
                    "cacheRead": 4,
                    "cacheWrite": 6,
                    "output": 19,
                    "totalTokens": 99,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "2026-04-07T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([assistant]))

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        let expectedCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 70,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 6,
            outputTokens: 19)
        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 99)
        #expect(abs((report.data.first?.costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `pi scanner preserves per-message threshold pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 9)
        let model = "claude-sonnet-4-5"
        let firstAssistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": model,
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 150_000,
                    "output": 0,
                    "totalTokens": 150_000,
                ],
            ],
        ]
        let secondAssistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day.addingTimeInterval(1)),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": model,
                "timestamp": Int(day.addingTimeInterval(1).timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 150_000,
                    "output": 0,
                    "totalTokens": 150_000,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "2026-05-09T10-00-00-000Z_threshold.jsonl",
            contents: env.jsonl([firstAssistant, secondAssistant]))

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))
        let expectedRequestCost = CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 150_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let aggregateCost = CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 300_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let expectedCost = expectedRequestCost * 2

        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 300_000)
        #expect(abs((report.data.first?.costUSD ?? 0) - expectedCost) < 0.000001)
        #expect(abs((report.data.first?.costUSD ?? 0) - aggregateCost) > 0.000001)
        #expect(abs((report.data.first?.modelBreakdowns?.first?.costUSD ?? 0) - expectedCost) < 0.000001)
    }

    @Test
    func `pi scanner ignores v3 cache with stale codex cached input pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let model = "gpt-5.4"
        let assistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": model,
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 180_000,
                    "cacheRead": 60000,
                    "output": 0,
                    "totalTokens": 240_000,
                ],
            ],
        ]

        let fileURL = try env.writePiSessionFile(
            relativePath: "2026-05-10T10-00-00-000Z_cache-read.jsonl",
            contents: env.jsonl([assistant]))
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mtime = try #require(attrs[.modificationDate] as? Date)
        let size = try #require((attrs[.size] as? NSNumber)?.int64Value)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 240_000,
            cachedInputTokens: 60000,
            outputTokens: 0) ?? 0
        let staleCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 180_000,
            cachedInputTokens: 60000,
            outputTokens: 0,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let stalePacked = PiPackedUsage(
            inputTokens: 180_000,
            cacheReadTokens: 60000,
            outputTokens: 0,
            totalTokens: 240_000,
            costNanos: Int64((staleCost * 1_000_000_000).rounded()),
            costSampleCount: 1,
            usageSampleCount: 1)
        let dayKey = "2026-05-10"
        let contributions = [
            UsageProvider.codex.rawValue: [
                dayKey: [
                    model: stalePacked,
                ],
            ],
        ]
        let oldFileUsage = PiSessionFileUsage(
            mtimeUnixMs: Int64(mtime.timeIntervalSince1970 * 1000),
            size: size,
            parsedBytes: size,
            lastModelContext: nil,
            contributions: contributions)
        var oldCache = PiSessionCostCache(version: 3)
        oldCache.lastScanUnixMs = Int64(day.timeIntervalSince1970 * 1000)
        oldCache.scanSinceKey = dayKey
        oldCache.scanUntilKey = dayKey
        oldCache.daysByProvider = contributions
        oldCache.files = [fileURL.path: oldFileUsage]
        let oldCacheURL = env.cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("pi-sessions-v3.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: oldCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(oldCache).write(to: oldCacheURL)

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 3600))

        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 240_000)
        #expect(abs((report.data.first?.costUSD ?? 0) - expectedCost) < 0.000001)
        #expect(abs((report.data.first?.costUSD ?? 0) - staleCost) > 0.000001)

        let newCacheURL = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        #expect(FileManager.default.fileExists(atPath: newCacheURL.path))
        let newCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        let rebuilt = newCache.daysByProvider[UsageProvider.codex.rawValue]?[dayKey]?[model]
        #expect(newCacheURL.lastPathComponent == "pi-sessions-v7.json")
        #expect(newCache.version == 7)
        #expect(rebuilt?.usageSampleCount == 1)
        #expect(rebuilt?.costSampleCount == 1)
        #expect(rebuilt?.costNanos == Int64((expectedCost * 1_000_000_000).rounded()))
    }

    @Test
    func `pi scanner ignores v4 cache with stale gpt56 cache write pricing`() throws {
        // v4 stored complete costNanos before cache-write rates existed; v7 must reprice.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        let model = "gpt-5.6-sol"
        let assistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": model,
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 70,
                    "cacheRead": 10,
                    "cacheWrite": 20,
                    "output": 5,
                    "totalTokens": 105,
                ],
            ],
        ]

        let fileURL = try env.writePiSessionFile(
            relativePath: "2026-07-10T10-00-00-000Z_cache-write.jsonl",
            contents: env.jsonl([assistant]))
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mtime = try #require(attrs[.modificationDate] as? Date)
        let size = try #require((attrs[.size] as? NSNumber)?.int64Value)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            cacheWriteInputTokens: 20,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        // Stale: writes folded into uncached input at 1× (pre-v5 behavior).
        let staleCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        #expect(abs(expectedCost - staleCost) > 0.000001)

        let stalePacked = PiPackedUsage(
            inputTokens: 70,
            cacheReadTokens: 10,
            cacheWriteTokens: 20,
            outputTokens: 5,
            totalTokens: 105,
            costNanos: Int64((staleCost * 1_000_000_000).rounded()),
            costSampleCount: 1,
            usageSampleCount: 1)
        let dayKey = "2026-07-10"
        let contributions = [
            UsageProvider.codex.rawValue: [
                dayKey: [
                    model: stalePacked,
                ],
            ],
        ]
        let oldFileUsage = PiSessionFileUsage(
            mtimeUnixMs: Int64(mtime.timeIntervalSince1970 * 1000),
            size: size,
            parsedBytes: size,
            lastModelContext: nil,
            contributions: contributions)
        var oldCache = PiSessionCostCache(version: 4)
        oldCache.lastScanUnixMs = Int64(day.timeIntervalSince1970 * 1000)
        oldCache.scanSinceKey = dayKey
        oldCache.scanUntilKey = dayKey
        oldCache.daysByProvider = contributions
        oldCache.files = [fileURL.path: oldFileUsage]
        let oldCacheURL = env.cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("pi-sessions-v4.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: oldCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(oldCache).write(to: oldCacheURL)

        let report = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 3600))

        #expect(report.data.count == 1)
        #expect(abs((report.data.first?.costUSD ?? 0) - expectedCost) < 0.000001)
        #expect(abs((report.data.first?.costUSD ?? 0) - staleCost) > 0.000001)

        let newCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        let rebuilt = newCache.daysByProvider[UsageProvider.codex.rawValue]?[dayKey]?[model]
        #expect(newCache.version == 7)
        #expect(rebuilt?.costNanos == Int64((expectedCost * 1_000_000_000).rounded()))
    }
}

extension PiSessionCostScannerTests {
    @Test
    func `scanner counts duplicate pi and omp session ids once`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 17)
        let session: [String: Any] = [
            "type": "session",
            "id": "shared-session",
            "timestamp": env.isoString(for: day),
        ]
        func assistant(id: String, input: Int, output: Int) -> [String: Any] {
            [
                "type": "message",
                "id": id,
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "gpt-5.4",
                    "usage": [
                        "input": input,
                        "output": output,
                        "totalTokens": input + output,
                    ],
                ],
            ]
        }

        let initial = try env.jsonl([session, assistant(id: "shared-turn", input: 10, output: 5)])
        let piSession = try env.writePiSessionFile(
            relativePath: "2026-07-17T10-00-00-000Z_shared.jsonl",
            contents: initial)
        let ompSessionsRoot = env.root.appendingPathComponent("omp-sessions", isDirectory: true)
        let ompSession = ompSessionsRoot.appendingPathComponent(
            "nested/2026-07-17T10-00-00-000Z_shared.jsonl",
            isDirectory: false)
        try FileManager.default.createDirectory(
            at: ompSession.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try initial.write(to: ompSession, atomically: true, encoding: .utf8)

        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            ompSessionsRoot: ompSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let first = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.first?.totalTokens == 15)

        let piHandle = try FileHandle(forWritingTo: piSession)
        try piHandle.seekToEnd()
        try piHandle.write(contentsOf: Data(env.jsonl([assistant(id: "pi-turn", input: 7, output: 3)]).utf8))
        try piHandle.close()
        let ompHandle = try FileHandle(forWritingTo: ompSession)
        try ompHandle.seekToEnd()
        try ompHandle.write(contentsOf: Data(env.jsonl([assistant(id: "omp-turn", input: 20, output: 10)]).utf8))
        try ompHandle.close()

        let second = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(second.data.first?.totalTokens == 55)
        #expect(second.data.first?.inputTokens == 37)
        #expect(second.data.first?.outputTokens == 18)

        let cache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(cache.files.values.count == 2)
        #expect(cache.files.values.allSatisfy { $0.sessionID == "shared-session" })
        #expect(cache.files.values.flatMap(\.entryUsages.keys).count == 4)
    }

    @Test
    func `pi scanner reprices unchanged files when catalog rates change`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        let model = "gpt-5.6-sol"
        func assistant(at timestamp: Date) -> [String: Any] {
            [
                "type": "message",
                "timestamp": env.isoString(for: timestamp),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": model,
                    "timestamp": Int(timestamp.timeIntervalSince1970 * 1000),
                    "usage": [
                        "input": 150_000,
                        "output": 0,
                        "totalTokens": 150_000,
                    ],
                ],
            ]
        }
        _ = try env.writePiSessionFile(
            relativePath: "2026-07-10T10-00-00-000Z_catalog-change.jsonl",
            contents: env.jsonl([
                assistant(at: day.addingTimeInterval(-1)),
                assistant(at: day),
            ]))

        let firstCatalog = try Self.modelsDevCatalog(inputCostPerMillion: 4)
        #expect(ModelsDevCache.save(catalog: firstCatalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        let firstReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        let firstPricingKey = try #require(firstCache.pricingKey)
        #expect(firstReport.data.first?.totalTokens == 300_000)
        #expect(abs((firstReport.data.first?.costUSD ?? 0) - 1.2) < 0.0000001)

        let secondCatalog = try Self.modelsDevCatalog(inputCostPerMillion: 8)
        #expect(ModelsDevCache.save(
            catalog: secondCatalog,
            fetchedAt: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot))
        #expect(PiSessionCostScanner.loadCachedDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot) == nil)

        let secondReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(secondCache.pricingKey != firstPricingKey)
        // Each 150K message stays below the 272K threshold. The 300K daily aggregate must be the
        // sum of two short-context costs, proving the pricing change triggered a full-file reparse.
        #expect(secondReport.data.first?.totalTokens == 300_000)
        #expect(abs((secondReport.data.first?.costUSD ?? 0) - 2.4) < 0.0000001)
    }

    @Test
    func `pi scanner reprices unchanged claude files when anthropic rates change`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        let model = "claude-fable-5"
        func assistant(at timestamp: Date) -> [String: Any] {
            [
                "type": "message",
                "timestamp": env.isoString(for: timestamp),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "model": model,
                    "timestamp": Int(timestamp.timeIntervalSince1970 * 1000),
                    "usage": [
                        "input": 150_000,
                        "output": 0,
                        "totalTokens": 150_000,
                    ],
                ],
            ]
        }
        _ = try env.writePiSessionFile(
            relativePath: "2026-07-10T10-00-00-000Z_anthropic-catalog-change.jsonl",
            contents: env.jsonl([
                assistant(at: day.addingTimeInterval(-1)),
                assistant(at: day),
            ]))

        let firstCatalog = try Self.anthropicModelsDevCatalog(inputCostPerMillion: 4)
        #expect(ModelsDevCache.save(catalog: firstCatalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        let firstReport = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        let firstPricingKey = try #require(firstCache.pricingKey)
        #expect(firstReport.data.first?.totalTokens == 300_000)
        #expect(abs((firstReport.data.first?.costUSD ?? 0) - 1.2) < 0.0000001)

        let secondCatalog = try Self.anthropicModelsDevCatalog(inputCostPerMillion: 8)
        #expect(ModelsDevCache.save(
            catalog: secondCatalog,
            fetchedAt: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot))
        #expect(PiSessionCostScanner.loadCachedDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot) == nil)

        let secondReport = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(secondCache.pricingKey != firstPricingKey)
        #expect(secondReport.data.first?.totalTokens == 300_000)
        #expect(abs((secondReport.data.first?.costUSD ?? 0) - 2.4) < 0.0000001)
    }

    @Test
    func `pi pricing key ignores catalog fetch time when rates are unchanged`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        let catalog = try Self.modelsDevCatalog(inputCostPerMillion: 4)
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        let assistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.6-sol",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 100, "output": 0, "totalTokens": 100],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-07-10T10-00-00-000Z_catalog-fetch-time.jsonl",
            contents: env.jsonl([assistant]))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        _ = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)

        #expect(ModelsDevCache.save(
            catalog: catalog,
            fetchedAt: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot))
        _ = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)

        #expect(secondCache.pricingKey == firstCache.pricingKey)
        #expect(secondCache.lastScanUnixMs == firstCache.lastScanUnixMs)
    }

    @Test
    func `pi pricing key ignores unrelated providers and non pricing context metadata`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        let firstCatalog = try Self.modelsDevCatalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "limit": { "context": 1000000 },
                "cost": { "input": 4, "output": 30 }
              }
            }
          },
          "google": {
            "id": "google",
            "models": {
              "gemini-test": {
                "id": "gemini-test",
                "cost": { "input": 1, "output": 2 }
              }
            }
          }
        }
        """)
        #expect(ModelsDevCache.save(catalog: firstCatalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        let assistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.6-sol",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 100, "output": 0, "totalTokens": 100],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-07-10T10-00-00-000Z_catalog-metadata.jsonl",
            contents: env.jsonl([assistant]))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        _ = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)

        let metadataOnlyChange = try Self.modelsDevCatalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "limit": { "context": 2000000 },
                "cost": { "input": 4, "output": 30 }
              }
            }
          },
          "google": {
            "id": "google",
            "models": {
              "gemini-test": {
                "id": "gemini-test",
                "cost": { "input": 99, "output": 199 }
              }
            }
          }
        }
        """)
        #expect(ModelsDevCache.save(
            catalog: metadataOnlyChange,
            fetchedAt: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot))
        _ = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondCache = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)

        #expect(secondCache.pricingKey == firstCache.pricingKey)
        #expect(secondCache.lastScanUnixMs == firstCache.lastScanUnixMs)
    }

    @Test
    func `pi scanner reparses unchanged cached file when scan window expands`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let oldAssistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: oldDay),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": Int(oldDay.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 10,
                    "output": 5,
                    "totalTokens": 15,
                ],
            ],
        ]
        let newAssistant: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: newDay),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": Int(newDay.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 20,
                    "output": 10,
                    "totalTokens": 30,
                ],
            ],
        ]

        _ = try env.writePiSessionFile(
            relativePath: "2026-04-08T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([oldAssistant, newAssistant]))

        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        let narrowReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: newDay,
            until: newDay,
            now: newDay,
            options: options)
        #expect(narrowReport.data.map(\.date) == ["2026-04-08"])
        #expect(narrowReport.data.first?.totalTokens == 30)

        let expandedReport = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: oldDay,
            until: newDay,
            now: newDay.addingTimeInterval(1),
            options: options)
        #expect(expandedReport.data.map(\.date) == ["2026-04-02", "2026-04-08"])
        #expect(expandedReport.summary?.totalTokens == 45)
    }

    private static func modelsDevCatalog(inputCostPerMillion: Double) throws -> ModelsDevCatalog {
        let json = """
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": {
                  "input": \(inputCostPerMillion),
                  "output": 30,
                  "cache_read": 0.5,
                  "cache_write": 6.25
                }
              }
            }
          }
        }
        """
        return try self.modelsDevCatalog(json)
    }

    private static func anthropicModelsDevCatalog(inputCostPerMillion: Double) throws -> ModelsDevCatalog {
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-fable-5": {
                "id": "claude-fable-5",
                "cost": {
                  "input": \(inputCostPerMillion),
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75
                }
              }
            }
          }
        }
        """
        return try self.modelsDevCatalog(json)
    }

    private static func modelsDevCatalog(_ json: String) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }
}
