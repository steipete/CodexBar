import Foundation
#if canImport(SQLite3)
import Testing
@testable import CodexBarCore

extension CostUsageScannerCodexPriorityCursorTests {
    @Test
    func `budgeted rescan preserves unseen request pricing across store reopen`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date()
        let day = try #require(Calendar.current.date(byAdding: .day, value: -10, to: now))
        let earlier = try #require(Calendar.current.date(byAdding: .day, value: -20, to: now))
        let dbURL = env.root.appendingPathComponent("pricing-traces.sqlite")
        defer { CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path) }
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [
            (Int64(day.timeIntervalSince1970), Self.priorityRequestBody(threadID: "partial", turnID: "changed")),
            (Int64(day.timeIntervalSince1970), Self.priorityRequestBody(threadID: "partial", turnID: "unchanged")),
            (Int64(now.timeIntervalSince1970), Self.priorityRequestBody(threadID: "other", turnID: "other")),
        ])
        func lines(changedInput: Int) -> [String] {
            var result = [#"{"type":"session_meta","payload":{"session_id":"partial"}}"#]
            for (date, turn, input) in [
                (earlier, "earlier", 10),
                (day, "changed", changedInput),
                (day.addingTimeInterval(1), "unchanged", 100),
                (now, "later", 30),
            ] {
                let iso = env.isoString(for: date)
                result.append(#"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5.5"}}"#)
                result.append(#"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"task_started","#
                    + #""turn_id":"\#(turn)"}}"#)
                result.append(#"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":0},"#
                    + #""model":"gpt-5.5"}}}"#)
            }
            return result
        }
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "partial-pricing.jsonl",
            contents: lines(changedInput: 200).joined(separator: "\n") + "\n")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: dbURL)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: earlier, until: now, now: now, options: options)
        let original = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let referenceRoot = env.root.appendingPathComponent("reference-cache")
        _ = CostUsageStoreAccess.replace(cacheRoot: referenceRoot, cache: original)
        try Self.deleteTestLog(dbURL: dbURL, rowID: 1)
        try Self.deleteTestLog(dbURL: dbURL, rowID: 2)
        let rewritten = lines(changedInput: 250)
        try (rewritten.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        var referenceOptions = options
        referenceOptions.cacheRoot = referenceRoot
        let expected = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: now.addingTimeInterval(1), options: referenceOptions)
        #expect(expected.summary?.totalTokens == 350)
        #expect(expected.data.first?.modelBreakdowns?.first?.priorityTokens == 100)
        let budget = Int64((rewritten.prefix(7).joined(separator: "\n") + "\n").utf8.count)
        options.maxCodexScanBytesPerRefresh = budget
        options.maxCodexSessionFileBytes = budget
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: now.addingTimeInterval(1), options: options)
        let partial = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[fileURL.path])
        #expect(partial.codexScanComplete == false)
        let partialInputs = Set(partial.codexRows?.map(\.input) ?? [])
        #expect(partialInputs.isSuperset(of: [10, 30]))
        #expect(partialInputs.isSubset(of: [10, 30, 250]))
        #expect(await CostUsageStore(cacheRoot: env.cacheRoot).fetchBufferedLines(path: fileURL.path).isEmpty == false)

        for index in 2..<30 {
            CostUsageScanner._test_resetCodexPriorityTurnsMemo(forPath: dbURL.path)
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: day, now: now.addingTimeInterval(Double(index)), options: options)
            if CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending != true { break }
        }
        let finalCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(finalCache.codexScanCatchUpPending != true)
        let final = try #require(finalCache.files[fileURL.path])
        #expect(final.codexRows?.map(\.input).sorted() == [10, 30, 100, 250])
        #expect(final.codexRows?.first { $0.turnID == "unchanged" }?.eventIndex == 2)
        #expect(await CostUsageStore(cacheRoot: env.cacheRoot).fetchBufferedLines(path: fileURL.path).isEmpty == true)
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: finalCache, range: .init(since: day, until: day))
        #expect(report.data == expected.data)
        #expect(report.summary == expected.summary)
    }
}
#endif
