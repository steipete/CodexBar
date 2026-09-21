import Foundation
import Testing
@testable import CodexBarCore

extension PiSessionCostScannerTests {
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

        let appendHandle = try FileHandle(forWritingTo: url)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data(env.jsonl([secondAssistant]).utf8))
        try appendHandle.close()

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
}
