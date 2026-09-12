import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageLazyHistoryBenchmarkTests {
    @Test
    func `repeated cumulative events retain exact costs across scan shapes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 4)
        let timestamp = env.isoString(for: day)
        let fileCount = 12
        let snapshotsPerFile = 1000
        var files: [URL] = []
        let tokenLine = try env.jsonl([[
            "type": "event_msg", "timestamp": timestamp,
            "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 100, "cached_input_tokens": 20, "output_tokens": 10,
            ]]],
        ]])
        for index in 0..<fileCount {
            let prefix = try env.jsonl([
                ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "synthetic-history-\(index)"]],
                ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            ])
            try files.append(env.writeCodexSessionFile(
                day: day,
                filename: "history-\(index).jsonl",
                contents: prefix + String(repeating: tokenLine, count: snapshotsPerFile)))
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let initial = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(initial.summary?.totalTokens == fileCount * 110)
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let seeded = store.syncLoadCodexCache(calendar: options.calendar)
        #expect(seeded.files.values.reduce(0) { $0 + ($1.codexTokenSnapshots?.count ?? 0) } ==
            fileCount * snapshotsPerFile)
        #expect(seeded.files.values.reduce(0) { $0 + ($1.codexRows?.count ?? 0) } == fileCount)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        for (index, mode) in ["unchanged", "debounced", "one-append", "all-append"].enumerated() {
            options.refreshMinIntervalSeconds = mode == "debounced" ? 3600 : 0
            if mode == "one-append" || mode == "all-append" {
                let changed = mode == "one-append" ? Array(files.prefix(1)) : files
                for file in changed {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(tokenLine.utf8))
                }
            }
            recorder.reset()
            let started = ContinuousClock.now
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(Double(index + 1)),
                options: options)
            let elapsed = (ContinuousClock.now - started).components
            let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            let work = recorder.snapshot()
            #expect(report.summary?.totalTokens == initial.summary?.totalTokens)
            #expect(try abs(#require(report.summary?.totalCostUSD) - #require(initial.summary?.totalCostUSD)) < 1e-12)
            print(
                "[lazy-history-benchmark] mode=\(mode) files=\(fileCount) snapshots=\(fileCount * snapshotsPerFile) " +
                    "wall_ms=\(milliseconds) token_reads=\(work.tokenSnapshotRows) usage_reads=\(work.usageRows)")
        }
    }
}
