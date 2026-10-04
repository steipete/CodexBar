import CryptoKit
import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeReconciliationMemoryTests {
    @Test
    func `winner payload contains only two indexes`() {
        let priorStride = MemoryLayout<(path: String, row: CostUsageScanner.ClaudeUsageRow)>.stride
        #expect(CostUsageScanner.claudeWinnerPayloadStride == 2 * MemoryLayout<Int>.stride)
        #expect(CostUsageScanner.claudeWinnerPayloadStride * 10 < priorStride)
    }

    /// Golden bytes captured from the row-copy implementation, including both temporal projections.
    @Test(arguments: 0..<4)
    func `randomized duplicate order preserves exact output`(seed: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var generator = Generator(state: UInt64(seed))
        var cache = CostUsageClaudeRebuildTests.cache(fileCount: 64, rowsPerFile: 50, includeOverflow: true)
        let files = cache.files.sorted { $0.key < $1.key }.shuffled(using: &generator)
        cache.files = [:]
        for (path, var file) in files {
            file.claudeRows?.shuffle(using: &generator)
            cache.files[path] = file
        }
        cache.files["empty"] = .init(mtimeUnixMs: 0, size: 0, days: [:], claudeRows: [])
        let rows = CostUsageScanner.reconciledClaudeRows(cache: cache)
        CostUsageScanner.rebuildClaudeDays(cache: &cache, rows: rows)
        let report = CostUsageScanner.buildClaudeReportFromCache(
            cache: cache,
            range: CostUsageClaudeRebuildTests.range,
            now: CostUsageClaudeRebuildTests.now,
            modelsDevCacheRoot: env.cacheRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try [
            encoder.encode(rows), encoder.encode(cache.days), encoder.encode(report),
            encoder.encode(report.hourly.map(CostUsageCodexPreviousReport.HourlyEntry.init)),
            encoder.encode(report.quotaSlices.map(CostUsageCodexPreviousReport.QuotaSlice.init)),
        ]
        let digest = try SHA256.hash(data: encoder.encode(bytes)).map { String(format: "%02x", $0) }.joined()
        let expected = [
            "7c046ec860b6766bb825f1870706c75d7e50ddb23b69f11fe78738f307d66930",
            "6b0663417d6124b4d66568a6ae26efcf42ed486ac5e9466290489a2364159c1c",
            "059a88ac800275b4ac0bee8571d393a45ae32117baa67bc89c5ed7e1e63ae1a8",
            "581788d8c7ee6d142f2673f0c0dde5287a8c6cc699aee3bf2fa8a1dabf3cd3a3",
        ]
        #expect(digest == expected[seed])
        #expect(cache.days["2026-09-01"]?["fixture/overflow"] == nil)
    }

    @Test
    func `cancellation after reconciliation leaves the cache and memo intact`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = CostUsageClaudeRebuildTests.now
        _ = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: """
        {"type":"assistant","timestamp":"2026-09-30T12:00:00Z","requestId":"fixture-request",
        "message":{"id":"fixture-message","model":"claude-sonnet-4-6",
        "usage":{"input_tokens":10,"output_tokens":1}}}
        """.replacingOccurrences(of: "\n", with: "") + "\n")
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            calendar: CostUsageClaudeRebuildTests.range.calendar)
        options.refreshMinIntervalSeconds = 0
        let prior = try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude, since: now, until: now, now: now, options: options, checkCancellation: nil)
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL)
        let before = try [Data(contentsOf: cacheURL), Data(contentsOf: memoURL)]
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        options.forceRescan = true
        #expect(throws: CancellationError.self) {
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                _ = try CostUsageScanner.loadDailyReportCancellable(
                    provider: .claude,
                    since: now,
                    until: now,
                    now: now,
                    options: options,
                    checkCancellation: {
                        if recorder.snapshot().reconciliations > 0 { throw CancellationError() }
                    })
            }
        }
        #expect(recorder.snapshot().reconciliations == 1)
        #expect(try [Data(contentsOf: cacheURL), Data(contentsOf: memoURL)] == before)
        options.forceRescan = false
        let after = try CostUsageScanner.loadDailyReportCancellable(
            provider: .claude, since: now, until: now, now: now, options: options, checkCancellation: nil)
        #expect(after.data == prior.data)
        #expect(after.summary == prior.summary)
        #expect(after.hourly == prior.hourly)
        #expect(after.quotaSlices == prior.quotaSlices)
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            self.state = self.state &* 6_364_136_223_846_793_005 &+ 1
            return self.state
        }
    }
}
