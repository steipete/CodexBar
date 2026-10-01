import Darwin
import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_REBUILD_BENCHMARK"] == "1"))
struct CostUsageClaudeRebuildBenchmarkTests {
    @Test
    func `warm large cache with one appended line`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var cache = CostUsageClaudeRebuildTests.cache(fileCount: 5000, rowsPerFile: 50)
        let range = CostUsageClaudeRebuildTests.range
        let now = CostUsageClaudeRebuildTests.now
        var ids: [String: String] = [:]
        // Seed retained rows directly: only the append is parsed in this warm-cache benchmark.
        for path in Array(cache.files.keys) {
            let written = try env.writeClaudeProjectFile(relativePath: path, contents: "{}\n")
            // Match the scanner's /private/var spelling; Foundation resolves it back to /var.
            let url = URL(fileURLWithPath: written.path.hasPrefix("/var/") ? "/private" + written.path : written.path)
            let stamp = try #require(CostUsageClaudeFileStamp.read(at: url))
            let retained = cache.files.removeValue(forKey: path)
            var usage = try #require(retained)
            usage.mtimeUnixMs = stamp.mtimeUnixMs
            cache.files[url.path] = usage
            ids[url.path] = stamp.fileID
        }
        var artifact = CostUsageClaudeCache()
        artifact.usage = cache
        artifact.sourceFileIDs = ids
        let saved = try CostUsageClaudeCacheIO.save(
            provider: .claude,
            cache: artifact,
            cacheRoot: env.cacheRoot,
            calendar: range.calendar)
        try #require(saved != nil)
        let seeded = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot, calendar: range.calendar)
        try #require(seeded.usage.files.count == 5000)
        #expect(seeded.usage.files.values.reduce(0) { $0 + ($1.claudeRows?.count ?? 0) } == 250_000)
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot, calendar: range.calendar)
        options.refreshMinIntervalSeconds = 0
        func load() throws -> CostUsageDailyReport {
            try CostUsageScanner.loadClaudeDaily(
                provider: .claude, range: range, now: now, options: options, checkCancellation: nil)
        }
        let warm = CostUsageScanner.ClaudeScanWorkRecorder()
        _ = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(warm) { try load() }
        try #require(warm.snapshot().transcriptParses == 0)
        #expect(warm.snapshot().repricedRows > 100_000)
        for iteration in 0..<3 {
            try self.measure("reconcile", iteration: iteration) {
                #expect(!CostUsageScanner.reconciledClaudeRows(cache: cache).isEmpty)
            }
            try self.measure("rebuild-days-including-reconcile", iteration: iteration) {
                var copy = cache
                CostUsageScanner.rebuildClaudeDays(
                    cache: &copy,
                    rows: CostUsageScanner.reconciledClaudeRows(cache: cache))
                #expect(!copy.days.isEmpty)
            }
            try self.measure("report-including-reconcile", iteration: iteration) {
                #expect(!CostUsageScanner.buildClaudeReportFromCache(
                    cache: cache, range: range, now: now, modelsDevCacheRoot: env.cacheRoot).data.isEmpty)
            }
            let source = try URL(fileURLWithPath: #require(cache.files.keys.min()))
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd()
            let line = """
            {"type":"assistant","timestamp":"2026-09-30T12:00:00Z","requestId":"append-\(iteration)",
            "message":{"id":"append-\(iteration)","model":"claude-sonnet-4-6",
            "usage":{"input_tokens":10,"output_tokens":1}}}
            """.replacingOccurrences(of: "\n", with: "") + "\n"
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
            try self.measure("warm-append-load", iteration: iteration) {
                let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
                let report = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) { try load() }
                let work = recorder.snapshot()
                #expect(!report.data.isEmpty)
                #expect(work.repricedRows > 100_000)
                #expect(work.transcriptParses == 1)
                #expect(work.incrementalTranscriptParses == 1)
                print("[rebuild-work] reconciliations=\(work.reconciliations) repricedRows=\(work.repricedRows)")
            }
        }
    }

    private func measure(_ label: String, iteration: Int, work: () throws -> Void) throws {
        let cpu = Self.cpuSeconds
        let start = ContinuousClock.now
        try autoreleasepool { try work() }
        print("[rebuild-benchmark] phase=\(label) run=\(iteration) "
            + "cpu=\(Self.cpuSeconds - cpu) wall=\(ContinuousClock.now - start)")
    }

    private static var cpuSeconds: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
