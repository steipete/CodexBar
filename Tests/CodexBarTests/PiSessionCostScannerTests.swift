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
}
