import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexUsageRowLinearWorkTests {
    private static let initialRowCount = 2048
    private static let boundedSliceBytes: Int64 = 32 * 1024

    @Test
    func `append and stable EOF usage row work stays proportional to the delta`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let sessionID = "linear-row-session"
        var lines = [
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"session_id":"\#(sessionID)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
        ]
        lines.reserveCapacity(Self.initialRowCount + 2)
        for index in 0..<Self.initialRowCount {
            lines.append(Self.tokenLine(timestamp: timestamp, cumulativeInput: index + 1))
        }
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "linear-row-session.jsonl",
            contents: lines.joined(separator: "\n") + "\n")
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(3600)],
            ofItemAtPath: fileURL.path)

        var boundedOptions = Self.options(
            env: env,
            cacheRoot: env.cacheRoot,
            forceRescan: false,
            maxFileBytes: Self.boundedSliceBytes)
        var boundedCache = CostUsageCache()
        var boundedCompleted = false
        for pass in 0..<64 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: boundedOptions)
            boundedCache = CostUsageCacheIO.load(
                provider: .codex,
                cacheRoot: env.cacheRoot,
                calendar: boundedOptions.calendar)
            if let usage = boundedCache.files.values.first(where: { $0.sessionId == sessionID }),
               usage.codexScanComplete == true,
               usage.codexUsageRowSidecarState?.rowCount == Self.initialRowCount,
               boundedCache.codexScanCatchUpPending != true
            {
                boundedCompleted = true
                break
            }
        }

        #expect(boundedCompleted)
        let initialUsage = try #require(
            boundedCache.files.values.first(where: { $0.sessionId == sessionID }))
        #expect(initialUsage.codexScanComplete == true)
        #expect(initialUsage.codexRows == nil)
        #expect(initialUsage.codexTurnIDs == nil)
        #expect(initialUsage.codexUsageRowSidecarState?.rowCount == Self.initialRowCount)
        #expect(initialUsage.codexUsageRowSidecarState?.nextUsageRowIndex == Self.initialRowCount)
        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        let initialJSONBytes = try Data(contentsOf: cacheURL).count

        let appendedRowCount = Self.initialRowCount + 1
        try Self.append(
            Self.tokenLine(timestamp: timestamp, cumulativeInput: appendedRowCount) + "\n",
            to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(7200)],
            ofItemAtPath: fileURL.path)

        let appendRecorder = CostUsageScanner.CodexScanWorkRecorder()
        boundedOptions.codexScanWorkRecorderForTesting = appendRecorder
        let appendedReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(10000),
            options: boundedOptions)
        let appendMetrics = appendRecorder.snapshot()
        #expect(appendMetrics.usageRowsRead == 0)
        #expect(appendMetrics.usageRowDeltaProcessed == 1)
        #expect(appendMetrics.usageRowsWritten == 1)
        #expect(appendMetrics.usageRowsRepriced == 1)
        #expect(appendMetrics.usageRowsFingerprintHashed == 1)

        let appendedCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: boundedOptions.calendar)
        let appendedUsage = try #require(
            appendedCache.files.values.first(where: { $0.sessionId == sessionID }))
        #expect(appendedUsage.codexScanComplete == true)
        #expect(appendedUsage.codexRows == nil)
        #expect(appendedUsage.codexTurnIDs == nil)
        #expect(appendedUsage.codexUsageRowSidecarState?.rowCount == appendedRowCount)
        #expect(appendedUsage.codexUsageRowSidecarState?.nextUsageRowIndex == appendedRowCount)
        #expect(appendedUsage.codexTokenSidecarState?.nextUsageRowIndex == appendedRowCount)
        #expect(appendedCache.codexScanCatchUpPending != true)

        let stableRecorder = CostUsageScanner.CodexScanWorkRecorder()
        boundedOptions.codexScanWorkRecorderForTesting = stableRecorder
        let stableReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(10001),
            options: boundedOptions)
        let stableMetrics = stableRecorder.snapshot()
        #expect(stableMetrics.fileBodyBudgetBytesConsumed == 0)
        #expect(stableMetrics.fileParseInvocations == 0)
        #expect(stableMetrics.usageRowsRead == 0)
        #expect(stableMetrics.usageRowDeltaProcessed == 0)
        #expect(stableMetrics.usageRowsWritten == 0)
        #expect(stableMetrics.usageRowsRepriced == 0)
        #expect(stableMetrics.usageRowsFingerprintHashed == 0)
        #expect(stableReport.data == appendedReport.data)
        #expect(stableReport.summary == appendedReport.summary)

        let stableCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: boundedOptions.calendar)
        let stableUsage = try #require(
            stableCache.files.values.first(where: { $0.sessionId == sessionID }))
        #expect(stableUsage.codexRows == nil)
        #expect(stableUsage.codexTurnIDs == nil)
        #expect(stableUsage.codexUsageRowSidecarState?.rowCount == appendedRowCount)
        let finalJSONBytes = try Data(contentsOf: cacheURL).count
        #expect(finalJSONBytes < 64 * 1024)
        #expect(finalJSONBytes <= initialJSONBytes + 4 * 1024)

        let controlCacheRoot = env.root.appendingPathComponent("linear-row-control-cache", isDirectory: true)
        let controlOptions = Self.options(
            env: env,
            cacheRoot: controlCacheRoot,
            forceRescan: true,
            maxFileBytes: 0)
        let controlReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(10001),
            options: controlOptions)
        #expect(stableReport.data == controlReport.data)
        #expect(stableReport.summary == controlReport.summary)
    }

    private static func options(
        env: CostUsageTestEnvironment,
        cacheRoot: URL,
        forceRescan: Bool,
        maxFileBytes: Int64) -> CostUsageScanner.Options
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"),
            calendar: .current,
            forceRescan: forceRescan,
            maxCodexSessionFileBytes: maxFileBytes,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: nil,
            preferNewestCodexSessionsFirst: true)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func tokenLine(timestamp: String, cumulativeInput: Int) -> String {
        let cached = cumulativeInput / 10
        let output = cumulativeInput / 20
        return #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":"#
            + #"{"total_token_usage":{"input_tokens":\#(cumulativeInput),"cached_input_tokens":\#(cached),"#
            + #""output_tokens":\#(output)},"model":"openai/gpt-5.4"}}}"#
    }

    private static func append(_ contents: String, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }
}
