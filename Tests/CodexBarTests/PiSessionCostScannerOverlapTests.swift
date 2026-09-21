import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostScannerOverlapTests {
    @Test
    func `scanner deduplicates session files from overlapping roots`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 18)
        let sharedRoot = env.root.appendingPathComponent("shared-sessions", isDirectory: true)
        let nestedRoot = sharedRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)

        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "usage": ["input": 7, "output": 0, "totalTokens": 7],
            ],
        ]
        let sessionURL = nestedRoot.appendingPathComponent(
            "2026-07-18T10-00-00-000Z_shared.jsonl",
            isDirectory: false)
        try env.jsonl([entry]).write(to: sessionURL, atomically: true, encoding: .utf8)

        let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: sharedRoot,
                ompSessionsRoot: nestedRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0),
            checkCancellation: nil)

        #expect(result.report.data.first?.totalTokens == 7)
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).files.count == 1)
    }
}
