import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PiSessionCostScopeTests {
    @Test
    func `cached pi report rejects a changed root scope`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 12)
        let firstRoot = env.root.appendingPathComponent("pi-first", isDirectory: true)
        let secondRoot = env.root.appendingPathComponent("pi-second", isDirectory: true)
        try [firstRoot, secondRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 3, "output": 2, "totalTokens": 5],
            ],
        ]
        try env.jsonl([entry]).write(
            to: firstRoot.appendingPathComponent("2026-04-12T10-00-00-000Z_scope.jsonl"),
            atomically: true,
            encoding: .utf8)

        let firstOptions = PiSessionCostScanner.Options(
            piSessionsRoot: firstRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        _ = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: firstOptions)

        let secondOptions = PiSessionCostScanner.Options(
            piSessionsRoot: secondRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        let cached = PiSessionCostScanner.loadCachedDailyReportResult(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot,
            calendar: secondOptions.calendar,
            options: secondOptions)
        #expect(cached == nil)
    }
}
