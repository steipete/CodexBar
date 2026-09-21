import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostNumericTests {
    @Test(arguments: [false, true])
    func `invalid numeric fields keep history incomplete while valid fractions retain rounding`(asString: Bool) throws {
        for (input, expected) in [(Double(Int.max), nil), (Double.greatestFiniteMagnitude, nil), (12.6, Optional(13))] {
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
            let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: .init(
                    piSessionsRoot: env.piSessionsRoot,
                    cacheRoot: env.cacheRoot,
                    refreshMinIntervalSeconds: 0),
                checkCancellation: nil)
            if let expected {
                #expect(result.isComplete)
                #expect(result.report.data.first?.inputTokens == expected)
                #expect(result.report.data.first?.outputTokens == 2)
                #expect(result.report.summary?.totalTokens == expected + 2)
            } else {
                #expect(!result.isComplete)
                #expect(result.report.data.isEmpty)
                #expect(result.lastScanAt == nil)
            }
        }
    }
}
