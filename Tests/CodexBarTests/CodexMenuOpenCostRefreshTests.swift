import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexMenuOpenCostRefreshTests {
    @Test
    func `unchanged menu refresh reads summaries while changed logs still scan exactly`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 28)
        let sessionURL = try env.writeCodexSessionFile(
            day: day,
            filename: "menu-refresh.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: day),
                    "payload": ["id": "menu-refresh-session"],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: day),
                    "payload": ["model": "openai/gpt-5.4"],
                ],
                Self.tokenCount(env: env, at: day.addingTimeInterval(1), last: 100, total: 100),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(cold.summary?.totalTokens == 100)

        let recorder = CostUsageStoreReadWorkRecorder(
            databaseURL: CostUsageStore(cacheRoot: env.cacheRoot).databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        options.reuseCodexReportWhenSourcesAreUnchanged = true

        let unchanged = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(unchanged.data == cold.data)
        #expect(unchanged.summary == cold.summary)
        Self.expectSummaryOnly(recorder.snapshot())

        let handle = try FileHandle(forWritingTo: sessionURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            Self.tokenCount(env: env, at: day.addingTimeInterval(3), last: 20, total: 120),
        ]).utf8))
        try handle.synchronize()

        recorder.reset()
        let changed = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: options)
        #expect(changed.summary?.totalTokens == 120)
        let changedWork = recorder.snapshot()
        // A changed source takes one full snapshot for the scan and a second immediately before
        // persistence. The save-side read is intentional: another CodexBar process or the CLI may
        // have committed newer cache state after the scan began, so it must not be overwritten.
        #expect(changedWork.fullSnapshotReads == 2)
        #expect(changedWork.tokenSnapshotRows > 0)
        #expect(changedWork.usageRows > 0)

        recorder.reset()
        let settled = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(5),
            options: options)
        #expect(settled.data == changed.data)
        #expect(settled.summary == changed.summary)
        Self.expectSummaryOnly(recorder.snapshot())
    }

    private static func tokenCount(
        env: CostUsageTestEnvironment,
        at date: Date,
        last: Int,
        total: Int) -> [String: Any]
    {
        [
            "type": "event_msg",
            "timestamp": env.isoString(for: date),
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": last,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                    "total_token_usage": [
                        "input_tokens": total,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                ],
            ],
        ]
    }

    private static func expectSummaryOnly(_ work: CostUsageStoreReadWorkMetrics) {
        #expect(work.fullSnapshotReads == 0)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.usageRows == 0)
        #expect(work.usagePayloadBytes == 0)
        #expect(work.accumulatorRows == 0)
        #expect(work.readViewConversions == 1)
    }
}
