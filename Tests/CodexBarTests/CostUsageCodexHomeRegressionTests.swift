import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexHomeRegressionTests {
    @Test
    func `scanning another home preserves established coverage`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let homeA = env.codexHomeRoot
        let homeB = env.root.appendingPathComponent("home-b")
        for (home, tokens) in [(homeA, 303), (homeB, 33)] {
            let directory = home.appendingPathComponent("sessions/2026/04/08")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let content = try env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: day),
                    "payload": ["model": "gpt-5.4"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                    "payload": ["type": "token_count", "info": [
                        "model": "gpt-5.4",
                        "last_token_usage": ["input_tokens": tokens, "cached_input_tokens": 0, "output_tokens": 0],
                    ]],
                ],
            ])
            try content.write(to: directory.appendingPathComponent("fixture.jsonl"), atomically: true, encoding: .utf8)
        }
        var options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func scan(_ home: URL) async throws -> CostUsageTokenSnapshot {
            try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                environment: [:],
                now: day,
                codexHomePath: home.path,
                historyDays: 1,
                allowPricingRefresh: false,
                includePiSessions: false,
                bypassScannerDebounce: true,
                scannerOptions: options)
        }
        var established = try await scan(homeA)
        for _ in 0..<3 where !established.historyCoverageIsEstablished {
            established = try await scan(homeA)
        }
        try #require(established.historyCoverageIsEstablished)
        #expect(established.sessionTokens == 303)
        _ = try await scan(homeB)
        let repeated = try await scan(homeA)
        print(
            "synthetic A before B: coverage=\(established.historyCoverageIsEstablished)" +
                " tokens=\(established.sessionTokens ?? -1)")
        print(
            "synthetic A after B: coverage=\(repeated.historyCoverageIsEstablished)" +
                " tokens=\(repeated.sessionTokens ?? -1)")
        #expect(repeated.historyCoverageIsEstablished)
        #expect(repeated.sessionTokens == established.sessionTokens)
    }
}
