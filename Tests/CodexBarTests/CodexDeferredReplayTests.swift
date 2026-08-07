import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexDeferredReplayTests {
    private static let eventCount = CostUsageScanner.codexBufferedFastLineCountLimit + 32

    private enum OrdinaryReplayMutation: Equatable {
        case appendBeforeReplay
        case appendDuringReplay
        case sameSizeRewrite
    }

    @Test
    func `ambiguous legacy subagent overflow is fail closed then replays once`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        var lines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"legacy-overflow","source":{"subagent":{"thread_spawn":{}}}}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
        ]
        for value in 1...Self.eventCount {
            lines.append(Self.tokenLine(timestamp: timestamp, totalInput: value, lastInput: 1))
        }
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "legacy-overflow.jsonl",
            contents: lines.joined(separator: "\n") + "\n")
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)

        let indexing = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)
        let plan = try #require(indexing.deferredReplayState)
        #expect(plan.phase == .replaying)
        #expect(plan.mode == .independentSubagent)
        #expect(indexing.rows.isEmpty)
        #expect(indexing.days.isEmpty)
        #expect(indexing.bufferedSubagentLines == nil)
        #expect(indexing.bufferedUnresolvedForkLines == nil)

        let replay = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: fileURL,
            range: range,
            initialDeferredReplayContext: .init(
                sessionId: indexing.sessionId,
                parentSessionId: indexing.forkedFromId,
                forkTimestamp: indexing.forkTimestamp,
                projectPath: indexing.projectPath,
                codexSession: indexing.codexSession,
                state: plan))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let model = CostUsagePricing.normalizeCodexModel("openai/gpt-5.4")
        #expect(replay.days[dayKey]?[model] == [Self.eventCount, 0, 0])
        #expect(replay.deferredReplayState == nil)
        #expect(replay.bufferedSubagentLines == nil)
    }

    @Test
    func `unresolved ordinary fork overflow never counts the truncated buffer`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        var lines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"fork-overflow","forked_from_id":"redacted-parent","timestamp":"\#(timestamp)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
        ]
        for value in 1...Self.eventCount {
            lines.append(Self.tokenLine(
                timestamp: timestamp,
                totalInput: 1000 + value,
                lastInput: 1))
        }
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "fork-overflow.jsonl",
            contents: lines.joined(separator: "\n") + "\n")
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)

        let indexing = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: range,
            inheritedTotalsResolver: { _, _ in .unresolved })
        let plan = try #require(indexing.deferredReplayState)
        #expect(plan.phase == .replaying)
        #expect(plan.mode == .unresolvedFork)
        #expect(indexing.rows.isEmpty)
        #expect(indexing.days.isEmpty)
        #expect(indexing.bufferedUnresolvedForkLines == nil)

        let replay = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: fileURL,
            range: range,
            initialDeferredReplayContext: .init(
                sessionId: indexing.sessionId,
                parentSessionId: indexing.forkedFromId,
                forkTimestamp: indexing.forkTimestamp,
                projectPath: indexing.projectPath,
                codexSession: indexing.codexSession,
                state: plan),
            inheritedTotalsResolver: { parentID, _ in
                #expect(parentID == "redacted-parent")
                return .resolved(.init(input: 1000, cached: 0, output: 0))
            })
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let model = CostUsagePricing.normalizeCodexModel("openai/gpt-5.4")
        #expect(replay.days[dayKey]?[model] == [Self.eventCount, 0, 0])
        #expect(replay.deferredReplayState == nil)
        #expect(replay.bufferedUnresolvedForkLines == nil)
    }

    @Test
    func `overflow indexing preserves metadata when copied history needs no replay`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let laterTimestamp = env.isoString(for: day.addingTimeInterval(60))
        var lines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"metadata-leaf","source":{"subagent":{"thread_spawn":{}}}}}"#,
        ]
        for value in 1...Self.eventCount {
            lines.append(Self.tokenLine(timestamp: timestamp, totalInput: value, lastInput: 1))
        }
        // Two distinct embedded ancestors prove copied history without inferring a unique parent.
        // With no token after the final context there is no owned suffix and therefore no replay.
        lines.append(#"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"ancestor-a"}}"#)
        lines.append(#"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"ancestor-b"}}"#)
        lines.append(
            // swiftlint:disable:next line_length
            #"{"type":"turn_context","timestamp":"\#(laterTimestamp)","payload":{"model":"openai/gpt-5.4","cwd":"/redacted/project","title":"Redacted proof"}}"#)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "metadata-overflow.jsonl",
            contents: lines.joined(separator: "\n") + "\n")
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)

        let parsed = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)

        #expect(parsed.days.isEmpty)
        #expect(parsed.rows.isEmpty)
        #expect(parsed.deferredReplayState == nil)
        #expect(parsed.bufferedSubagentLines == nil)
        #expect(parsed.lastModel == "openai/gpt-5.4")
        #expect(parsed.codexSession.cwd == "/redacted/project")
        #expect(parsed.codexSession.title == "Redacted proof")
        #expect(parsed.codexSession.latestActivityUnixMs != nil)
    }

    @Test
    func `persisted replay starts at zero once and progress stays monotonic`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        var lines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"persisted-replay","source":{"subagent":{"thread_spawn":{}}}}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
        ]
        for value in 1...Self.eventCount {
            lines.append(Self.tokenLine(timestamp: timestamp, totalInput: value, lastInput: 1))
        }
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "persisted-replay.jsonl",
            contents: lines.joined(separator: "\n") + "\n")
        let indexedSize = CostUsageScanner.codexFileMetadata(fileURL: fileURL).size

        let sliceBytes: Int64 = 16 * 1024
        var options = Self.options(env: env, maxFileBytes: sliceBytes)
        var previousProgress: Int64 = 0
        var previousReplayCursor: Int64?
        var sawReplayStart = false
        var sawCompleted = false
        var sawPersistedIndexShape = false
        var replayStartTransitions = 0

        for pass in 0..<80 {
            let recorder = CostUsageScanner.CodexScanWorkRecorder()
            options.codexScanWorkRecorderForTesting = recorder
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let usage = try #require(cache.files.values.first { $0.sessionId == "persisted-replay" })
            let progress = cache.codexScanProcessedBytes ?? 0
            #expect(progress >= previousProgress)
            previousProgress = progress

            if let replay = usage.codexDeferredReplayState, replay.phase == .replaying {
                #expect(replay.mode == .independentSubagent)
                #expect(usage.forkedFromId == nil)
                if replay.replayStarted == true {
                    if !sawReplayStart {
                        replayStartTransitions += 1
                        sawReplayStart = true
                        #expect((usage.parsedBytes ?? indexedSize) < indexedSize)
                    }
                    if let previousReplayCursor {
                        #expect((usage.parsedBytes ?? 0) > previousReplayCursor)
                    }
                    previousReplayCursor = usage.parsedBytes
                } else {
                    #expect(usage.parsedBytes == indexedSize)
                    #expect(progress == indexedSize)
                    #expect(!sawReplayStart)
                }
            } else if let replay = usage.codexDeferredReplayState, replay.phase == .indexing {
                sawPersistedIndexShape = true
                let shape = try #require(replay.legacySubagentShape)
                #expect(shape.leafSessionId == "persisted-replay")
                #expect(shape.hasEmbeddedAncestor == false)
                #expect(shape.ancestorSessionIds.isEmpty)
                #expect(usage.forkedFromId == nil)
            }

            if usage.codexScanComplete == true {
                sawCompleted = true
                #expect(usage.codexDeferredReplayState == nil)
                break
            }
        }

        #expect(sawPersistedIndexShape)
        #expect(sawReplayStart)
        #expect(sawCompleted)
        #expect(replayStartTransitions == 1)
        let finalCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let finalUsage = try #require(finalCache.files.values.first { $0.sessionId == "persisted-replay" })
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let model = CostUsagePricing.normalizeCodexModel("openai/gpt-5.4")
        #expect(finalUsage.forkedFromId == nil)
        #expect(finalUsage.codexSession?.forkedFromId == nil)
        #expect(finalUsage.days[dayKey]?[model] == [Self.eventCount, 0, 0])

        let stableRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = stableRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(100),
            options: options)
        let stableMetrics = stableRecorder.snapshot()
        #expect(stableMetrics.fileBodyBudgetBytesConsumed == 0)
        #expect(stableMetrics.fileParseInvocations == 0)
    }

    @Test
    func `legacy replay plan reclassifies lineage appended before and during replay`() throws {
        try Self.assertLegacyAppendReclassification(afterReplayStarted: false)
        try Self.assertLegacyAppendReclassification(afterReplayStarted: true)
    }

    @Test
    func `legacy replay plan reclassifies a same size in place rewrite`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        var originalLines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"rewrite-leaf","source":{"subagent":{"thread_spawn":{}}}}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
        ]
        for value in 1...Self.eventCount {
            originalLines.append(Self.tokenLine(timestamp: timestamp, totalInput: value, lastInput: 1))
        }
        originalLines.append(
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"rewrite-leaf"}}"#)
        originalLines.append(
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"rewrite-leaf"}}"#)
        let originalBody = originalLines.joined(separator: "\n") + "\n"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "same-size-rewrite.jsonl",
            contents: originalBody)
        let originalMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let originalModificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)
        var options = Self.options(env: env, maxFileBytes: 0)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let classifiedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let classified = try #require(
            classifiedCache.files.values.first { $0.sessionId == "rewrite-leaf" })
        #expect(classified.codexDeferredReplayState?.phase == .replaying)
        #expect(classified.codexDeferredReplayState?.mode == .independentSubagent)
        #expect(classified.codexDeferredReplayState?.replayStarted != true)

        var rewrittenLines = originalLines
        rewrittenLines[rewrittenLines.count - 2] =
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"ancestor-one"}}"#
        rewrittenLines[rewrittenLines.count - 1] =
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"ancestor-two"}}"#
        let rewrittenBody = rewrittenLines.joined(separator: "\n") + "\n"
        #expect(rewrittenBody.utf8.count == originalBody.utf8.count)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewrittenBody.utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: fileURL.path)
        let rewrittenMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(rewrittenMetadata.fileId == originalMetadata.fileId)
        #expect(rewrittenMetadata.size == originalMetadata.size)
        #expect(rewrittenMetadata.mtimeUnixMs == originalMetadata.mtimeUnixMs)
        #expect(rewrittenMetadata.changeUnixNs != originalMetadata.changeUnixNs)

        options.maxCodexSessionFileBytes = 16 * 1024
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        var rebuiltCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        var rebuilt = try #require(rebuiltCache.files.values.first { $0.sessionId == "rewrite-leaf" })
        #expect(rebuilt.codexDeferredReplayState?.phase == .indexing)
        #expect(rebuilt.codexDeferredReplayState?.mode == .legacySubagentClassification)
        #expect((rebuilt.parsedBytes ?? rewrittenMetadata.size) < rewrittenMetadata.size)
        #expect(rebuilt.days.isEmpty)

        for pass in 2..<80 where rebuilt.codexScanComplete != true {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            rebuiltCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            rebuilt = try #require(rebuiltCache.files.values.first { $0.sessionId == "rewrite-leaf" })
        }
        #expect(rebuilt.codexScanComplete == true)
        #expect(rebuilt.codexDeferredReplayState == nil)
        #expect(rebuilt.days.isEmpty)
    }

    @Test
    func `ordinary unresolved replay preflights live lineage after source mutation`() throws {
        try Self.assertOrdinaryReplayUsesLiveLineage(after: .appendBeforeReplay)
        try Self.assertOrdinaryReplayUsesLiveLineage(after: .appendDuringReplay)
        try Self.assertOrdinaryReplayUsesLiveLineage(after: .sameSizeRewrite)
    }

    @Test
    func `stable missing replay is quiescent and parent appearance reactivates it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        var childLines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"missing-replay-child","forked_from_id":"redacted-parent","timestamp":"\#(timestamp)","source":{"subagent":{"thread_spawn":{}}}}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
        ]
        for value in 1...Self.eventCount {
            childLines.append(Self.tokenLine(timestamp: timestamp, totalInput: value, lastInput: 1))
        }
        childLines.append(
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"copied-ancestor"}}"#)
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "missing-replay-child.jsonl",
            contents: childLines.joined(separator: "\n") + "\n")
        var options = Self.options(env: env, maxFileBytes: 0)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let indexedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let indexedChild = try #require(
            indexedCache.files.values.first { $0.sessionId == "missing-replay-child" })
        #expect(indexedChild.codexDeferredReplayState?.phase == .replaying)
        #expect(indexedChild.codexDeferredReplayState?.mode == .inheritedSubagentFork)
        #expect(indexedChild.codexDeferredReplayState?.replayStarted != true)
        #expect(indexedChild.parsedBytes == CostUsageScanner.codexFileMetadata(fileURL: childURL).size)

        let settleRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = settleRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let settledCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let settledChild = try #require(
            settledCache.files.values.first { $0.sessionId == "missing-replay-child" })
        #expect(settledChild.forkBaselineDependencyKey?.hasPrefix("missing|redacted-parent|") == true)
        #expect(settledChild.hasSettledDeferredCodexReplay)
        #expect(settledCache.codexScanCatchUpPending == false)
        #expect(settledCache.codexScanCompletedFiles == settledCache.codexScanTotalFiles)
        #expect(settleRecorder.snapshot().fileBodyBudgetBytesConsumed == 0)
        #expect(settleRecorder.snapshot().fileParseInvocations == 0)

        let warmRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = warmRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(warmRecorder.snapshot().fileBodyBudgetBytesConsumed == 0)
        #expect(warmRecorder.snapshot().fileParseInvocations == 0)

        let parentLines = [
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"redacted-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
            Self.tokenLine(timestamp: timestamp, totalInput: Self.eventCount, lastInput: Self.eventCount),
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "redacted-parent.jsonl",
            contents: parentLines.joined(separator: "\n") + "\n")

        let reactivateRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = reactivateRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        let resolvedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let resolvedChild = try #require(
            resolvedCache.files.values.first { $0.sessionId == "missing-replay-child" })
        #expect(resolvedChild.codexDeferredReplayState == nil)
        #expect(resolvedChild.codexScanComplete == true)
        #expect(resolvedChild.forkBaselineDependencyKey?.hasPrefix("file|redacted-parent|") == true)
        #expect(reactivateRecorder.snapshot().fileBodyBudgetBytesConsumed > 0)
        #expect(reactivateRecorder.snapshot().fileParseInvocations > 0)
    }

    private static func options(
        env: CostUsageTestEnvironment,
        maxFileBytes: Int64) -> CostUsageScanner.Options
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: maxFileBytes,
            maxCodexScanBytesPerRefresh: 64 * 1024 * 1024,
            preferNewestCodexSessionsFirst: false)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func assertLegacyAppendReclassification(afterReplayStarted: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let sessionID = afterReplayStarted ? "mid-replay-append" : "before-replay-append"
        var lines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"\#(sessionID)","source":{"subagent":{"thread_spawn":{}}}}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
        ]
        for value in 1...Self.eventCount {
            lines.append(Self.tokenLine(timestamp: timestamp, totalInput: value, lastInput: 1))
        }
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "\(sessionID).jsonl",
            contents: lines.joined(separator: "\n") + "\n")
        var options = Self.options(env: env, maxFileBytes: 0)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        var usage = try #require(cache.files.values.first { $0.sessionId == sessionID })
        #expect(usage.codexDeferredReplayState?.phase == .replaying)
        #expect(usage.codexDeferredReplayState?.mode == .independentSubagent)
        #expect(usage.codexDeferredReplayState?.replayStarted != true)

        options.maxCodexSessionFileBytes = 16 * 1024
        if afterReplayStarted {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options)
            cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            usage = try #require(cache.files.values.first { $0.sessionId == sessionID })
            #expect(usage.codexDeferredReplayState?.phase == .replaying)
            #expect(usage.codexDeferredReplayState?.replayStarted == true)
            #expect((usage.parsedBytes ?? 0) > 0)
            #expect((usage.parsedBytes ?? 0) < CostUsageScanner.codexFileMetadata(fileURL: fileURL).size)
        }

        let appended = [
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"ancestor-one"}}"#,
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"id":"ancestor-two"}}"#,
        ].joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        let grownSize = CostUsageScanner.codexFileMetadata(fileURL: fileURL).size

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(afterReplayStarted ? 2 : 1),
            options: options)
        cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        usage = try #require(cache.files.values.first { $0.sessionId == sessionID })
        #expect(usage.codexDeferredReplayState?.phase == .indexing)
        #expect(usage.codexDeferredReplayState?.mode == .legacySubagentClassification)
        #expect((usage.parsedBytes ?? grownSize) < grownSize)
        #expect(usage.days.isEmpty)

        let firstCompletionPass = afterReplayStarted ? 3 : 2
        for pass in firstCompletionPass..<80 where usage.codexScanComplete != true {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            usage = try #require(cache.files.values.first { $0.sessionId == sessionID })
        }
        #expect(usage.codexScanComplete == true)
        #expect(usage.codexDeferredReplayState == nil)
        #expect(usage.days.isEmpty)
    }

    private static func assertOrdinaryReplayUsesLiveLineage(
        after mutation: OrdinaryReplayMutation) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let parentTimestamp = env.isoString(for: day)
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(1))
        let childTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let liveParentLines = [
            #"{"type":"session_meta","timestamp":"\#(parentTimestamp)","payload":{"id":"live-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(parentTimestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
            Self.tokenLine(timestamp: forkTimestamp, totalInput: 200, lastInput: 200),
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "00-live-parent.jsonl",
            contents: liveParentLines.joined(separator: "\n") + "\n")
        let nextParentLines = [
            #"{"type":"session_meta","timestamp":"\#(parentTimestamp)","payload":{"id":"next-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(parentTimestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
            Self.tokenLine(timestamp: forkTimestamp, totalInput: 220, lastInput: 220),
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "01-next-parent.jsonl",
            contents: nextParentLines.joined(separator: "\n") + "\n")
        let childLines = [
            // swiftlint:disable:next line_length
            #"{"type":"session_meta","timestamp":"\#(childTimestamp)","payload":{"id":"ordinary-live-child","forked_from_id":"live-parent","timestamp":"\#(forkTimestamp)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(childTimestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
            Self.tokenLine(timestamp: childTimestamp, totalInput: 250, lastInput: 50),
        ]
        let originalChildBody = childLines.joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "99-ordinary-live-child.jsonl",
            contents: originalChildBody)
        let originalMetadata = CostUsageScanner.codexFileMetadata(fileURL: childURL)
        let originalModificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: childURL.path)[.modificationDate] as? Date)
        var options = Self.options(env: env, maxFileBytes: 0)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let childEntry = try #require(
            cache.files.first { $0.value.sessionId == "ordinary-live-child" })
        var child = childEntry.value
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let model = CostUsagePricing.normalizeCodexModel("openai/gpt-5.4")
        #expect(child.days[dayKey]?[model] == [50, 0, 0])

        // Seed the persisted state reached by an interrupted ordinary replay, including a stale
        // contribution. The live source deliberately names a different parent from this cache.
        CostUsageScanner.applyFileDays(cache: &cache, fileDays: child.days, sign: -1)
        let staleDays = [dayKey: ["stale-partial": [777, 0, 0]]]
        child.days = staleDays
        CostUsageScanner.applyFileDays(cache: &cache, fileDays: staleDays, sign: 1)
        child.forkedFromId = "stale-missing-parent"
        child.codexForkTimestamp = forkTimestamp
        child.forkBaselineDependencyKey = "missing|stale-missing-parent|seed"
        if var session = child.codexSession {
            session.forkedFromId = "stale-missing-parent"
            child.codexSession = session
        }
        let replayStarted = mutation == .appendDuringReplay
        child.codexDeferredReplayState = CostUsageCodexDeferredReplayState(
            phase: .replaying,
            mode: .unresolvedFork,
            ownedSuffixStartOffset: nil,
            rawTotalsBaseline: nil,
            parentTotalsAtBoundary: nil,
            legacySubagentShape: nil,
            replayStarted: replayStarted)
        child.codexDeferredForkScan = nil
        child.codexScanComplete = false
        if replayStarted {
            let cursor = max(1, originalMetadata.size / 2)
            child.parsedBytes = cursor
            child.codexTokenIndexAnchor = CostUsageScanner.codexTokenIndexAnchor(
                fileURL: childURL,
                indexedBytes: cursor)
        } else {
            child.parsedBytes = originalMetadata.size
        }
        cache.files[childEntry.key] = child
        cache.codexScanCatchUpPending = true
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let expectedParent: String
        let expectedChildInput: Int
        switch mutation {
        case .appendBeforeReplay, .appendDuringReplay:
            let appended = Self.tokenLine(
                timestamp: childTimestamp,
                totalInput: 260,
                lastInput: 10) + "\n"
            let handle = try FileHandle(forWritingTo: childURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(appended.utf8))
            try handle.close()
            expectedParent = "live-parent"
            expectedChildInput = 60

        case .sameSizeRewrite:
            let rewrittenBody = originalChildBody.replacingOccurrences(
                of: #""forked_from_id":"live-parent""#,
                with: #""forked_from_id":"next-parent""#)
            #expect(rewrittenBody != originalChildBody)
            #expect(rewrittenBody.utf8.count == originalChildBody.utf8.count)
            let handle = try FileHandle(forWritingTo: childURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(rewrittenBody.utf8))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: originalModificationDate],
                ofItemAtPath: childURL.path)
            let rewrittenMetadata = CostUsageScanner.codexFileMetadata(fileURL: childURL)
            #expect(rewrittenMetadata.fileId == originalMetadata.fileId)
            #expect(rewrittenMetadata.size == originalMetadata.size)
            #expect(rewrittenMetadata.mtimeUnixMs == originalMetadata.mtimeUnixMs)
            #expect(rewrittenMetadata.changeUnixNs != originalMetadata.changeUnixNs)
            expectedParent = "next-parent"
            expectedChildInput = 30
        }

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(10),
            options: options)
        let resolvedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let resolved = try #require(
            resolvedCache.files.values.first { $0.sessionId == "ordinary-live-child" })

        #expect(resolved.forkedFromId == expectedParent)
        #expect(resolved.codexSession?.forkedFromId == expectedParent)
        #expect(resolved.forkBaselineDependencyKey?.hasPrefix("file|\(expectedParent)|") == true)
        #expect(resolved.codexDeferredReplayState == nil)
        #expect(resolved.codexScanComplete == true)
        #expect(resolved.days[dayKey]?[model] == [expectedChildInput, 0, 0])
        #expect(resolved.days[dayKey]?["stale-partial"] == nil)
        #expect(resolvedCache.days[dayKey]?["stale-partial"] == nil)
        #expect(recorder.snapshot().fileBodyBudgetBytesConsumed > 0)
        #expect(recorder.snapshot().fileParseInvocations > 0)
    }

    private static func tokenLine(timestamp: String, totalInput: Int, lastInput: Int) -> String {
        // swiftlint:disable:next line_length
        #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"model":"openai/gpt-5.4","total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":\#(lastInput),"cached_input_tokens":0,"output_tokens":0}}}}"#
    }
}
