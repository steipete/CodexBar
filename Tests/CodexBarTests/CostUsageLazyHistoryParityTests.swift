import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageLazyHistoryParityTests {
    @Test(arguments: [0.0, 3600.0])
    func `unchanged and debounced scans preserve exact request costs and reasoning`(_ debounce: TimeInterval) throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 9, day: 4)
        let timestamp = environment.isoString(for: day)
        var entries: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "synthetic-lazy-history"]],
        ]
        for index in 1...2 {
            entries.append([
                "type": "event_msg", "timestamp": timestamp,
                "payload": ["type": "task_started", "turn_id": "synthetic-turn-\(index)"],
            ])
            entries.append([
                "type": "turn_context", "timestamp": timestamp,
                "payload": ["model": "gpt-5.4", "turn_id": "synthetic-turn-\(index)"],
            ])
            entries.append([
                "type": "event_msg", "timestamp": timestamp,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 200_000, "cached_input_tokens": 0,
                            "output_tokens": 100, "reasoning_output_tokens": 50,
                        ],
                        "total_token_usage": [
                            "input_tokens": 200_000 * index, "cached_input_tokens": 0,
                            "output_tokens": 100 * index, "reasoning_output_tokens": 50 * index,
                        ],
                    ],
                ],
            ])
        }
        _ = try environment.writeCodexSessionFile(
            day: day, filename: "exact-requests.jsonl", contents: environment.jsonl(entries))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            cacheRoot: environment.cacheRoot,
            codexTraceDatabaseURL: environment.root.appendingPathComponent("missing-trace.sqlite"))
        let initial = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day, options: options)
        #expect(initial.summary?.totalTokens == 400_200)
        #expect(initial.data.first?.reasoningTokens == 100)
        #expect(try abs(#require(initial.summary?.totalCostUSD) - 1.003) < 1e-9)

        options.refreshMinIntervalSeconds = debounce
        let cached = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(1), options: options)
        #expect(cached.data == initial.data)
        #expect(cached.summary == initial.summary)
    }
}
