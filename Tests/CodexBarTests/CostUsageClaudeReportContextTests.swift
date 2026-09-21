import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageClaudeReportContextTests {
    @Test(arguments: [false, true], [false, true])
    func `app refresh repairs a narrow legacy memo projected from a wide cache`(
        cold: Bool,
        narrowRewrite: Bool) throws
    {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let contents = try fixture.event(day: fixture.now, id: "same", input: 10)
            + fixture.event(day: fixture.day(-120), id: "same", input: 20)
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "legacy.jsonl", contents: contents)
        _ = fixture.loadLegacy(days: 365)
        if narrowRewrite {
            _ = try fixture.write(path: "changed.jsonl", day: fixture.now, id: "changed", input: 3)
        }
        _ = fixture.loadLegacy(days: 30)
        if narrowRewrite {
            let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
            let range = CostUsageScanner.CostUsageDayRange(
                since: fixture.day(-29), until: fixture.now, calendar: fixture.options.calendar)
            #expect(cache.usage.scanSinceKey == range.scanSinceKey)
            #expect(cache.usage.scanUntilKey == range.scanUntilKey)
        }
        if cold {
            let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: fixture.env.cacheRoot)
            let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL)
            var memo = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: memoURL)) as? [String: Any])
            memo.removeValue(forKey: "hasWindowScopedRows")
            try JSONSerialization.data(withJSONObject: memo).write(to: memoURL, options: .atomic)
        }
        let (report, _) = try fixture.load(context: .regular, days: 30, cold: cold)
        #expect(report.summary?.totalInputTokens == (narrowRewrite ? 13 : 10))
        try fixture.expectColdOracle(report, days: 30)
        #expect(try fixture.load(context: .regular, days: 30, cold: true).1.transcriptParses == 0)
    }

    @Test
    func `legacy same window append preserves a certified app baseline`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let file = try fixture.write(path: "recent.jsonl", day: fixture.now, id: "recent", input: 10)
        _ = try fixture.load(context: .regular, days: 30)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(fixture.event(day: fixture.now, id: "append", input: 5).utf8))
        try handle.close()
        #expect(fixture.loadLegacy(days: 30).summary?.totalInputTokens == 15)
        let (report, work) = try fixture.load(context: .regular, days: 30, cold: true)
        #expect(report.summary?.totalInputTokens == 15)
        #expect(work == CostUsageScanner.ClaudeScanWorkMetrics())
    }

    @Test(arguments: [false, true])
    func `external cache replacement cannot inherit a prior row certificate`(cold: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let contents = try fixture.event(day: fixture.now, id: "same", input: 10)
            + fixture.event(day: fixture.day(-120), id: "same", input: 20)
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "duplicates.jsonl", contents: contents)
        _ = try fixture.load(context: .regular, days: 30)
        let legacyRoot = fixture.env.root.appendingPathComponent("legacy-cache")
        _ = fixture.loadLegacy(days: 365, cacheRoot: legacyRoot)
        _ = try fixture.write(path: "changed.jsonl", day: fixture.now, id: "changed", input: 3)
        _ = fixture.loadLegacy(days: 30, cacheRoot: legacyRoot)
        let replacement = try Data(contentsOf: CostUsageClaudeCacheIO.cacheFileURL(
            provider: .claude, cacheRoot: legacyRoot))
        try replacement.write(
            to: CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: fixture.env.cacheRoot),
            options: .atomic)
        let (report, work) = try fixture.load(context: .regular, days: 30, cold: cold)
        #expect(report.summary?.totalInputTokens == 13)
        #expect(work.transcriptParses == 2)
        #expect(work.incrementalTranscriptParses == 0)
        try fixture.expectColdOracle(report, days: 30)
    }

    @Test(arguments: [CostUsageReportContext.regular, .spendDashboard])
    func `shrinking an app window recovers its own duplicate winner`(context: CostUsageReportContext) throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let contents = try fixture.event(day: fixture.now, id: "same", input: 10)
            + fixture.event(day: fixture.day(-20), id: "same", input: 20)
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "shrinking.jsonl", contents: contents)
        #expect(try fixture.load(context: context, days: 30).0.summary?.totalInputTokens == 20)
        let (report, work) = try fixture.load(context: context, days: 7, cold: true)
        #expect(report.summary?.totalInputTokens == 10)
        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 0)
        try fixture.expectColdOracle(report, days: 7)
    }

    @Test(arguments: [false, true])
    func `menu and dashboard refreshes only parse their changed tail after both are warm`(cold: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let recent = try fixture.write(path: "recent.jsonl", day: fixture.now, id: "recent", input: 10)
        _ = try fixture.write(path: "old.jsonl", day: fixture.day(-120), id: "old", input: 20)
        _ = try fixture.load(context: .regular, days: 30)
        _ = try fixture.load(context: .spendDashboard, days: 365)

        let handle = try FileHandle(forWritingTo: recent)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(fixture.event(day: fixture.now, id: "append", input: 5).utf8))
        try handle.close()

        for (context, days, expected) in [
            (CostUsageReportContext.regular, 30, 15),
            (.spendDashboard, 365, 35),
        ] {
            let (report, work) = try fixture.load(context: context, days: days, cold: cold)
            #expect(report.summary?.totalInputTokens == expected)
            #expect(work.transcriptParses == 1)
            #expect(work.incrementalTranscriptParses == 1)
            try fixture.expectColdOracle(report, days: days)
        }
        #expect(try fixture.load(context: .regular, days: 30, cold: cold).1.transcriptParses == 0)
        #expect(try fixture.load(context: .spendDashboard, days: 365, cold: cold).1.transcriptParses == 0)
    }

    @Test(arguments: [false, true])
    func `each report preserves its own same identity winner after alternating ranges`(cold: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let contents = try fixture.event(day: fixture.now, id: "same", input: 10)
            + fixture.event(day: fixture.day(-120), id: "same", input: 20)
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "duplicates.jsonl", contents: contents)
        let (narrow, _) = try fixture.load(context: .regular, days: 30)
        let (wide, _) = try fixture.load(context: .spendDashboard, days: 365)
        #expect(narrow.summary?.totalInputTokens == 10)
        #expect(wide.summary?.totalInputTokens == 20)
        let (narrowAgain, _) = try fixture.load(context: .regular, days: 30, cold: cold)
        let (wideAgain, _) = try fixture.load(context: .spendDashboard, days: 365, cold: cold)
        #expect(narrowAgain.data == narrow.data)
        #expect(narrowAgain.summary == narrow.summary)
        #expect(wideAgain.data == wide.data)
        #expect(wideAgain.summary == wide.summary)
        try fixture.expectColdOracle(narrowAgain, days: 30)
        try fixture.expectColdOracle(wideAgain, days: 365)
    }

    @Test(arguments: [CostUsageReportContext.regular, .spendDashboard])
    func `replacement and deletion preserve the report window winners`(context: CostUsageReportContext) throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let file = try fixture.write(path: "replaced.jsonl", day: fixture.now, id: "same", input: 10)
        let days = context == .regular ? 30 : 365
        _ = try fixture.load(context: context, days: days)
        let replacement = try fixture.event(day: fixture.now, id: "same", input: 30)
            + fixture.event(day: fixture.day(-120), id: "same", input: 60)
        try Data(replacement.utf8).write(to: file, options: .atomic)

        let (report, work) = try fixture.load(context: context, days: days, cold: true)
        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 0)
        #expect(report.summary?.totalInputTokens == (context == .regular ? 30 : 60))
        try fixture.expectColdOracle(report, days: days)

        try FileManager.default.removeItem(at: file)
        let (deleted, _) = try fixture.load(context: context, days: days, cold: true)
        #expect(deleted.data.isEmpty)
        try fixture.expectColdOracle(deleted, days: days)
    }

    @Test(arguments: [CostUsageReportContext.regular, .spendDashboard])
    func `later end dates still recover previously filtered events without source changes`(
        context: CostUsageReportContext) throws
    {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        let contents = try fixture.event(day: fixture.now, id: "now", input: 10)
            + fixture.event(day: fixture.day(2), id: "future", input: 20)
        let file = try fixture.env.writeClaudeProjectFile(relativePath: "future.jsonl", contents: contents)
        let stamp = CostUsageClaudeFileStamp.read(at: file)
        #expect(try fixture.load(context: context, days: 30).0.summary?.totalInputTokens == 10)

        let (nextDay, nextWork) = try fixture.load(context: context, days: 30, until: fixture.day(1), cold: true)
        #expect(nextDay.summary?.totalInputTokens == 10)
        #expect(nextWork.transcriptParses == 1)
        #expect(nextWork.incrementalTranscriptParses == 0)
        let (later, _) = try fixture.load(context: context, days: 30, until: fixture.day(2), cold: true)
        #expect(later.summary?.totalInputTokens == 30)
        try fixture.expectColdOracle(later, days: 30, until: fixture.day(2))
        #expect(CostUsageClaudeFileStamp.read(at: file) == stamp)
        #expect(try Data(contentsOf: file) == Data(contents.utf8))
    }

    @Test
    func `dashboard cache creation preserves the released regular cache and memo`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        _ = try fixture.write(path: "recent.jsonl", day: fixture.now, id: "recent", input: 10)
        _ = try fixture.load(context: .regular, days: 30)
        let legacyURL = fixture.env.cacheRoot.appendingPathComponent("cost-usage/claude-v6.json")
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: legacyURL)
        let legacyData = try Data(contentsOf: legacyURL)
        let memoData = try Data(contentsOf: memoURL)
        _ = try fixture.load(context: .spendDashboard, days: 365)
        #expect(try Data(contentsOf: legacyURL) == legacyData)
        #expect(try Data(contentsOf: memoURL) == memoData)
        #expect(try fixture.load(context: .regular, days: 30, cold: true).1 ==
            CostUsageScanner.ClaudeScanWorkMetrics())
    }

    @Test
    func `dashboard Vertex reads preserve the default provider filter`() throws {
        let fixture = try Fixture()
        defer { fixture.env.cleanup() }
        _ = try fixture.write(path: "anthropic.jsonl", day: fixture.now, id: "ordinary", input: 10)
        let vertex = try fixture.event(day: fixture.now, id: "vertex", input: 20)
            .replacingOccurrences(of: "request-vertex", with: "req_vrtx_fixture")
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "vertex.jsonl", contents: vertex)
        for context in [CostUsageReportContext.regular, .spendDashboard] {
            let report = try CostUsageScanner.loadDailyReportCancellable(
                provider: .vertexai,
                since: fixture.now,
                until: fixture.now,
                now: fixture.now,
                options: fixture.options,
                reportContext: context,
                checkCancellation: nil)
            #expect(report.summary?.totalInputTokens == 20)
        }
    }

    struct Fixture {
        let env: CostUsageTestEnvironment
        let now: Date
        let options: CostUsageScanner.Options

        init(now: Date? = nil) throws {
            self.env = try CostUsageTestEnvironment()
            self.now = try now ?? self.env.makeLocalNoon(year: 2026, month: 9, day: 1)
            var options = CostUsageScanner.Options(
                claudeProjectsRoots: [self.env.claudeProjectsRoot],
                cacheRoot: self.env.cacheRoot)
            options.refreshMinIntervalSeconds = 0
            self.options = options
        }

        func day(_ offset: Int) -> Date {
            self.options.calendar.date(byAdding: .day, value: offset, to: self.now)!
        }

        func load(
            context: CostUsageReportContext,
            days: Int,
            until: Date? = nil,
            cold: Bool = false,
            cacheRoot: URL? = nil) throws -> (CostUsageDailyReport, CostUsageScanner.ClaudeScanWorkMetrics)
        {
            if cold {
                CostUsageScanner.evictClaudeReportMemoForTesting(
                    provider: .claude,
                    cacheRoot: self.env.cacheRoot,
                    reportContext: context)
            }
            var options = self.options
            if let cacheRoot { options.cacheRoot = cacheRoot }
            let end = until ?? self.now
            let start = options.calendar.date(byAdding: .day, value: -(days - 1), to: end)!
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            let report = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                try CostUsageScanner.loadDailyReportCancellable(
                    provider: .claude,
                    since: start,
                    until: end,
                    now: end,
                    options: options,
                    reportContext: context,
                    checkCancellation: nil)
            }
            return (report, recorder.snapshot())
        }

        func loadLegacy(days: Int, cacheRoot: URL? = nil) -> CostUsageDailyReport {
            var options = self.options
            if let cacheRoot { options.cacheRoot = cacheRoot }
            return CostUsageScanner.loadDailyReport(
                provider: .claude,
                since: self.day(-(days - 1)),
                until: self.now,
                now: self.now,
                options: options)
        }

        func expectColdOracle(_ report: CostUsageDailyReport, days: Int, until: Date? = nil) throws {
            let root = self.env.root.appendingPathComponent("oracle-\(UUID().uuidString)")
            let (oracle, _) = try self.load(context: .regular, days: days, until: until, cacheRoot: root)
            #expect(report.data == oracle.data)
            #expect(report.summary == oracle.summary)
            #expect(report.hourly == oracle.hourly)
            #expect(report.quotaSlices == oracle.quotaSlices)
        }

        func write(path: String, day: Date, id: String, input: Int) throws -> URL {
            try self.env.writeClaudeProjectFile(
                relativePath: path,
                contents: self.event(day: day, id: id, input: input))
        }

        func event(day: Date, id: String, input: Int) throws -> String {
            try self.env.jsonl([[
                "type": "assistant",
                "timestamp": self.env.isoString(for: day),
                "sessionId": "fixture-session",
                "requestId": "request-\(id)",
                "message": [
                    "id": "message-\(id)",
                    "model": "claude-sonnet-4-20250514",
                    "usage": ["input_tokens": input, "output_tokens": 0],
                ],
            ]])
        }
    }
}
