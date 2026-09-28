import Darwin
import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_REFRESH_BENCHMARK"] == "1"))
struct CostUsageClaudeRefreshBenchmarkTests {
    @Test
    func `large history refresh CPU writes and retained memory`() throws {
        let fixture = try autoreleasepool {
            try CostUsageClaudeWriteAmplificationTests.Fixture(rowCount: 24000, identityLength: 48)
        }
        defer { fixture.env.cleanup() }
        let context = CostUsageReportContext.spendDashboard
        let initial = try autoreleasepool { try fixture.load(context: context) }
        let url = fixture.cacheURL(context: context)
        try print("[refresh-benchmark] rows=24000 artifactBytes=\(Data(contentsOf: url).count)")

        func measure(_ name: String, count: Int, work: (Int) throws -> Void) throws {
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            let cpuBefore = Self.cpuSeconds
            let started = ContinuousClock.now
            var written: Int64 = 0
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                for cycle in 0..<count {
                    try autoreleasepool {
                        let before = try fixture.stamps(context: context)
                        try work(cycle)
                        let after = try fixture.stamps(context: context)
                        written += zip(before, after).reduce(Int64(0)) { $0 + ($1.0 == $1.1 ? 0 : $1.1.size) }
                    }
                    if cycle == 0 || (cycle + 1).isMultiple(of: 100) {
                        print("[refresh-memory] phase=\(name) cycle=\(cycle + 1) rssBytes=\(Self.residentBytes)")
                    }
                }
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let metrics = recorder.snapshot()
            print("[refresh-benchmark] phase=\(name) count=\(count) cpuSeconds=\(Self.cpuSeconds - cpuBefore) "
                + "wall=\(ContinuousClock.now - started) payloadBytesWritten=\(written) "
                + "peakRSSBytes=\(usage.ru_maxrss) rssBytes=\(Self.residentBytes) "
                + "decodes=\(metrics.cacheDecodes) encodes=\(metrics.cacheEncodes)")
        }

        try measure("cold", count: 3) { _ in
            CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
            #expect(CostUsageClaudeCacheIO.load(
                provider: .claude, cacheRoot: fixture.env.cacheRoot, reportContext: context).usage.files.count == 1)
        }
        try measure("identical-save", count: 8) { _ in
            let cache = CostUsageClaudeCacheIO.load(
                provider: .claude, cacheRoot: fixture.env.cacheRoot, reportContext: context)
            _ = try CostUsageClaudeCacheIO.save(
                provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot, reportContext: context)
        }
        let source = fixture.env.claudeProjectsRoot.appendingPathComponent("session.jsonl")
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try measure("append", count: 12) { cycle in
            try handle.write(contentsOf: Data(fixture.event(index: 24000 + cycle).utf8))
            let report = try fixture.load(context: context, cycle: cycle + 1)
            #expect(report.summary?.totalInputTokens == (initial.summary?.totalInputTokens ?? 0) + (cycle + 1) * 10)
        }
        try measure("idle", count: 1000) { cycle in
            let report = try fixture.load(context: context, cycle: cycle + 20)
            #expect(report.summary?.totalInputTokens == (initial.summary?.totalInputTokens ?? 0) + 120)
        }
    }

    private static var cpuSeconds: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static var residentBytes: UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
