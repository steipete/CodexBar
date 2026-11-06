import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeWindowReuseTests {
    private typealias Fixture = CostUsageClaudeReportContextTests.Fixture

    @Test(arguments: [CostUsageReportContext.regular, .spendDashboard])
    func `midnight reuses complete files inside or outside both windows`(context: CostUsageReportContext) throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        _ = try fixture.write(path: "recent.jsonl", day: fixture.day(-2), id: "recent", input: 10)
        _ = try fixture.write(path: "old.jsonl", day: fixture.day(-120), id: "old", input: 20)
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "empty.jsonl", contents: "{}\n")
        let original = try fixture.load(context: context, days: 30).0
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: CostUsageClaudeCacheIO.cacheFileURL(
            provider: .claude, cacheRoot: fixture.env.cacheRoot, reportContext: context))
        let (next, work) = try fixture.load(context: context, days: 30, until: fixture.day(1), cold: true)
        #expect(next.data == original.data)
        #expect(work.transcriptParses == 0)
        try fixture.expectColdOracle(next, days: 30, until: fixture.day(1))
    }

    @Test
    func `rollover reparses boundary duplicates and newly included future events`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let contents = try fixture.event(day: fixture.day(-2), id: "duplicate", input: 10)
            + fixture.event(day: fixture.day(-30), id: "duplicate", input: 20)
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "boundary.jsonl", contents: contents)
        _ = try fixture.write(path: "future.jsonl", day: fixture.day(2), id: "future", input: 30)
        _ = try fixture.write(path: "stable.jsonl", day: fixture.day(-1), id: "stable", input: 5)
        #expect(try fixture.load(context: .regular, days: 30).0.summary?.totalInputTokens == 5)
        let (next, work) = try fixture.load(context: .regular, days: 30, until: fixture.day(1), cold: true)
        #expect(next.summary?.totalInputTokens == 15)
        #expect(work.transcriptParses == 2)
        try fixture.expectColdOracle(next, days: 30, until: fixture.day(1))
        let (later, laterWork) = try fixture.load(context: .regular, days: 30, until: fixture.day(2), cold: true)
        #expect(later.summary?.totalInputTokens == 45)
        #expect(laterWork.transcriptParses == 1)
        try fixture.expectColdOracle(later, days: 30, until: fixture.day(2))
    }

    @Test
    func `append coverage includes filtered days and replacement discards prior coverage`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let file = try fixture.write(path: "changing.jsonl", day: fixture.day(-2), id: "recent", input: 10)
        _ = try fixture.load(context: .regular, days: 30)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(fixture.event(day: fixture.day(3), id: "future", input: 20).utf8))
        try handle.close()
        let (_, appended) = try fixture.load(context: .regular, days: 30)
        #expect(appended.incrementalTranscriptParses == 1)
        let (next, work) = try fixture.load(context: .regular, days: 30, until: fixture.day(1), cold: true)
        #expect(next.summary?.totalInputTokens == 10)
        #expect(work.transcriptParses == 1)
        try fixture.expectColdOracle(next, days: 30, until: fixture.day(1))
        let (later, _) = try fixture.load(context: .regular, days: 30, until: fixture.day(3), cold: true)
        #expect(later.summary?.totalInputTokens == 30)
        try fixture.expectColdOracle(later, days: 30, until: fixture.day(3))
        try Data(fixture.event(day: fixture.day(-2), id: "replacement", input: 7).utf8)
            .write(to: file, options: .atomic)
        let (replaced, replacedWork) = try fixture.load(context: .regular, days: 30, until: fixture.day(3))
        #expect(replaced.summary?.totalInputTokens == 7)
        #expect(replacedWork.transcriptParses == 1)
        let (final, finalWork) = try fixture.load(context: .regular, days: 30, until: fixture.day(4), cold: true)
        #expect(finalWork.transcriptParses == 0)
        try fixture.expectColdOracle(final, days: 30, until: fixture.day(4))
    }

    @Test
    func `certified older caches without source coverage rebuild once`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        _ = try fixture.write(path: "old-cache.jsonl", day: fixture.day(-2), id: "recent", input: 10)
        _ = try fixture.load(context: .regular, days: 30)
        let url = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prior = try #require(CostUsageClaudeReportMemo.shared.entry(
            provider: .claude, canonicalCachePath: canonicalPath))
        var cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        cache.sourceDayBounds = [:]
        let stamp = try #require(try CostUsageClaudeCacheIO.save(
            provider: .claude,
            cache: cache,
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.options.calendar))
        var key = prior.reportKey
        key.cacheArtifactStamp = stamp
        CostUsageClaudeReportMemo.shared.store(
            provider: .claude,
            canonicalCachePath: canonicalPath,
            sourceInventory: prior.sourceInventory,
            reportKey: key,
            report: prior.report,
            hasWindowScopedRows: true)
        CostUsageClaudeCacheIO.evictArtifactMemoForTesting(at: url)
        let (next, work) = try fixture.load(context: .regular, days: 30, until: fixture.day(1), cold: true)
        #expect(work.transcriptParses == 1)
        try fixture.expectColdOracle(next, days: 30, until: fixture.day(1))
        let (later, laterWork) = try fixture.load(context: .regular, days: 30, until: fixture.day(2), cold: true)
        #expect(laterWork.transcriptParses == 0)
        try fixture.expectColdOracle(later, days: 30, until: fixture.day(2))
    }

    @Test
    func `an unfinished source tail cannot certify rollover reuse`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let contents = try fixture.event(day: fixture.day(-2), id: "recent", input: 10)
            + "{\"type\":\"assistant\""
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "partial.jsonl", contents: contents)
        _ = try fixture.load(context: .regular, days: 30)
        let (next, work) = try fixture.load(context: .regular, days: 30, until: fixture.day(1), cold: true)
        #expect(work.transcriptParses == 1)
        try fixture.expectColdOracle(next, days: 30, until: fixture.day(1))
    }

    @Test
    func `source coverage keeps identity key spelling through fragment round trips`() throws {
        var cache = CostUsageClaudeCache()
        let path = "/synthetic/caf\u{e9}.jsonl"
        let sourceKey = "/synthetic/cafe\u{301}.jsonl"
        cache.usage.files[path] = CostUsageFileUsage(mtimeUnixMs: 1, size: 1, days: [:], claudeRows: [])
        cache.sourceFileIDs[sourceKey] = "synthetic-identity"
        cache.sourceDayBounds[sourceKey] = CostUsageClaudeDayBounds(first: "2026-08-30", last: "2026-08-30")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(cache)
        let (header, files) = try cache.split()
        var restored = header
        restored.join(files)
        #expect(try encoder.encode(restored) == before)
    }

    @Test
    func `symlink sources keep Claude and Vertex coverage separate across rollover`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let native = try fixture.event(day: fixture.day(-2), id: "native", input: 10)
        let vertex = try fixture.event(day: fixture.day(-2), id: "vertex", input: 20)
            .replacingOccurrences(of: "request-vertex", with: "req_vrtx_synthetic")
        let source = try fixture.env.writeClaudeProjectFile(relativePath: "mixed.jsonl", contents: native + vertex)
        try FileManager.default.createSymbolicLink(
            at: fixture.env.claudeProjectsRoot.appendingPathComponent("alias.jsonl"),
            withDestinationURL: source)
        func load(
            provider: UsageProvider,
            options: CostUsageScanner.Options,
            offset: Int) throws -> (CostUsageDailyReport, CostUsageScanner.ClaudeScanWorkMetrics)
        {
            let end = fixture.day(offset)
            let start = try #require(fixture.options.calendar.date(byAdding: .day, value: -29, to: end))
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            let report = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                try CostUsageScanner.loadDailyReportCancellable(
                    provider: provider,
                    since: start,
                    until: end,
                    now: end,
                    options: options,
                    reportContext: .regular,
                    checkCancellation: nil)
            }
            return (report, recorder.snapshot())
        }
        for (provider, filter, expected) in [
            (UsageProvider.claude, CostUsageScanner.ClaudeLogProviderFilter.excludeVertexAI, 10),
            (.vertexai, .all, 20),
        ] {
            var options = fixture.options
            options.claudeLogProviderFilter = filter
            #expect(try load(provider: provider, options: options, offset: 0).0.summary?.totalInputTokens == expected)
            let (next, work) = try load(provider: provider, options: options, offset: 1)
            #expect(next.summary?.totalInputTokens == expected)
            #expect(work.transcriptParses == 0)
            options.cacheRoot = fixture.env.root.appendingPathComponent("oracle-\(provider.rawValue)")
            let oracle = try load(provider: provider, options: options, offset: 1).0
            #expect(next.data == oracle.data)
            #expect(next.summary == oracle.summary)
            #expect(next.hourly == oracle.hourly)
            #expect(next.quotaSlices == oracle.quotaSlices)
        }
        let (changedFilter, work) = try load(provider: .claude, options: fixture.options, offset: 2)
        #expect(changedFilter.summary?.totalInputTokens == 30)
        #expect(work.transcriptParses == 2)
    }
}
