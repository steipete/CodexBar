import Foundation
import Testing
@testable import CodexBarCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_PERSISTENCE_BENCHMARK"] == "1"))
struct CostUsageClaudePersistenceBenchmarkTests {
    @Test
    func `synthetic two hundred thousand row saves`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var cache = CostUsageClaudeCache()
        cache.usage.version = 4
        cache.usage.timeZoneIdentifier = Calendar.current.timeZone.identifier
        cache.usage.lastScanUnixMs = 1_780_000_000_000
        for file in 0..<1000 {
            let path = "/synthetic/project/session-\(file).jsonl"
            let rows = (0..<200).map { index in
                CostUsageScanner.ClaudeUsageRow(
                    dayKey: "2026-07-01",
                    model: "synthetic-model",
                    sessionId: "session-\(file)",
                    messageId: "message-\(file)-\(index)",
                    requestId: "request-\(file)-\(index)",
                    timestampUnixMs: 1_780_000_000_000 + Int64(index),
                    isSidechain: false,
                    pathRole: .parent,
                    input: 100,
                    cacheRead: 20,
                    cacheCreate: 10,
                    cacheCreate1h: 0,
                    output: 50,
                    costNanos: 105_000,
                    costPriced: true)
            }
            cache.usage.files[path] = CostUsageFileUsage(
                mtimeUnixMs: 1_780_000_000_000, size: 100_000, days: [:], claudeRows: rows)
            cache.sourceFileIDs[path] = "synthetic:\(file)"
        }
        let url = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)
        _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
        for phase in ["unchanged-warm", "unchanged-evicted", "changed"] {
            var times: [Double] = []
            var cpuTimes: [Double] = []
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                for _ in 0..<3 {
                    if phase == "unchanged-evicted" { CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url) }
                    if phase == "changed" {
                        cache.usage.lastScanUnixMs += 1
                        for file in 0..<3 {
                            let path = "/synthetic/project/session-\(file).jsonl"
                            cache.usage.files[path]?.mtimeUnixMs += 1
                            let previous = cache.usage.files[path]?.claudeRows?[0].isIncomplete
                            cache.usage.files[path]?.claudeRows?[0].isIncomplete = previous != true
                        }
                    }
                    try autoreleasepool {
                        var before = rusage()
                        getrusage(RUSAGE_SELF, &before)
                        let start = ContinuousClock.now
                        _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: root)
                        let duration = start.duration(to: .now).components
                        times.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                        var after = rusage()
                        getrusage(RUSAGE_SELF, &after)
                        cpuTimes.append(Double(after.ru_utime.tv_sec - before.ru_utime.tv_sec
                                + after.ru_stime.tv_sec - before.ru_stime.tv_sec)
                            + Double(after.ru_utime.tv_usec - before.ru_utime.tv_usec
                                + after.ru_stime.tv_usec - before.ru_stime.tv_usec) / 1e6)
                    }
                }
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let bytes = try #require(CostUsageClaudeFileStamp.read(at: url)).size
            print("[persistence-benchmark] rows=200000 bytes=\(bytes) phase=\(phase) " +
                "seconds=\(times) median=\(times.sorted()[1]) encodes=\(recorder.snapshot().cacheEncodes) " +
                "fragments=\(recorder.snapshot().fragmentEncodes) fallbacks=\(recorder.snapshot().fragmentFallbacks) " +
                "cpuSeconds=\(cpuTimes) medianCPU=\(cpuTimes.sorted()[1]) peakRSSBytes=\(usage.ru_maxrss)")
        }
    }
}
