import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostNumericTests {
    @Test(arguments: [false, true])
    func `numeric and string usage counts reject overflow while retaining rounding`(asString: Bool) throws {
        for (input, expected) in [(Double(Int.max), 0), (Double.greatestFiniteMagnitude, 0), (12.6, 13)] {
            let env = try CostUsageTestEnvironment()
            defer { env.cleanup() }
            let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
            let value: Any = asString ? String(input) : input
            let entry: [String: Any] = [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "gpt-5.4",
                    "usage": ["input": value, "output": 2],
                ],
            ]
            _ = try env.writePiSessionFile(relativePath: "bounds.jsonl", contents: env.jsonl([entry]))
            let report = PiSessionCostScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: .init(
                    piSessionsRoot: env.piSessionsRoot,
                    cacheRoot: env.cacheRoot,
                    refreshMinIntervalSeconds: 0))
            #expect(report.data.first?.inputTokens == (expected == 0 ? nil : expected))
            #expect(report.data.first?.outputTokens == 2)
            #expect(report.summary?.totalTokens == expected + 2)
        }
    }
}
