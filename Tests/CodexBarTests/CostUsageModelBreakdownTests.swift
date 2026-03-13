import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageModelBreakdownTests {
    @Test
    func codexScannerKeepsAllModelBreakdownsWithTokenTotals() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let models: [(raw: String, input: Int, cached: Int, output: Int)] = [
            ("openai/gpt-5.2-codex", 80, 20, 10),
            ("openai/gpt-5.2-mini", 50, 0, 5),
            ("openai/o4-mini", 30, 0, 3),
            ("openai/o3", 20, 0, 2),
            ("openai/gpt-4.1", 10, 0, 1),
        ]

        var events: [[String: Any]] = []
        for (index, model) in models.enumerated() {
            let turnTimestamp = env.isoString(for: day.addingTimeInterval(TimeInterval(index * 2)))
            let tokenTimestamp = env.isoString(for: day.addingTimeInterval(TimeInterval((index * 2) + 1)))
            events.append([
                "type": "turn_context",
                "timestamp": turnTimestamp,
                "payload": [
                    "model": model.raw,
                ],
            ])
            events.append([
                "type": "event_msg",
                "timestamp": tokenTimestamp,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": model.input,
                            "cached_input_tokens": model.cached,
                            "output_tokens": model.output,
                        ],
                        "model": model.raw,
                    ],
                ],
            ])
        }

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "breakdowns.jsonl",
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

        let breakdown = try #require(report.data.first?.modelBreakdowns)
        #expect(breakdown.count == models.count)
        #expect(breakdown.allSatisfy { $0.totalTokens != nil })
        #expect(breakdown.map(\.totalTokens).compactMap(\.self).sorted() == [11, 22, 33, 55, 90])
    }
}
