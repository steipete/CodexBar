import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexOrdinalSubagentResumeTests {
    private static let copiedEventCount = CostUsageScanner.codexBufferedFastLineCountLimit + 24
    private static let sliceBytes: Int64 = 16 * 1024

    @Test
    func `protocol ordinal stays compact across slices and appends from the owned suffix`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let sessionID = "ordinal-linear-child"
        let parentID = "ordinal-linear-parent"
        let historyStartOrdinal = Self.copiedEventCount + 1
        var lines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","ordinal":0,"timestamp":"\#(timestamp)","payload":{"id":"\#(sessionID)","forked_from_id":"\#(parentID)","timestamp":"\#(timestamp)","subagent_history_start_ordinal":\#(historyStartOrdinal),"source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parentID)"}}}}}"#,
        ]
        for ordinal in 1...Self.copiedEventCount {
            lines.append(Self.tokenLine(
                timestamp: timestamp,
                ordinal: ordinal,
                model: "openai/gpt-5.3",
                totalInput: ordinal * 10,
                lastInput: 10))
        }
        lines.append(
            // swiftlint:disable:next line_length
            #"{"type":"turn_context","ordinal":\#(historyStartOrdinal),"timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#)
        lines.append(Self.tokenLine(
            timestamp: timestamp,
            ordinal: historyStartOrdinal + 1,
            model: "openai/gpt-5.4",
            totalInput: Self.copiedEventCount * 10 + 10,
            lastInput: 10))
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "ordinal-linear-child.jsonl",
            contents: lines.joined(separator: "\n") + "\n")

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"),
            maxCodexSessionFileBytes: Self.sliceBytes,
            maxCodexScanBytesPerRefresh: Self.sliceBytes,
            maxCodexScanDurationPerRefresh: nil)
        options.refreshMinIntervalSeconds = 0

        var previousOffset: Int64 = 0
        var completedReport: CostUsageDailyReport?
        var completedUsage: CostUsageFileUsage?
        for pass in 0..<128 {
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            guard let usage = cache.files.values.first(where: { $0.sessionId == sessionID }) else { continue }
            let offset = try #require(usage.parsedBytes)
            #expect(offset >= previousOffset)
            #expect(usage.codexBufferedSubagentLines == nil)
            #expect(usage.codexDeferredReplayState == nil)
            #expect(usage.codexSubagentResumeState != nil)
            previousOffset = offset
            if usage.codexScanComplete == true {
                completedReport = report
                completedUsage = usage
                break
            }
        }

        let initialReport = try #require(completedReport)
        let initialUsage = try #require(completedUsage)
        #expect(initialReport.data.first?.totalTokens == 10)
        #expect(initialUsage.codexSubagentResumeState?.phase == .ownedSuffix)
        #expect(initialUsage.forkBaselineDependencyKey == CostUsageScanner.codexForkDependencyNotRequiredKey)
        let initialSize = try #require(initialUsage.parsedBytes)
        let initialGeneration = try #require(initialUsage.codexUsageRowSidecarState?.generation)

        let appended = Self.tokenLine(
            timestamp: timestamp,
            ordinal: historyStartOrdinal + 2,
            model: "openai/gpt-5.4",
            totalInput: Self.copiedEventCount * 10 + 15,
            lastInput: 5) + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        let appendedSize = CostUsageScanner.codexFileMetadata(fileURL: fileURL).size

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let appendedReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(10000),
            options: options)
        let metrics = recorder.snapshot()
        #expect(metrics.fileParseInvocations == 1)
        #expect(metrics.fileBodyBudgetBytesConsumed == appendedSize - initialSize)
        #expect(metrics.fileBodyBudgetBytesConsumed < initialSize)
        #expect(appendedReport.data.first?.totalTokens == 15)

        let appendedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let appendedUsage = try #require(
            appendedCache.files.values.first(where: { $0.sessionId == sessionID }))
        #expect(appendedUsage.codexScanComplete == true)
        #expect(appendedUsage.codexBufferedSubagentLines == nil)
        #expect(appendedUsage.codexDeferredReplayState == nil)
        #expect(appendedUsage.codexSubagentResumeState?.phase == .ownedSuffix)
        #expect(appendedUsage.codexUsageRowSidecarState?.generation == initialGeneration)
    }

    @Test
    func `foundation fallback token crosses the protocol owned boundary without replaying prefix`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let sessionID = "foundation-ordinal-child"
        let parentID = "foundation-ordinal-parent"
        let metadata =
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","ordinal":0,"timestamp":"\#(timestamp)","payload":{"id":"\#(sessionID)","forked_from_id":"\#(parentID)","timestamp":"\#(timestamp)","subagent_history_start_ordinal":2,"source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parentID)"}}}}}"#
        let copied = Self.tokenLine(
            timestamp: timestamp,
            ordinal: 1,
            model: "openai/gpt-5.3",
            totalInput: 100,
            lastInput: 100)
        // Escaping the root type makes the byte parser decline this line. The literal nested
        // marker admits it through the cheap prefilter, so Foundation decoding returns before
        // the ordinal router transitions copiedPrefix -> ownedSuffix for this same record.
        let ownedFallback =
            // swiftlint:disable:next line_length
            #"{"\u0074ype":"event_msg","marker":{"type":"event_msg"},"ordinal":2,"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"model":"openai/gpt-5.4","total_token_usage":{"input_tokens":107,"cached_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0}}}}"#
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "foundation-ordinal-child.jsonl",
            contents: [metadata, copied, ownedFallback].joined(separator: "\n") + "\n")

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.4"] == [7, 0, 0])
        #expect(parsed.days[dayKey]?["gpt-5.3"] == nil)
        #expect(parsed.rows.count == 1)
        #expect(parsed.subagentResumeState?.phase == .ownedSuffix)
    }

    private static func tokenLine(
        timestamp: String,
        ordinal: Int,
        model: String,
        totalInput: Int,
        lastInput: Int) -> String
    {
        // swiftlint:disable:next line_length
        #"{"type":"event_msg","ordinal":\#(ordinal),"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"model":"\#(model)","total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":\#(lastInput),"cached_input_tokens":0,"output_tokens":0}}}}"#
    }
}
