import Darwin
import Foundation
import Testing
@testable import CodexBarCore

@Suite(
    .serialized,
    CostUsageClaudeCacheFixtures(),
    .enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_ACTIVE_HISTORY_BENCHMARK"] == "1"))
struct CostUsageActiveHistoryBenchmarkTests {
    @Test
    func `active report refresh`() throws {
        let fixture = try CostUsageClaudeWriteAmplificationTests.Fixture(rowCount: 12000, identityLength: 48)
        defer { fixture.env.cleanup() }
        let row = Data(("{\"type\":\"user\",\"padding\":\"" + String(repeating: "x", count: 16384) + "\"}\n").utf8)
        let url = fixture.env.claudeProjectsRoot.appendingPathComponent("session.jsonl")
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.seekToEnd()
        for _ in 0..<4096 {
            try writer.write(contentsOf: row)
        }
        // Clone the synthetic tool payload on APFS; each archive has its own inode and distinct usage.
        // 53 x 64 MiB exercises the directory and transcript working set of a multi-GB history.
        let template = fixture.env.root.appendingPathComponent("padding")
        try Data().write(to: template)
        let padding = try FileHandle(forWritingTo: template)
        for _ in 0..<4096 {
            try padding.write(contentsOf: row)
        }
        try padding.close()
        for index in 0..<52 {
            let archive = fixture.env.claudeProjectsRoot.appendingPathComponent("retired-\(index).jsonl")
            try FileManager.default.copyItem(at: template, to: archive)
            let handle = try FileHandle(forWritingTo: archive)
            try handle.seekToEnd()
            for event in 0..<100 {
                try handle.write(contentsOf: Data(fixture.event(index: 13000 + index * 100 + event).utf8))
            }
            try handle.close()
        }
        _ = try fixture.load(context: .regular, includeBreakdowns: true)
        var billed = 0
        for phase in ["idle", "tool", "usage"] {
            var cpu = 0.0, wall = Duration.zero
            var diskRead: UInt64 = 0, diskWrite: UInt64 = 0
            let counts = ByteCounts()
            for cycle in 1...5 {
                if phase == "tool" { try writer.write(contentsOf: row) }
                if phase == "usage" {
                    try writer.write(contentsOf: Data(fixture.event(index: 12000 + billed).utf8))
                    billed += 1
                }
                let cpuStart = Self.cpuSeconds
                let before = Self.usage()
                let start = ContinuousClock.now
                let reader: @Sendable (URL, Data.ReadingOptions) -> Data? = { url, options in
                    let data = try? Data(contentsOf: url, options: options)
                    counts.add(read: data?.count ?? 0)
                    return data
                }
                let observe: @Sendable (Int) -> Void = { counts.add(write: $0) }
                let daily = try autoreleasepool {
                    try CostUsageClaudeCacheIO.$readForTesting.withValue(reader) {
                        try CostUsageClaudeArtifactWriter.$observeWrittenBytesForTesting.withValue(observe) {
                            try fixture.load(context: .regular, cycle: cycle, includeBreakdowns: true)
                        }
                    }
                }
                wall += start.duration(to: .now)
                let after = Self.usage()
                cpu += Self.cpuSeconds - cpuStart
                diskRead += after.ri_diskio_bytesread - before.ri_diskio_bytesread
                diskWrite += after.ri_diskio_byteswritten - before.ri_diskio_byteswritten
                #expect(daily.summary?.totalInputTokens == (17200 + billed) * 10)
            }
            // Baseline totals for these five scans on a26ca57. Gate deterministic artifact bytes only.
            if phase == "usage", ProcessInfo.processInfo.environment["CODEXBAR_ENFORCE_ACTIVE_HISTORY_BUDGET"] == "1" {
                #expect(counts.read <= 2_490_055)
                #expect(counts.write <= 2_415_638)
            }
            print("[active-history] phase=\(phase) scans=5 cpu=\(cpu) wall=\(wall) " +
                "cacheRead=\(counts.read) cacheWrite=\(counts.write) diskRead=\(diskRead) diskWrite=\(diskWrite) " +
                "footprint=\(Self.usage().ri_phys_footprint) " +
                "peakFootprint=\(Self.usage().ri_lifetime_max_phys_footprint)")
        }
    }

    @Test
    func `one changed Codex day in a year of retained aggregates`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 32, rowsPerFile: 64)
        defer { fixture.remove() }
        var seed = fixture.canonical
        for offset in 1...365 {
            let date = try #require(fixture.calendar.date(byAdding: .day, value: -offset, to: fixture.now))
            let day = CostUsageScanner.CostUsageDayRange.dayKey(from: date, calendar: fixture.calendar)
            for model in 0..<4 {
                seed.days[day, default: [:]]["synthetic-\(model)"] = [100, 10, 25]
            }
        }
        try #require(!fixture.save(seed).catchUpRequired)
        let metrics = await fixture.store.persistenceWriteMetricsForTesting()
        let start = ContinuousClock.now
        let cpuStart = Self.cpuSeconds
        let before = Self.usage()
        for cycle in 1...5 {
            let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { loaded.release() }
            var cache = loaded.cache
            cache.days[ReadWorkFixture.day, default: [:]]["synthetic-active"] = [100 * cycle, 10, 25]
            #expect(!fixture.save(cache, load: loaded).catchUpRequired)
        }
        let cpu = Self.cpuSeconds - cpuStart
        let after = Self.usage()
        let wall = start.duration(to: .now)
        let endMetrics = await fixture.store.persistenceWriteMetricsForTesting()
        let restored = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(restored.days.count == seed.days.count)
        #expect(restored.days[ReadWorkFixture.day]?["synthetic-active"] == [500, 10, 25])
        print("[active-history] phase=codex-store scans=5 cpu=\(cpu) wall=\(wall) " +
            "changedRows=\(endMetrics.rows - metrics.rows) dirtyPages=\(endMetrics.pages - metrics.pages) " +
            "diskRead=\(after.ri_diskio_bytesread - before.ri_diskio_bytesread) " +
            "diskWrite=\(after.ri_diskio_byteswritten - before.ri_diskio_byteswritten) " +
            "footprint=\(after.ri_phys_footprint) peakFootprint=\(after.ri_lifetime_max_phys_footprint)")
    }

    private static var cpuSeconds: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func usage() -> rusage_info_v4 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        precondition(result == 0)
        return info
    }

    private final class ByteCounts: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var read = 0
        private(set) var write = 0
        func add(read: Int = 0, write: Int = 0) {
            self.lock.withLock {
                self.read += read
                self.write += write
            }
        }
    }
}
