import Darwin
import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageGrowingRolloutPerformanceTests {
    @Test
    func `large growing rollout completes frozen generations within bounded passes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let file = try env.seedCodexSessionFile(
            day: day,
            filename: "large-rollout.jsonl",
            contents: """
            {"type":"session_meta","timestamp":"\(timestamp)","payload":{"session_id":"synthetic-large-rollout"}}
            {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-5.2-codex"}}

            """)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let padding = Data(("{\"type\":\"response_item\",\"payload\":{\"text\":\""
                + String(repeating: "x", count: 65536) + "\"}}\n").utf8)
        func appendTurn(_ turn: Int) throws {
            try handle.write(contentsOf: padding)
            let line = #"{"type":"event_msg","timestamp":"\#(timestamp)","#
                + #""payload":{"type":"token_count","info":{"total_token_usage":{"#
                + #""input_tokens":\#(turn * 100),"cached_input_tokens":0,"output_tokens":\#(turn * 10)}}}}"# + "\n"
            try handle.write(contentsOf: Data(line.utf8))
        }
        for turn in 1...4096 {
            try appendTurn(turn)
        }
        let originalSize = CostUsageScanner.codexFileMetadata(fileURL: file).size
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 32 * 1024 * 1024,
            maxCodexScanBytesPerRefresh: 32 * 1024 * 1024)
        options.refreshMinIntervalSeconds = 0
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        var before = rusage()
        #expect(getrusage(RUSAGE_SELF, &before) == 0)
        let started = ContinuousClock.now
        var passes = 0
        var appended = 0
        var offsets: [Int64] = []
        var report: CostUsageDailyReport?
        var cache = CostUsageCache()
        for pass in 0..<16 {
            report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(Double(pass)),
                options: options)
            passes += 1
            cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            let usage = try #require(cache.files.values.first)
            offsets.append(usage.parsedBytes ?? 0)
            #expect(usage.codexScanTargetSize == originalSize)
            if usage.codexScanComplete == true { break }
            appended += 1
            try appendTurn(4096 + appended)
        }
        #expect(passes > 1 && passes < 16)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
        #expect(offsets.last == originalSize)
        #expect(cache.codexScanCatchUpPending == false)
        #expect(report?.summary?.totalTokens == 4096 * 110)
        let tail = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(30), options: options)
        #expect(tail.summary?.totalTokens == (4096 + appended) * 110)
        cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(cache.codexScanCatchUpPending == false)
        #expect(cache.files.values.first?.parsedBytes == CostUsageScanner.codexFileMetadata(fileURL: file).size)
        let attempts = recorder.snapshot().codexFileScanAttempts
        for refresh in 0..<3 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(Double(60 + refresh)),
                options: options)
        }
        var after = rusage()
        #expect(getrusage(RUSAGE_SELF, &after) == 0)
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        let cpu = seconds(after.ru_utime) + seconds(after.ru_stime)
            - seconds(before.ru_utime) - seconds(before.ru_stime)
        print("[growing-rollout] bytes=\(originalSize) prefixPasses=\(passes) tailPasses=1 appendedTurns=\(appended)")
        print("[growing-rollout] offsets=\(offsets) finalTokens=\(tail.summary?.totalTokens ?? 0)")
        print(
            "[growing-rollout] wall=\(ContinuousClock.now - started) cpuSeconds=\(cpu) peakRSSBytes=\(after.ru_maxrss)")
        print(
            "[growing-rollout] scanAttempts=\(attempts) "
                + "afterThreeUnchangedRefreshes=\(recorder.snapshot().codexFileScanAttempts)")
    }
}
