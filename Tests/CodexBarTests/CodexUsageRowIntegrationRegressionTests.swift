import Foundation
import Testing
@testable import CodexBarCore

// These integration gates intentionally keep each complete cold/warm/recovery sequence visible.
// swiftlint:disable function_body_length
@Suite(.serialized)
struct CodexUsageRowIntegrationRegressionTests {
    #if canImport(SQLite3)
    @Test
    func `sidecar row is repriced when its unchanged turn becomes priority`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let sessionID = "late-priority-sidecar-session"
        let turnID = "late-priority-turn"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "late-priority-sidecar.jsonl",
            contents: env.jsonl([
                Self.sessionMetadata(timestamp: timestamp, sessionID: sessionID),
                Self.turnContext(timestamp: timestamp, model: "gpt-5.5"),
                Self.taskStarted(timestamp: timestamp, turnID: turnID),
                Self.tokenCount(timestamp: timestamp, input: 100, cached: 20, output: 10),
            ]))
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: fileURL.path)

        // The trace DB must exist during both scans. Creating it only after the cold scan changes
        // the metadata source from `missing:` to `sqlite:` and exercises the coarse full-rescan
        // invalidation instead of the changed-turn-ID path covered here.
        let traceURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: traceURL)
        var options = Self.options(env: env, traceURL: traceURL)

        let standardReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let standardBreakdown = try #require(standardReport.data.first?.modelBreakdowns?.first)
        #expect(standardBreakdown.totalTokens == 110)
        // The public report exposes the standard/priority split only after a priority bucket
        // exists; an all-standard report keeps the legacy unsplit presentation.
        #expect(standardBreakdown.standardTokens == nil)
        #expect(standardBreakdown.priorityTokens == nil)

        let standardCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let standardUsage = try #require(
            standardCache.files.values.first(where: { $0.sessionId == sessionID }))
        let standardRowState = try #require(standardUsage.codexUsageRowSidecarState)
        #expect(standardUsage.codexRows == nil)
        #expect(standardUsage.codexTurnIDs == nil)
        #expect(standardRowState.rowCount == 1)

        try CostUsageScannerCodexPriorityTests.insertTestLog(
            dbURL: traceURL,
            timestamp: timestamp,
            body: "thread_id=late-priority-thread turn.id=\(turnID) websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let priorityReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let metrics = recorder.snapshot()
        let priorityBreakdown = try #require(priorityReport.data.first?.modelBreakdowns?.first)

        #expect((priorityBreakdown.standardTokens ?? 0) == 0)
        #expect(priorityBreakdown.priorityTokens == 110)
        #expect((priorityBreakdown.priorityCostUSD ?? 0) > (standardBreakdown.costUSD ?? 0))
        #expect(priorityReport.summary?.totalTokens == standardReport.summary?.totalTokens)
        // Repricing uses the published row-sidecar reference; unchanged JSONL must not be read.
        #expect(metrics.fileBodyBudgetBytesConsumed == 0)
        #expect(metrics.fileParseInvocations == 0)
        #expect(metrics.usageRowsRead == 1)
        #expect(metrics.usageRowsRepriced == 1)

        let priorityCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let priorityUsage = try #require(
            priorityCache.files.values.first(where: { $0.sessionId == sessionID }))
        let priorityRowState = try #require(priorityUsage.codexUsageRowSidecarState)
        #expect(priorityUsage.codexRows == nil)
        #expect(priorityUsage.codexTurnIDs == nil)
        #expect(priorityRowState.rowCount == standardRowState.rowCount)
        #expect(priorityRowState.prefixDigest != standardRowState.prefixDigest)
    }
    #endif

    @Test
    func `narrow request appends to a wider row sidecar without resetting its cursor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let wideSince = try #require(Calendar.current.date(byAdding: .day, value: -29, to: day))
        let narrowSince = try #require(Calendar.current.date(byAdding: .day, value: -6, to: day))
        let timestamp = env.isoString(for: day)
        let sessionID = "wide-to-narrow-append-session"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "wide-to-narrow-append.jsonl",
            contents: env.jsonl([
                Self.sessionMetadata(timestamp: timestamp, sessionID: sessionID),
                Self.turnContext(timestamp: timestamp, model: "gpt-5.5"),
                Self.taskStarted(timestamp: timestamp, turnID: "wide-to-narrow-turn"),
                Self.tokenCount(timestamp: timestamp, input: 100, cached: 20, output: 10),
            ]))
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: fileURL.path)

        var options = Self.options(env: env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: wideSince,
            until: day,
            now: day,
            options: options)
        let wideCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let wideUsage = try #require(
            wideCache.files.values.first(where: { $0.sessionId == sessionID }))
        let wideState = try #require(wideUsage.codexUsageRowSidecarState)
        let publishedOffset = try #require(wideUsage.parsedBytes)
        #expect(wideUsage.codexScanComplete == true)
        #expect(publishedOffset == wideUsage.size)

        let narrowWarmRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = narrowWarmRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: narrowSince,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(narrowWarmRecorder.snapshot().fileBodyBudgetBytesConsumed == 0)

        let narrowWarmCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let narrowWarmUsage = try #require(
            narrowWarmCache.files.values.first(where: { $0.sessionId == sessionID }))
        #expect(narrowWarmUsage.parsedBytes == publishedOffset)
        #expect(narrowWarmUsage.codexUsageRowSidecarState?.coverageSinceKey == wideState.coverageSinceKey)
        #expect(narrowWarmUsage.codexUsageRowSidecarState?.coverageUntilKey == wideState.coverageUntilKey)

        try Self.appendJSONLines(
            [
                Self.tokenCount(timestamp: timestamp, input: 7, cached: 0, output: 3),
            ],
            env: env,
            to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: fileURL.path)
        let appendedSize = CostUsageScanner.codexFileMetadata(fileURL: fileURL).size
        #expect(appendedSize > publishedOffset)

        let appendRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = appendRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: narrowSince,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let appendMetrics = appendRecorder.snapshot()
        let appendedCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let appendedUsage = try #require(
            appendedCache.files.values.first(where: { $0.sessionId == sessionID }))
        let appendedState = try #require(appendedUsage.codexUsageRowSidecarState)

        #expect(appendMetrics.fileParseInvocations == 1)
        #expect(appendMetrics.fileBodyBudgetBytesConsumed == appendedSize - publishedOffset)
        #expect(appendMetrics.fileBodyBudgetBytesConsumed < publishedOffset)
        #expect(appendedUsage.parsedBytes == appendedSize)
        #expect((appendedUsage.parsedBytes ?? 0) >= publishedOffset)
        #expect(appendedUsage.codexScanComplete == true)
        #expect(appendedState.rowCount == wideState.rowCount + 1)
        #expect(appendedState.coverageSinceKey == wideState.coverageSinceKey)
        #expect(appendedState.coverageUntilKey == wideState.coverageUntilKey)
        #expect(appendedCache.codexScanCatchUpPending != true)
    }

    @Test
    func `unchanged ownership projection stays at EOF after monotonic bounded catch up`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let sessionID = "bounded-ownership-session"
        var preferredBody: [[String: Any]] = [
            Self.sessionMetadata(timestamp: timestamp, sessionID: sessionID),
            Self.turnContext(timestamp: timestamp, model: "gpt-5.5"),
            Self.taskStarted(timestamp: timestamp, turnID: "bounded-ownership-turn"),
            Self.tokenCount(timestamp: timestamp, input: 100, cached: 20, output: 10),
        ]
        // The projected source contains one row also present in the preferred source plus one
        // genuinely distinct row. Keeping a non-empty effective projection prevents the duplicate
        // cleanup path from deleting it while its large body advances across bounded slices.
        var projectedBody = preferredBody
        projectedBody.append(Self.tokenCount(timestamp: timestamp, input: 7, cached: 0, output: 3))
        let padding = String(repeating: "x", count: 1024)
        for index in 0..<96 {
            let paddingEvent: [String: Any] = [
                "type": "event_msg",
                "timestamp": timestamp,
                "payload": [
                    "type": "agent_message",
                    "message": "padding-\(index)-\(padding)",
                ],
            ]
            preferredBody.append(paddingEvent)
            projectedBody.append(paddingEvent)
        }

        let preferredURL = try env.writeCodexSessionFile(
            day: day,
            filename: "bounded-ownership-preferred.jsonl",
            contents: env.jsonl(preferredBody))
        let projectedURL = try env.writeCodexSessionFile(
            day: day,
            filename: "bounded-ownership-projected.jsonl",
            contents: env.jsonl(projectedBody))
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: preferredURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: projectedURL.path)

        var options = Self.options(env: env, maxFileBytes: 8 * 1024)
        var ownershipPath: String?
        var observedOffsets: [Int64] = []
        var completedUsage: CostUsageFileUsage?
        for pass in 0..<64 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            let cache = CostUsageCacheIO.load(
                provider: .codex,
                cacheRoot: env.cacheRoot,
                calendar: options.calendar)
            guard let entry = cache.files
                .filter({
                    $0.value.sessionId == sessionID
                        && $0.value.codexUsageRowSidecarState?.ownershipKey != nil
                })
                .min(by: { $0.key < $1.key })
            else { continue }

            if let ownershipPath {
                #expect(entry.key == ownershipPath)
            } else {
                ownershipPath = entry.key
            }
            let offset = entry.value.parsedBytes ?? 0
            if let previous = observedOffsets.last {
                #expect(offset >= previous)
            }
            observedOffsets.append(offset)
            if entry.value.codexScanComplete == true,
               offset == entry.value.size,
               cache.codexScanCatchUpPending != true
            {
                completedUsage = entry.value
                break
            }
        }

        let complete = try #require(completedUsage)
        let completedPath = try #require(ownershipPath)
        #expect(observedOffsets.count >= 3)
        #expect(Set(observedOffsets).count >= 3)
        #expect(complete.codexUsageRowSidecarState?.ownershipKey != nil)
        #expect(complete.codexScanComplete == true)
        #expect(complete.parsedBytes == complete.size)

        let stableRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = stableRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1000),
            options: options)
        let stableMetrics = stableRecorder.snapshot()
        let stableCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let stable = try #require(stableCache.files[completedPath])

        #expect(stableMetrics.fileBodyBudgetBytesConsumed == 0)
        #expect(stableMetrics.fileParseInvocations == 0)
        #expect(stableMetrics.usageRowsRead == 0)
        #expect(stableMetrics.usageRowDeltaProcessed == 0)
        #expect(stableMetrics.usageRowsWritten == 0)
        #expect(stableMetrics.usageRowsRepriced == 0)
        #expect(stableMetrics.usageRowsFingerprintHashed == 0)
        #expect(stable.parsedBytes == complete.parsedBytes)
        #expect(stable.parsedBytes == stable.size)
        #expect(stable.codexScanComplete == true)
        #expect(stable.codexUsageRowSidecarState?.generation == complete.codexUsageRowSidecarState?.generation)
        #expect(stable.codexUsageRowSidecarState?.prefixDigest == complete.codexUsageRowSidecarState?.prefixDigest)
        #expect(stableCache.codexScanCatchUpPending != true)

        // An ownership key intentionally covers every physical source for the logical session.
        // Mutating one source therefore invalidates the projection and takes the conservative
        // byte-zero reconciliation path. Keep this boundary explicit: relaxing it to a suffix
        // append without an owner-migration protocol can double count a row that also appears in
        // a sibling source, especially when newest-first ordering changes after the append.
        let completedURL = URL(fileURLWithPath: completedPath)
        try Self.appendJSONLines(
            [
                Self.tokenCount(timestamp: timestamp, input: 11, cached: 0, output: 5),
            ],
            env: env,
            to: completedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(2000)],
            ofItemAtPath: completedURL.path)
        let appendedSize = CostUsageScanner.codexFileMetadata(fileURL: completedURL).size
        #expect(appendedSize > complete.size)

        let reconciliationRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = reconciliationRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2001),
            options: options)
        let reconciliationMetrics = reconciliationRecorder.snapshot()
        let reconciliationCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let firstReconciliation = try #require(reconciliationCache.files[completedPath])
        let firstReconciliationOffset = try #require(firstReconciliation.parsedBytes)

        #expect(reconciliationMetrics.fileParseInvocations == 1)
        #expect(reconciliationMetrics.fileBodyBudgetBytesConsumed == 8 * 1024)
        #expect(firstReconciliationOffset == Int64(8 * 1024))
        #expect(firstReconciliationOffset < complete.size)
        #expect(firstReconciliation.codexScanComplete == false)
        #expect(reconciliationCache.codexScanCatchUpPending == true)

        var reconciliationOffset = firstReconciliationOffset
        var reconciledUsage: CostUsageFileUsage?
        var reconciledReport: CostUsageDailyReport?
        var reconciledCache: CostUsageCache?
        for pass in 0..<64 {
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(2002 + pass)),
                options: options)
            let cache = CostUsageCacheIO.load(
                provider: .codex,
                cacheRoot: env.cacheRoot,
                calendar: options.calendar)
            let usage = try #require(cache.files[completedPath])
            let offset = try #require(usage.parsedBytes)
            #expect(offset >= reconciliationOffset)
            reconciliationOffset = offset
            if usage.codexScanComplete == true,
               offset == appendedSize,
               cache.codexScanCatchUpPending != true
            {
                reconciledUsage = usage
                reconciledReport = report
                reconciledCache = cache
                break
            }
        }

        let reconciled = try #require(reconciledUsage)
        let report = try #require(reconciledReport)
        let finalCache = try #require(reconciledCache)
        #expect(reconciled.parsedBytes == appendedSize)
        // The append makes this source newest, so ownership may move to its sibling. Exactly one
        // projected source must remain instead of requiring the old physical owner to keep the key.
        #expect(finalCache.files.values.count(where: {
            $0.sessionId == sessionID && $0.codexUsageRowSidecarState?.ownershipKey != nil
        }) == 1)
        #expect(report.summary?.totalTokens == 136)
    }

    @Test
    func `compatible predecessor row generation remains readable after cache producer migration`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let sessionID = "predecessor-stable-row-generation"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "predecessor-stable-row-generation.jsonl",
            contents: env.jsonl([
                Self.sessionMetadata(timestamp: timestamp, sessionID: sessionID),
                Self.turnContext(timestamp: timestamp, model: "gpt-5.5"),
                Self.taskStarted(timestamp: timestamp, turnID: "predecessor-stable-turn"),
                Self.tokenCount(timestamp: timestamp, input: 100, cached: 20, output: 10),
            ]))
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: fileURL.path)
        var options = Self.options(env: env)

        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        var predecessorCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let entry = try #require(predecessorCache.files.first(where: { $0.value.sessionId == sessionID }))
        let predecessorProducerKey = "codex:cu:pcdc205df2dba1a53"
        let predecessorState = try Self.replacePublishedRowGeneration(
            path: entry.key,
            usage: entry.value,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar,
            producerKey: predecessorProducerKey)
        predecessorCache.files[entry.key]?.codexUsageRowSidecarState = predecessorState
        predecessorCache.files[entry.key]?.codexUsageRowProducerKey = nil
        CostUsageCacheIO.save(
            provider: .codex,
            cache: predecessorCache,
            cacheRoot: env.cacheRoot,
            producerKey: predecessorProducerKey,
            calendar: options.calendar)

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let migratedReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let metrics = recorder.snapshot()
        let migratedCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let migratedUsage = try #require(migratedCache.files[entry.key])

        #expect(migratedReport.data == baseline.data)
        #expect(migratedReport.summary == baseline.summary)
        #expect(metrics.fileBodyBudgetBytesConsumed == 0)
        #expect(metrics.fileParseInvocations == 0)
        #expect(metrics.usageRowsRead == 0)
        #expect(metrics.usageRowsWritten == 0)
        #expect(migratedCache.producerKey == CostUsageCacheIO.currentProducerKey(provider: .codex))
        #expect(migratedUsage.codexUsageRowSidecarState == predecessorState)
        #expect(migratedUsage.codexUsageRowProducerKey == predecessorProducerKey)
        #expect(try CodexPublishedUsageRowsTestSupport.load(
            path: entry.key,
            usage: migratedUsage,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar).count == 1)

        let workspace = CodexWorkspaceUsageSidecar(cacheRoot: env.cacheRoot)
        try workspace.synchronizeSources(cache: migratedCache, catalog: .empty)
        let imported = try #require(
            workspace.usageCache(roots: migratedCache.roots ?? [:]).files[entry.key]?.codexRows)
        #expect(imported.count == 1)
        #expect(imported.first?.input == 100)
    }

    @Test
    func `append migrates predecessor row generation without rereading JSON prefix`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let timestamp = env.isoString(for: day)
        let sessionID = "predecessor-append-row-generation"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "predecessor-append-row-generation.jsonl",
            contents: env.jsonl([
                Self.sessionMetadata(timestamp: timestamp, sessionID: sessionID),
                Self.turnContext(timestamp: timestamp, model: "gpt-5.5"),
                Self.taskStarted(timestamp: timestamp, turnID: "predecessor-append-turn"),
                Self.tokenCount(timestamp: timestamp, input: 100, cached: 20, output: 10),
            ]))
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: fileURL.path)
        var options = Self.options(env: env)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        var predecessorCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let entry = try #require(predecessorCache.files.first(where: { $0.value.sessionId == sessionID }))
        let predecessorProducerKey = "codex:cu:pcdc205df2dba1a53"
        let predecessorState = try Self.replacePublishedRowGeneration(
            path: entry.key,
            usage: entry.value,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar,
            producerKey: predecessorProducerKey)
        predecessorCache.files[entry.key]?.codexUsageRowSidecarState = predecessorState
        predecessorCache.files[entry.key]?.codexUsageRowProducerKey = nil
        CostUsageCacheIO.save(
            provider: .codex,
            cache: predecessorCache,
            cacheRoot: env.cacheRoot,
            producerKey: predecessorProducerKey,
            calendar: options.calendar)

        // First publish the entry-scoped predecessor producer without touching the JSONL body.
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let migratedCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let migratedUsage = try #require(migratedCache.files[entry.key])
        let prefixBytes = try #require(migratedUsage.parsedBytes)
        #expect(migratedUsage.codexUsageRowProducerKey == predecessorProducerKey)

        try Self.appendJSONLines(
            [
                Self.tokenCount(timestamp: timestamp, input: 7, cached: 0, output: 3),
            ],
            env: env,
            to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(2)],
            ofItemAtPath: fileURL.path)
        let appendedSize = CostUsageScanner.codexFileMetadata(fileURL: fileURL).size

        let appendRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = appendRecorder
        let appendedReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let appendMetrics = appendRecorder.snapshot()
        let appendedCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let appendedUsage = try #require(appendedCache.files[entry.key])
        let appendedState = try #require(appendedUsage.codexUsageRowSidecarState)

        #expect(appendMetrics.fileParseInvocations == 1)
        #expect(appendMetrics.fileBodyBudgetBytesConsumed == appendedSize - prefixBytes)
        #expect(appendMetrics.fileBodyBudgetBytesConsumed < prefixBytes)
        #expect(appendMetrics.usageRowsRead == 1)
        #expect(appendMetrics.usageRowsWritten == 2)
        #expect(appendedUsage.parsedBytes == appendedSize)
        #expect(appendedUsage.codexScanComplete == true)
        #expect(appendedState.generation != predecessorState.generation)
        #expect(appendedState.rowCount == 2)
        #expect(appendedUsage.codexUsageRowProducerKey
            == CostUsageCacheIO.currentProducerKey(provider: .codex))

        var controlOptions = options
        controlOptions.codexScanWorkRecorderForTesting = nil
        controlOptions.cacheRoot = env.root.appendingPathComponent("predecessor-append-control")
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: controlOptions)
        #expect(appendedReport.data == control.data)
        #expect(appendedReport.summary == control.summary)

        let stableRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = stableRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        let stableMetrics = stableRecorder.snapshot()
        let stableCache = CostUsageCacheIO.load(
            provider: .codex,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let stableUsage = try #require(stableCache.files[entry.key])
        #expect(stableMetrics.fileBodyBudgetBytesConsumed == 0)
        #expect(stableMetrics.fileParseInvocations == 0)
        #expect(stableMetrics.usageRowsRead == 0)
        #expect(stableMetrics.usageRowsWritten == 0)
        #expect(stableUsage.codexUsageRowSidecarState == appendedState)
    }

    private static func options(
        env: CostUsageTestEnvironment,
        traceURL: URL? = nil,
        maxFileBytes: Int64 = 0) -> CostUsageScanner.Options
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: traceURL ?? env.root.appendingPathComponent("missing-trace.sqlite"),
            calendar: .current,
            forceRescan: false,
            maxCodexSessionFileBytes: maxFileBytes,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: nil,
            preferNewestCodexSessionsFirst: true)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func replacePublishedRowGeneration(
        path: String,
        usage: CostUsageFileUsage,
        cacheRoot: URL,
        calendar: Calendar,
        producerKey: String) throws -> CostUsageCodexUsageRowSidecarState
    {
        let state = try #require(usage.codexUsageRowSidecarState)
        let fileId = try #require(usage.codexScanFileId)
        let anchor = try #require(usage.codexTokenIndexAnchor)
        let rows = try CodexPublishedUsageRowsTestSupport.load(
            path: path,
            usage: usage,
            cacheRoot: cacheRoot,
            calendar: calendar)
        let records = try #require(CostUsageScanner.codexUsageRowRecords(
            rows: rows,
            sessionId: usage.sessionId,
            fileIdentity: path))
        let source = CostUsageCodexUsageRowSource(
            path: CostUsageCodexUsageRowStore.sourcePath(for: URL(fileURLWithPath: path)),
            fileId: fileId,
            indexedBytes: usage.parsedBytes ?? usage.size,
            anchor: anchor,
            isComplete: usage.codexScanComplete != false,
            changeUnixNs: usage.codexScanChangeUnixNs,
            sessionId: usage.sessionId,
            forkedFromId: usage.forkedFromId,
            forkDependencyKey: usage.forkBaselineDependencyKey,
            producerKey: producerKey,
            timeZoneIdentifier: calendar.timeZone.identifier)
        let reference = try CostUsageCodexUsageRowStore(cacheRoot: cacheRoot).createGeneration(
            source: source,
            records: records,
            nextUsageRowIndex: state.nextUsageRowIndex,
            coverageSinceKey: state.coverageSinceKey,
            coverageUntilKey: state.coverageUntilKey,
            ownershipKey: state.ownershipKey,
            pricingKey: state.pricingKey,
            priorityMetadataKey: state.priorityMetadataKey)
        return reference.state
    }

    private static func sessionMetadata(timestamp: String, sessionID: String) -> [String: Any] {
        [
            "type": "session_meta",
            "timestamp": timestamp,
            "payload": ["session_id": sessionID],
        ]
    }

    private static func turnContext(timestamp: String, model: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": ["model": model],
        ]
    }

    private static func taskStarted(timestamp: String, turnID: String) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "task_started",
                "turn_id": turnID,
            ],
        ]
    }

    private static func tokenCount(
        timestamp: String,
        input: Int,
        cached: Int,
        output: Int) -> [String: Any]
    {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                    ],
                ],
            ],
        ]
    }

    private static func appendJSONLines(
        _ entries: [[String: Any]],
        env: CostUsageTestEnvironment,
        to fileURL: URL) throws
    {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + env.jsonl(entries)).utf8))
    }
}

// swiftlint:enable function_body_length
