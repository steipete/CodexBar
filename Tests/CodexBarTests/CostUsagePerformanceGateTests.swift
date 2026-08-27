// swiftlint:disable file_length
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

// The performance corpus and its fixtures intentionally stay together so timing gates share setup.

/// Regression gates for the two cost-usage scan-storm classes that have shipped before:
/// re-parsing unchanged session files on every refresh (#1387, #1392) and re-running the
/// full trace-database scan on every refresh (#1392, the pre-memo priority-turns path).
@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct CostUsagePerformanceGateTests {
    @Test
    func `time limited codex catch-up bounds oversized active day discovery`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        CostUsageScanner.resetCodexDirectoryCursorsForTesting()
        defer { CostUsageScanner.resetCodexDirectoryCursorsForTesting() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = 1500
        let candidateLimit = CostUsageScanner.codexCatchUpScanCandidateLimit
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: corpusSize,
            turnsPerFile: 1)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0

        let firstRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = firstRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstMetrics = firstRecorder.snapshot()
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        print(
            "[discovery-proof] first=\(firstCache.files.count), "
                + "discovery=\(firstMetrics.codexDiscoveryVisits), "
                + "attempts=\(firstMetrics.codexFileScanAttempts)")

        #expect(firstMetrics.codexDiscoveryVisits == candidateLimit)
        #expect(firstMetrics.codexFileScanAttempts == candidateLimit)
        #expect(firstCache.files.count == candidateLimit)
        #expect(firstCache.codexScanCatchUpPending == true)

        CostUsageScanner.resetCodexDirectoryCursorsForTesting()
        let relaunchedRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = relaunchedRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let relaunchedMetrics = relaunchedRecorder.snapshot()
        let relaunchedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        print(
            "[discovery-proof] relaunched=\(relaunchedCache.files.count), "
                + "discovery=\(relaunchedMetrics.codexDiscoveryVisits), "
                + "attempts=\(relaunchedMetrics.codexFileScanAttempts)")

        #expect(relaunchedMetrics.codexDiscoveryVisits == candidateLimit)
        #expect(relaunchedMetrics.codexFileScanAttempts == 0)
        #expect(relaunchedCache.files.count == candidateLimit)
        #expect(relaunchedCache.codexScanCatchUpPending == true)

        let secondRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = secondRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondMetrics = secondRecorder.snapshot()
        let secondCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        print(
            "[discovery-proof] second=\(secondCache.files.count), "
                + "discovery=\(secondMetrics.codexDiscoveryVisits), "
                + "visits=\(secondMetrics.codexCandidateSelectionVisits), "
                + "attempts=\(secondMetrics.codexFileScanAttempts), "
                + "accounting=\(secondMetrics.codexProgressAccountingVisits)")

        #expect(secondMetrics.codexDiscoveryVisits == candidateLimit)
        #expect(secondMetrics.codexCandidateSelectionVisits == candidateLimit)
        #expect(secondMetrics.codexFileScanAttempts == candidateLimit)
        #expect(secondMetrics.codexProgressAccountingVisits == 0)
        #expect(secondCache.files.count == candidateLimit * 2)
        #expect(secondCache.codexScanCatchUpPending == true)
    }

    @Test
    func `warm codex refresh indexes cache aliases once at incident corpus scale`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = 1500
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: corpusSize,
            turnsPerFile: 1)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let started = ContinuousClock.now
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let elapsed = ContinuousClock.now - started
        let metrics = recorder.snapshot()

        // The cache identity index may inspect only the matching identity bucket per file.
        // With unique files that is one candidate per lookup, not corpusSize² cache visits.
        #expect(metrics.cacheAliasEntriesIndexed == corpusSize)
        #expect(metrics.cacheAliasLookups == corpusSize)
        #expect(metrics.cacheAliasCandidatesVisited == corpusSize)
        #expect(metrics.usageRowsProcessed == 0)
        #expect(elapsed < TestTimingBudget.scaled(.seconds(10)))
        let elapsedComponents = elapsed.components
        let elapsedMilliseconds = elapsedComponents.seconds * 1000
            + elapsedComponents.attoseconds / 1_000_000_000_000_000
        print(
            "[alias-index-proof] warm refresh \(corpusSize) files: \(elapsedMilliseconds) ms, "
                + "lookups=\(metrics.cacheAliasLookups), candidates=\(metrics.cacheAliasCandidatesVisited)")
    }

    @Test
    func `warm codex refresh over an unchanged session corpus must not re-parse it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let fileURLs = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 2, turnsPerFile: 4)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let changedFile = try #require(fileURLs.first)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: changedFile.path)
        let originalModificationDate = try #require(originalAttributes[.modificationDate] as? Date)
        let original = try String(contentsOf: changedFile, encoding: .utf8)
        let modified = original.replacingOccurrences(
            of: #""input_tokens":100,"#,
            with: #""input_tokens":900,"#)
        #expect(modified != original)
        #expect(modified.utf8.count == original.utf8.count)
        try modified.write(to: changedFile, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: changedFile.path)

        let warm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(cold.data.count == 1)
        #expect(warm.data.first?.totalTokens == cold.data.first?.totalTokens)
    }

    @Test
    func `identical refresh advances the scan timestamp without rewriting content tables`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 2, turnsPerFile: 4)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        // Always refresh so the second pass rescans the unchanged corpus instead of debouncing.
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let dbURL = store.databaseURL
        func fileSize(_ url: URL) -> Int64? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return (attributes[.size] as? NSNumber)?.int64Value
        }

        let dbSizeBefore = fileSize(dbURL)
        let stampBefore = store.syncLoadCodexCache(calendar: .current).lastScanUnixMs

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(60),
            options: options)
        #expect(second.data.first?.totalTokens == first.data.first?.totalTokens)

        // The identical pass advances the durable timestamp but leaves the content tables alone,
        // so refresh debounce survives cache reloads instead of rescanning every interval.
        let stampAfter = store.syncLoadCodexCache(calendar: .current).lastScanUnixMs
        #expect(stampAfter > stampBefore)
        #expect(fileSize(dbURL) == dbSizeBefore)
        #expect(store.syncLoadCodexCache(calendar: .current).files.count == 2)

        // A later cycle inside the debounce window skips the rescan and any save entirely.
        options.refreshMinIntervalSeconds = 300
        let debounced = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(120),
            options: options)
        #expect(debounced.data.first?.totalTokens == first.data.first?.totalTokens)
        #expect(store.syncLoadCodexCache(calendar: .current).lastScanUnixMs == stampAfter)
        #expect(fileSize(dbURL) == dbSizeBefore)
    }

    @Test(.timeLimit(.minutes(2)))
    func `scanner only identical save stays bounded at corpus scale`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fileCount = 200
        let recordsPerFile = 100
        let recordCount = fileCount * recordsPerFile
        var cache = Self.persistenceScaleCache(files: fileCount, recordsPerFile: recordsPerFile)
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let window = (sinceKey: "2026-08-01", untilKey: "2026-08-01")
        _ = store.syncSaveCodexCache(cache, calendar: .current, requestedScanWindow: window)
        #expect(await store.setWALAutoCheckpointForTesting(0))
        #expect(await store.truncateWALForTesting())

        let seeded = await store.readSnapshot()
        #expect(seeded.files.count == fileCount)
        #expect(seeded.usageRows.count == recordCount)
        #expect(seeded.tokenSnapshots.count == recordCount)
        #expect(cache.files.keys.allSatisfy { !FileManager.default.fileExists(atPath: $0) })

        struct Footprint: CustomStringConvertible {
            var databaseBytes: Int64
            var walBytes: Int64
            var databaseMtime: TimeInterval?
            var walMtime: TimeInterval?

            var description: String {
                "dbBytes=\(self.databaseBytes) walBytes=\(self.walBytes) "
                    + "dbMtime=\(self.databaseMtime ?? -1) walMtime=\(self.walMtime ?? -1)"
            }
        }

        let databaseURL = store.databaseURL
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        func footprint() -> Footprint {
            func values(_ url: URL) -> (Int64, TimeInterval?) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (
                    (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                    (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970)
            }
            let database = values(databaseURL)
            let wal = values(walURL)
            return Footprint(
                databaseBytes: database.0,
                walBytes: wal.0,
                databaseMtime: database.1,
                walMtime: wal.1)
        }

        func measure(_ operation: () -> Void) -> (elapsed: Double, cpu: Double) {
            let elapsedStart = ProcessInfo.processInfo.systemUptime
            let cpuStart = clock()
            operation()
            return (
                elapsed: ProcessInfo.processInfo.systemUptime - elapsedStart,
                cpu: Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC))
        }

        cache.lastScanUnixMs += 1
        _ = await store.persistenceWriteMetricsForTesting(resetPageCounter: true)
        let fullCountersBefore = await store.persistenceWriteMetricsForTesting()
        let fullBefore = footprint()
        let fullTiming = measure {
            _ = store.syncSaveCodexCache(cache, calendar: .current, requestedScanWindow: window)
        }
        let fullAfter = footprint()
        let fullCountersAfter = await store.persistenceWriteMetricsForTesting(resetPageCounter: true)
        let fullRows = fullCountersAfter.rows - fullCountersBefore.rows

        var unchanged = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        unchanged.lastScanUnixMs += 1
        #expect(await store.truncateWALForTesting())
        _ = await store.persistenceWriteMetricsForTesting(resetPageCounter: true)
        let noOpCountersBefore = await store.persistenceWriteMetricsForTesting()
        let noOpBefore = footprint()
        let noOpTiming = measure {
            _ = store.syncSaveCodexCache(
                unchanged,
                calendar: .current,
                requestedScanWindow: window,
                skipIdenticalContent: true)
        }
        let noOpAfter = footprint()
        let noOpCountersAfter = await store.persistenceWriteMetricsForTesting(resetPageCounter: true)
        let noOpRows = noOpCountersAfter.rows - noOpCountersBefore.rows

        #expect(noOpRows == 1)
        #expect(fullRows > noOpRows)
        #expect(noOpCountersAfter.pages <= 2)
        // Equality is intentionally O(cache rows), not O(files): current main's stable full
        // save already reuses row payloads, so the semantic comparison can cost more CPU while
        // still eliminating almost all writes. Keep that cost bounded without claiming it is free.
        #expect(noOpTiming.elapsed < 3)
        #expect(noOpTiming.cpu < 3)
        #expect(noOpAfter.databaseBytes == noOpBefore.databaseBytes)
        #expect(noOpAfter.walBytes > 0)

        let scanDay = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: scanDay,
            files: fileCount,
            turnsPerFile: 1)
        var scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("scanner-cache", isDirectory: true),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        scannerOptions.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: scanDay,
            until: scanDay,
            now: scanDay,
            options: scannerOptions)
        let headVisits = HeadParseCounter()
        let warmScannerTiming = measure {
            _ = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
                headVisits.increment()
            } operation: {
                CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: scanDay,
                    until: scanDay,
                    now: scanDay.addingTimeInterval(1),
                    options: scannerOptions)
            }
        }
        #expect(headVisits.value == 0)
        #expect(warmScannerTiming.elapsed < 3)
        print("[scale-write-proof] files=\(fileCount) rows=\(recordCount) snapshots=\(recordCount)")
        print("[scale-write-proof] full elapsed=\(fullTiming.elapsed) cpu=\(fullTiming.cpu) "
            + "logicalRows=\(fullRows) pages=\(fullCountersAfter.pages) before={\(fullBefore)} after={\(fullAfter)}")
        print("[scale-write-proof] noOp elapsed=\(noOpTiming.elapsed) cpu=\(noOpTiming.cpu) "
            + "logicalRows=\(noOpRows) pages=\(noOpCountersAfter.pages) before={\(noOpBefore)} after={\(noOpAfter)}")
        print("[scale-visit-proof] files=\(fileCount) headVisits=\(headVisits.value) "
            + "elapsed=\(warmScannerTiming.elapsed) cpu=\(warmScannerTiming.cpu)")
    }

    @Test(arguments: ["43609cc56f76a003", "c6c46a376ba16304"])
    func `compatible predecessor store adoption performs zero session head parses`(predecessorHash: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 3, turnsPerFile: 2)
        let coldCacheRoot = env.root.appendingPathComponent("cold-cache", isDirectory: true)
        var coldOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: coldCacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        coldOptions.refreshMinIntervalSeconds = 0
        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: coldOptions)
        let cache = CostUsageStoreAccess.read(cacheRoot: coldCacheRoot, calendar: coldOptions.calendar)
        let predecessorStore = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: CostUsageStore.combinedSchemaVersion(
                base: CostUsageStore.baseSchemaVersion,
                parserHash: predecessorHash),
            parserHash: predecessorHash)
        _ = predecessorStore.syncSaveCodexCache(
            cache,
            calendar: coldOptions.calendar,
            requestedScanWindow: (
                sinceKey: CostUsageScanner.CostUsageDayRange.dayKey(from: day),
                untilKey: CostUsageScanner.CostUsageDayRange.dayKey(from: day)))

        var warmOptions = coldOptions
        warmOptions.cacheRoot = env.cacheRoot
        let counter = HeadParseCounter()
        let warm = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            counter.increment()
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: warmOptions)
        }

        #expect(counter.value == 0)
        #expect(warm.data == cold.data)
        #expect(warm.summary == cold.summary)
    }

    @Test
    func `over budget prune retains stale coverage file modified inside the window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let oldDay = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let windowStart = try env.makeLocalNoon(year: 2026, month: 7, day: 27)
        let windowDay = try env.makeLocalNoon(year: 2026, month: 8, day: 2)
        let oldISO = env.isoString(for: oldDay)

        // One still-active session whose usage rows are all out of window, plus idle stale
        // sessions. The active file lives in the scanned window's directory and keeps an
        // in-window mtime, exactly like a session that stopped producing usage weeks ago.
        let activeURL = try env.writeCodexSessionFile(
            day: windowDay,
            filename: "stale-active.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(oldISO)","payload":{"session_id":"stale-active-session"}}"#,
                #"{"type":"turn_context","timestamp":"\#(oldISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(oldISO)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ].joined(separator: "\n") + "\n")
        try FileManager.default.setAttributes(
            [.modificationDate: windowDay],
            ofItemAtPath: activeURL.path)
        for index in 0..<30 {
            let idleURL = try env.writeCodexSessionFile(
                day: windowDay,
                filename: "idle-\(index).jsonl",
                contents: [
                    #"{"type":"session_meta","timestamp":"\#(oldISO)","payload":{"session_id":"idle-\#(index)"}}"#,
                    #"{"type":"event_msg","timestamp":"\#(oldISO)","payload":{"type":"token_count","info":"#
                        + #"{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":1},"#
                        + #""model":"openai/gpt-5.2-codex"}}}"#,
                ].joined(separator: "\n") + "\n")
            try FileManager.default.setAttributes(
                [.modificationDate: oldDay],
                ofItemAtPath: idleURL.path)
        }

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: windowDay,
            now: windowDay,
            options: options)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let activeFile = { (files: [CostUsageStoreFile]) -> CostUsageStoreFile? in
            files.first { $0.sessionID == "stale-active-session" }
        }
        let coldRow = try #require(await activeFile(store.readSnapshot().files))
        #expect(coldRow.scanState.isComplete)
        let coldAnchor = coldRow.anchor?.sha256
        let coldParsedBytes = coldRow.parsedBytes

        // Force the over-budget branch of the production save path: 31 retained files
        // exceed the 1-file row budget, so the window prune must run before the row cap.
        let budget = await store.enforceBudgets(
            maxRows: 1,
            maxFileBytes: .max,
            requestedSinceDay: Self.dayKeyString(for: windowStart),
            requestedUntilDay: Self.dayKeyString(for: windowDay),
            calendar: .current)
        #expect(budget.rowCount == 1)
        let retained = try #require(await activeFile(store.readSnapshot().files))
        #expect(retained.scanState.isComplete)
        #expect(retained.anchor?.sha256 == coldAnchor)
        print("[retention-proof] stale-coverage file retained after over-budget prune: \(retained.path)")

        let warmCounter = HeadParseCounter()
        _ = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            warmCounter.increment()
        } operation: {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: windowStart,
                until: windowDay,
                now: windowDay,
                options: options)
        }
        #expect(warmCounter.value == 0)
        let warmRow = try #require(await activeFile(store.readSnapshot().files))
        #expect(warmRow.anchor?.sha256 == coldAnchor)
        #expect(warmRow.parsedBytes == coldParsedBytes)
        print("[retention-proof] warm refresh reused the cached row, headParses=0")
    }

    @Test
    func `priority turns refresh must scan only appended trace rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)

        let epoch: Int64 = 1_760_000_000
        var rows: [(epochSeconds: Int64, body: String)] = (0..<50).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        }
        rows.append((
            epochSeconds: epoch,
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        let full = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(full.keys.sorted() == ["turn-a"])
        let scanned = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        try Self.replaceTraceBody(
            dbURL: dbURL,
            rowID: 1,
            body: "thread_id=mutated turn.id=mutated-old websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)])

        let refreshed = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(refreshed.keys.sorted() == ["turn-a", "turn-b"])
        let advanced = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(advanced.lastRowID == scanned.lastRowID + 1)
    }

    @Test
    func `cached daily report resolves and uses the pricing catalog once`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let model = "perf-custom-model"
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: 3,
            turnsPerFile: 4,
            model: model)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let catalogJSON = """
        {
          "openai": {
            "id": "openai",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": { "input": 10, "output": 50, "cache_read": 1 }
              }
            }
          }
        }
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(catalogJSON.utf8))
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let cachedUsage = try #require(cache.files.values.first { !($0.codexRows?.isEmpty ?? true) })
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        #expect(!CostUsageScanner.needsCodexPricingMetadata(cachedUsage, range: range))
        var catalogLoadCount = 0
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCacheRoot: env.cacheRoot,
            modelsDevCatalogLoader: { _ in
                catalogLoadCount += 1
                return catalog
            })

        #expect(report.summary?.totalCostUSD != nil)
        #expect(catalogLoadCount == 1)
    }

    @Test
    func `cached daily report resolves pricing once at read time`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 3, turnsPerFile: 4)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let scanned = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var catalogLoadCount = 0
        let cached = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            modelsDevCacheRoot: env.cacheRoot,
            modelsDevCatalogLoader: { _ in
                catalogLoadCount += 1
                return ModelsDevCatalog(providers: [:])
            })

        #expect(cached.data.map(\.totalTokens) == scanned.data.map(\.totalTokens))
        #expect(cached.summary?.totalTokens == scanned.summary?.totalTokens)
        #expect(abs((cached.summary?.totalCostUSD ?? 0) - (scanned.summary?.totalCostUSD ?? 0)) < 0.000000001)
        #expect(catalogLoadCount == 1)
    }

    @Test
    func `legacy missing aggregate cost backfills rows before threshold pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: 2,
            turnsPerFile: 1,
            model: "openai/gpt-5.5",
            inputTokensPerTurn: 200_000)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let scanned = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        for path in legacy.files.keys {
            legacy.files[path]?.codexCostCacheComplete = nil
            legacy.files[path]?.codexCostNanos = nil
            legacy.files[path]?.codexStandardCostNanos = nil
            legacy.files[path]?.codexPriorityCostNanos = nil
        }
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        #expect(legacy.files.values.allSatisfy { CostUsageScanner.needsCodexPricingMetadata($0, range: range) })

        let backfilled = CostUsageScanner.buildCodexReportFromCache(cache: legacy, range: range)

        #expect(abs((backfilled.summary?.totalCostUSD ?? 0) - (scanned.summary?.totalCostUSD ?? 0)) < 0.000000001)

        var mixed = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let mixedPaths = mixed.files.keys.sorted()
        let legacyPath = try #require(mixedPaths.first)
        let rowlessPath = try #require(mixedPaths.last)
        #expect(legacyPath != rowlessPath)
        mixed.files[legacyPath]?.codexCostCacheComplete = nil
        mixed.files[legacyPath]?.codexCostNanos = nil
        mixed.files[legacyPath]?.codexStandardCostNanos = nil
        mixed.files[legacyPath]?.codexPriorityCostNanos = nil
        mixed.files[rowlessPath]?.codexRows = nil

        let mixedBackfilled = CostUsageScanner.buildCodexReportFromCache(cache: mixed, range: range)
        #expect(mixedBackfilled.summary?.totalTokens == scanned.summary?.totalTokens)
        #expect(mixedBackfilled.summary?.totalCostUSD == nil)

        let aggregateCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 400_000,
            cachedInputTokens: 0,
            outputTokens: 20)
        #expect(abs((backfilled.summary?.totalCostUSD ?? 0) - (aggregateCost ?? 0)) > 0.1)
    }

    @Test
    func `project rollups resolve the pricing catalog once per build`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 3, turnsPerFile: 4)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var catalogLoadCount = 0
        let projects = CostUsageScanner.buildCodexProjectBreakdownsFromCache(
            cache: cache,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            modelsDevCacheRoot: env.cacheRoot,
            modelsDevCatalogLoader: { _ in
                catalogLoadCount += 1
                return ModelsDevCatalog(providers: [:])
            })

        #expect(!projects.isEmpty)
        #expect(catalogLoadCount == 1)
    }

    @Test
    func `oversized codex session is fully accounted across bounded refreshes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 8)
        let oversizedURL = try #require(files.first)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: oversizedURL)

        var baselineOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("baseline-cache"),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        baselineOptions.refreshMinIntervalSeconds = 0
        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: baselineOptions)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: max(1, metadata.size / 4),
            maxCodexScanBytesPerRefresh: max(1, metadata.size / 4))
        options.refreshMinIntervalSeconds = 0

        var offsets: [Int64] = []
        var report: CostUsageDailyReport?
        for _ in 0..<12 {
            report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
            let cached = try #require(CostUsageStoreAccess.read(
                cacheRoot: env.cacheRoot).files.values.first)
            offsets.append(cached.parsedBytes ?? 0)
            if cached.codexScanComplete == true {
                break
            }
        }

        #expect(offsets.count > 1)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(offsets.last == metadata.size)
        #expect(report?.summary?.totalTokens == baseline.summary?.totalTokens)
        #expect(report?.data.map(\.totalTokens) == baseline.data.map(\.totalTokens))
    }

    @Test
    func `oversized codex progress survives cache round trip`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 8)
        let fileURL = try #require(files.first)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let slice = max(1, metadata.size / 4)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: slice,
            maxCodexScanBytesPerRefresh: slice)
        options.refreshMinIntervalSeconds = 0
        options.maxCodexScanBytesPerRefresh += Self.codexLookbackDiscoveryWork(options: options)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let roundTripped = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let first = try #require(roundTripped.files.values.first)
        let firstOffset = try #require(first.parsedBytes)
        #expect(first.codexScanFileId == metadata.fileId)
        #expect(first.codexScanTargetSize == metadata.size)
        #expect(first.codexScanComplete == false)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let second = try #require(CostUsageStoreAccess.read(
            cacheRoot: env.cacheRoot).files.values.first)
        #expect((second.parsedBytes ?? 0) > firstOffset)
        #expect(second.codexScanFileId == metadata.fileId)
        #expect(second.codexScanTargetSize == metadata.size)
    }

    @Test
    func `oversized codex progress survives an append while catch-up is in progress`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 8)
        let fileURL = try #require(files.first)
        let originalMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let slice = max(1, originalMetadata.size / 4)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: slice,
            maxCodexScanBytesPerRefresh: slice)
        options.refreshMinIntervalSeconds = 0
        options.maxCodexScanBytesPerRefresh += Self.codexLookbackDiscoveryWork(options: options)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let first = try #require(CostUsageStoreAccess.read(
            cacheRoot: env.cacheRoot).files.values.first)
        #expect(first.parsedBytes == slice)
        #expect(first.codexScanComplete == false)

        let original = try String(contentsOf: fileURL, encoding: .utf8)
        try (original + String(repeating: " ", count: 512)).write(to: fileURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: fileURL.path)
        let changedMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(changedMetadata.size != originalMetadata.size)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let resumed = try #require(CostUsageStoreAccess.read(
            cacheRoot: env.cacheRoot).files.values.first)
        #expect((resumed.parsedBytes ?? 0) > (first.parsedBytes ?? 0))
        #expect(resumed.parsedBytes == min(changedMetadata.size, (first.parsedBytes ?? 0) + slice))
        #expect(resumed.codexScanTargetSize == changedMetadata.size)
        #expect(resumed.codexScanFileId == changedMetadata.fileId)
        #expect(resumed.codexScanComplete == false)
    }

    @Test
    func `catch-up API continuously advances bounded slices to the exact full result`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let files = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 1, turnsPerFile: 8)
        let fileURL = try #require(files.first)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let slice = max(1, metadata.size / 4)

        var baselineOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("baseline-cache"),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        baselineOptions.refreshMinIntervalSeconds = 0
        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: baselineOptions)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: slice,
            maxCodexScanBytesPerRefresh: slice)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let fetcher = CostUsageFetcher(scannerOptions: options)
        var status = await fetcher.codexScanCatchUpStatus()
        #expect(status.pending)
        var progressStates = [(pending: status.pending, key: status.progressKey)]
        for _ in 0..<12 where status.pending {
            status = try await fetcher.advanceCodexScanCatchUp(now: day, historyDays: 1)
            progressStates.append((pending: status.pending, key: status.progressKey))
        }

        let completedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let completedUsage = try #require(completedCache.files.values.first)
        let completedReport = CostUsageScanner.buildCodexReportFromCache(
            cache: completedCache,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        #expect(!status.pending)
        #expect(completedUsage.codexScanComplete == true)
        #expect(completedUsage.parsedBytes == metadata.size)
        #expect(zip(progressStates, progressStates.dropFirst()).allSatisfy { previous, next in
            previous.key != next.key || (previous.pending && !next.pending)
        })
        #expect(completedReport.summary?.totalTokens == baseline.summary?.totalTokens)
        #expect(completedReport.data.map(\.totalTokens) == baseline.data.map(\.totalTokens))
    }

    @Test
    func `previous report stays visible until bounded fork rebuild converges`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.2-codex"

        let parentBody = ([
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"upgrade-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"\#(model)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25},"#
                + #""model":"\#(model)"}}}"#,
        ] + Array(repeating: "x", count: 4096)).joined(separator: "\n") + "\n"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "upgrade-parent.jsonl",
            contents: parentBody)
        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"upgrade-child","#
                + #""forked_from_id":"upgrade-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"\#(model)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":600,"cached_input_tokens":60,"output_tokens":30},"#
                + #""model":"\#(model)"}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "upgrade-child.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day],
            ofItemAtPath: parentURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: childURL.path)

        var baselineOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("upgrade-baseline-cache"),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        baselineOptions.refreshMinIntervalSeconds = 0
        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: baselineOptions)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1024,
            maxCodexScanBytesPerRefresh: 1024,
            preferNewestCodexSessionsFirst: true)
        options.refreshMinIntervalSeconds = 0
        let range = CostUsageScanner.CostUsageDayRange(
            since: day,
            until: day,
            calendar: options.calendar)
        let priorScanAt = day.addingTimeInterval(-3600)
        var priorCache = CostUsageCache()
        priorCache.lastScanUnixMs = Int64(priorScanAt.timeIntervalSince1970 * 1000)
        priorCache.scanSinceKey = range.scanSinceKey
        priorCache.scanUntilKey = range.scanUntilKey
        priorCache.timeZoneIdentifier = options.calendar.timeZone.identifier
        priorCache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        priorCache.days = [
            range.sinceKey: [CostUsagePricing.normalizeCodexModel(model): [777, 0, 0]],
        ]
        let priorReport = CostUsageScanner.buildCodexReportFromCache(
            cache: priorCache,
            range: range)
        var rebuildingCache = CostUsageCache()
        rebuildingCache.scanSinceKey = range.scanSinceKey
        rebuildingCache.scanUntilKey = range.scanUntilKey
        rebuildingCache.timeZoneIdentifier = options.calendar.timeZone.identifier
        rebuildingCache.roots = priorCache.roots
        rebuildingCache.codexScanCatchUpPending = true
        rebuildingCache.codexPreviousReport = CostUsageCodexPreviousReport(
            report: priorReport,
            cache: priorCache,
            reportSinceKey: range.sinceKey,
            reportUntilKey: range.untilKey)
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: rebuildingCache)
        var report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let fetcher = CostUsageFetcher(scannerOptions: options)
        var status = await fetcher.codexScanCatchUpStatus()

        #expect(status.pending)
        #expect(status.staleSnapshotUpdatedAt == priorScanAt)
        #expect(report.data == priorReport.data)
        #expect(report.summary == priorReport.summary)
        #expect(CostUsageStoreAccess.read(
            cacheRoot: env.cacheRoot).codexPreviousReport != nil)

        for pass in 1...16 where status.pending {
            report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            status = await fetcher.codexScanCatchUpStatus()
            if status.pending {
                #expect(report.data == priorReport.data)
                #expect(report.summary == priorReport.summary)
                #expect(status.staleSnapshotUpdatedAt == priorScanAt)
            }
        }

        let completedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(!status.pending)
        #expect(status.staleSnapshotUpdatedAt == nil)
        #expect(completedCache.codexPreviousReport == nil)
        #expect(report.data == baseline.data)
        #expect(report.summary == baseline.summary)
    }

    @Test
    func `single oversized jsonl record resumes without stalling`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let model = "openai/gpt-5.2-codex"
        let contents = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"long-record"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"\#(model)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","padding":""#
                + String(repeating: "x", count: 4096)
                +
                #"","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"#
                + #""output_tokens":25},"model":"\#(model)"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(day: day, filename: "long-record.jsonl", contents: contents)

        var baselineOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.root.appendingPathComponent("baseline-cache"),
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        baselineOptions.refreshMinIntervalSeconds = 0
        let baseline = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: baselineOptions)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 256,
            maxCodexScanBytesPerRefresh: 256)
        options.refreshMinIntervalSeconds = 0

        var offsets: [Int64] = []
        var sawPartialRecord = false
        var report: CostUsageDailyReport?
        for _ in 0..<24 {
            report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
            let cached = try #require(CostUsageStoreAccess.read(
                cacheRoot: env.cacheRoot).files.values.first)
            offsets.append(cached.parsedBytes ?? 0)
            sawPartialRecord = sawPartialRecord || cached.codexJSONLResumeState != nil
            if cached.codexScanComplete == true {
                break
            }
        }

        #expect(sawPartialRecord)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
        #expect(report?.summary?.totalTokens == baseline.summary?.totalTokens)
    }

    @Test
    func `codex scan budget never admits more than its remaining allowance`() {
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 100, maxBytesPerRefresh: 150)
        guard case let .allow(first) = budget.admit(workBytes: 1000) else {
            Issue.record("expected first bounded admission")
            return
        }
        #expect(first == 100)
        budget.consume(workBytes: first)

        guard case let .allow(second) = budget.admit(workBytes: 1000) else {
            Issue.record("expected remaining-budget admission")
            return
        }
        #expect(second == 50)
        budget.consume(workBytes: second)
        guard case .deferBudget = budget.admit(workBytes: 1) else {
            Issue.record("expected exhausted budget to defer")
            return
        }
        #expect(budget.bytesConsumed == 150)
    }

    @Test
    func `codex scan budget yields after its wall clock deadline`() {
        let clock = TestMonotonicClock()
        let budget = CostUsageScanner.CodexScanBudget(
            maxFileBytes: 100,
            maxBytesPerRefresh: 150,
            maxDuration: 2,
            now: { clock.now() })
        guard case let .allow(first) = budget.admit(workBytes: 100) else {
            Issue.record("expected work before the deadline to be admitted")
            return
        }
        budget.consume(workBytes: first)

        clock.advance(by: .seconds(3))
        #expect(budget.shouldYield(additionalBytes: 0))
        #expect(budget.deferredByTimeBudgetFileCount == 1)
        #expect(budget.shouldYield(additionalBytes: 0))
        #expect(budget.deferredByTimeBudgetFileCount == 1)
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset = Duration.zero

    func now() -> ContinuousClock.Instant {
        self.lock.withLock {
            self.origin.advanced(by: self.offset)
        }
    }

    func advance(by duration: Duration) {
        self.lock.withLock {
            self.offset += duration
        }
    }
}

extension CostUsagePerformanceGateTests {
    private static func persistenceScaleCache(files: Int, recordsPerFile: Int) -> CostUsageCache {
        let day = "2026-08-01"
        let model = "synthetic-scale-model"
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 1_754_044_800_000
        cache.scanSinceKey = day
        cache.scanUntilKey = day
        cache.timeZoneIdentifier = TimeZone.current.identifier
        cache.days = [day: [model: [files * recordsPerFile, 0, files * recordsPerFile]]]
        cache.files.reserveCapacity(files)
        for fileIndex in 0..<files {
            let path = "/synthetic/corpus/session-\(fileIndex).jsonl"
            let snapshots = (0..<recordsPerFile).map { recordIndex in
                CostUsageCodexTokenSnapshot(
                    timestamp: "2026-08-01T12:00:00.\(recordIndex)Z",
                    last: CostUsageCodexTotals(input: 1, cached: 0, output: 1),
                    total: CostUsageCodexTotals(input: recordIndex + 1, cached: 0, output: recordIndex + 1),
                    endOffset: Int64(recordIndex + 1))
            }
            let rows = (0..<recordsPerFile).map { recordIndex in
                CostUsageScanner.CodexUsageRow(
                    day: day,
                    model: model,
                    turnID: "turn-\(fileIndex)-\(recordIndex)",
                    eventIndex: recordIndex,
                    timestampUnixMs: Int64(1_754_044_800_000 + recordIndex),
                    input: 1,
                    cached: 0,
                    output: 1)
            }
            var usage = CostUsageFileUsage(
                mtimeUnixMs: Int64(1_754_044_800_000 + fileIndex),
                size: Int64(recordsPerFile),
                days: [day: [model: [recordsPerFile, 0, recordsPerFile]]])
            usage.parsedBytes = Int64(recordsPerFile)
            usage.codexScanFileId = "synthetic:\(fileIndex)"
            usage.codexScanComplete = true
            usage.codexTokenTimestampsMonotonic = true
            usage.codexTokenSnapshots = snapshots
            usage.codexRows = rows
            cache.files[path] = usage
        }
        return cache
    }

    @Test
    func `missing parent head discovery resumes inside the scan budget`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let body = #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"known-session","cwd":"#
            + String(repeating: "x", count: 512)
            + #""}}"#
            + "\n"
        let fileURL = try env.writeCodexSessionFile(day: day, filename: "budgeted-head.jsonl", contents: body)

        var discovery: CostUsageCodexSessionDiscovery?
        var offsets: [Int64] = []
        var resolvedMissing = false
        for _ in 0..<32 {
            let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 32, maxBytesPerRefresh: 32)
            let index = CostUsageScanner.CodexSessionFileIndex(
                files: [fileURL],
                roots: [env.codexSessionsRoot],
                cachedDiscovery: discovery,
                scanBudget: budget)
            switch try index.lookup(sessionId: "absent-session") {
            case .found:
                Issue.record("unexpected parent resolution")
            case .missing:
                resolvedMissing = true
            case .deferred:
                break
            }
            discovery = index.persistedState
            if let offset = discovery?.headScan?.resumeState?.offset ?? discovery?.headScan?.offset {
                offsets.append(offset)
            }
            if resolvedMissing {
                break
            }
        }

        #expect(offsets.count >= 2)
        #expect(offsets[1] > offsets[0])
        #expect(resolvedMissing)
        #expect(discovery?.missingSessionIds.contains("absent-session") == true)
    }

    @Test
    func `missing fork parent stays idle then publishes buffered usage once when created`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        _ = try Self.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: 250,
            turnsPerFile: 0)

        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"missing-child","#
                + #""forked_from_id":"late-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":150,"cached_input_tokens":15,"output_tokens":8},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "missing-child.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(600)],
            ofItemAtPath: childURL.path)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let coldCounter = HeadParseCounter()
        _ = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            coldCounter.increment()
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
        }
        let coldCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let coldChild = try #require(coldCache.files.values.first { $0.sessionId == "missing-child" })
        let coldDiscovery = try #require(coldCache.codexSessionDiscovery)
        #expect(coldCounter.value >= 250)
        #expect(coldChild.days.isEmpty)
        #expect(coldChild.forkBaselineDependencyKey?.contains("missing|late-parent|discovery|") == true)
        #expect(coldDiscovery.missingSessionIds.contains("late-parent"))

        let warmCounter = HeadParseCounter()
        _ = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            warmCounter.increment()
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options)
        }
        #expect(warmCounter.value == 0)

        let parentBody = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"late-parent"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":5},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(day: day, filename: "late-parent.jsonl", contents: parentBody)

        let resolved = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let resolvedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let resolvedChild = try #require(resolvedCache.files.values.first { $0.sessionId == "missing-child" })
        #expect(!resolvedChild.days.isEmpty)
        #expect(resolvedChild.forkBaselineDependencyKey?.hasPrefix("file|late-parent|") == true)

        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        let stableCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let stableChild = try #require(stableCache.files.values.first { $0.sessionId == "missing-child" })
        #expect(stableChild.days == resolvedChild.days)
        #expect(stable.summary?.totalTokens == resolved.summary?.totalTokens)
    }

    @Test
    func `partition inventory change rotates negative lookup generation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        _ = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 20, turnsPerFile: 0)
        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"inventory-child","#
                + #""forked_from_id":"inventory-missing"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":10,"cached_input_tokens":1,"output_tokens":1}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "inventory-child.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(600)],
            ofItemAtPath: childURL.path)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let firstGeneration = try #require(firstCache.codexSessionDiscovery?.generation)
        #expect(firstCache.codexSessionDiscovery?.missingSessionIds.contains("inventory-missing") == true)

        let newFile = try env.writeCodexSessionFile(
            day: day,
            filename: "inventory-new.jsonl",
            contents: #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"new-session"}}"#
                + "\n")
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(300)],
            ofItemAtPath: newFile.path)
        let counter = HeadParseCounter()
        _ = CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            counter.increment()
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options)
        }
        let changedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let changedGeneration = try #require(changedCache.codexSessionDiscovery?.generation)
        #expect(changedGeneration != firstGeneration)
        #expect(changedCache.codexSessionDiscovery?.missingSessionIds.contains("inventory-missing") == true)
        #expect(counter.value <= 1)
    }

    @Test
    func `sparse token checkpoints preserve the exact accumulator state`() {
        let mebibyte: Int64 = 1024 * 1024
        let events = [
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:00:00Z",
                last: .init(input: 100, cached: 10, output: 5),
                total: .init(input: 100, cached: 10, output: 5),
                endOffset: 1 * mebibyte),
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:01:00Z",
                last: .init(input: 100, cached: 10, output: 5),
                total: .init(input: 200, cached: 20, output: 10),
                endOffset: 5 * mebibyte),
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:02:00Z",
                last: .init(input: 10, cached: 1, output: 1),
                total: .init(input: 150, cached: 15, output: 8),
                endOffset: 6 * mebibyte),
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:03:00Z",
                last: .init(input: 70, cached: 7, output: 2),
                total: .init(input: 220, cached: 22, output: 12),
                endOffset: 10 * mebibyte),
            CostUsageCodexTokenSnapshot(
                timestamp: "2026-05-10T12:04:00Z",
                last: .init(input: 10, cached: 1, output: 1),
                total: .init(input: 230, cached: 23, output: 13),
                endOffset: 10 * mebibyte + 1),
        ]

        let checkpoints = CostUsageScanner.codexTokenCheckpoints(for: events)
        #expect(checkpoints.map(\.eventIndex) == [1, 3, 4])

        for checkpoint in checkpoints {
            var accumulator = CostUsageScanner.CodexSnapshotAccumulator()
            for event in events[...checkpoint.eventIndex] {
                _ = accumulator.apply(last: event.last, total: event.total)
            }
            #expect(checkpoint.state == accumulator.state)
        }
    }

    @Test
    func `per refresh byte budget defers later dirty files`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let urls = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 3, turnsPerFile: 3)
        // Make deterministic order by newest-first: touch later files later.
        let older = try #require(urls.first)
        let middle = try #require(urls.dropFirst().first)
        let newer = try #require(urls.last)
        let olderDate = day.addingTimeInterval(-3600)
        let middleDate = day.addingTimeInterval(-1800)
        let newerDate = day
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: middleDate], ofItemAtPath: middle.path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newer.path)

        let newestMeta = CostUsageScanner.codexFileMetadata(fileURL: newer)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 64 * 1024 * 1024,
            // Enough for the newest file only; remaining dirty files defer.
            maxCodexScanBytesPerRefresh: max(1, newestMeta.size),
            preferNewestCodexSessionsFirst: true)
        options.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let cachedNames = Set(cache.files.keys.map { URL(fileURLWithPath: $0).lastPathComponent })

        #expect(cachedNames.contains(newer.lastPathComponent))
        #expect(!cachedNames.contains(older.lastPathComponent))
    }

    @Test
    func `pending work bytes treat fork files as full rescan work`() {
        let metadata = CostUsageScanner.CodexFileMetadata(
            path: "/tmp/forked.jsonl",
            mtimeUnixMs: 2,
            size: 1000,
            fileId: "1:2")
        let cached = CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 400,
            days: [:],
            parsedBytes: 400,
            forkedFromId: "parent-session")
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(metadata: metadata, cached: cached) == 1000)
    }

    @Test
    func `pending work bytes charge full file for forced rescans of unchanged cache entries`() {
        let metadata = CostUsageScanner.CodexFileMetadata(
            path: "/tmp/unchanged.jsonl",
            mtimeUnixMs: 42,
            size: 2_000_000_000,
            fileId: "9:9")
        let cached = CostUsageFileUsage(
            mtimeUnixMs: 42,
            size: 2_000_000_000,
            days: ["2026-05-10": ["gpt-5.2-codex": [100, 20, 10]]],
            parsedBytes: 2_000_000_000,
            sessionId: "session-unchanged")
        // keepCached can still reject this (forceFullScan / priority / fork dependency).
        // Budget must not report zero pending work or multi-GB forced rescans slip through.
        #expect(CostUsageScanner.pendingCodexScanWorkBytes(metadata: metadata, cached: cached) == 2_000_000_000)
    }

    @Test
    func `oversized parent baseline resolves from its same refresh partial snapshot`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let parentTotalISO = env.isoString(for: day.addingTimeInterval(1))
        let forkISO = env.isoString(for: day.addingTimeInterval(2))

        // Parent is intentionally larger than the per-file budget.
        let parentBody = ([
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"parent-giant"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(parentTotalISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":3},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ] + Array(repeating: "x", count: 4096)).joined(separator: "\n") + "\n"
        _ = try env.writeCodexSessionFile(day: day, filename: "parent-giant.jsonl", contents: parentBody)

        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"child-small","#
                + #""forked_from_id":"parent-giant"}}"#,
            #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":600,"cached_input_tokens":60,"output_tokens":30},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(day: day, filename: "child-small.jsonl", contents: childBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 1024,
            maxCodexScanBytesPerRefresh: 64 * 1024 * 1024)
        options.refreshMinIntervalSeconds = 0
        let started = Date()
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let elapsed = Date().timeIntervalSince(started)
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let firstParent = try #require(firstCache.files.values.first { $0.sessionId == "parent-giant" })
        let firstChild = try #require(firstCache.files.values.first { $0.sessionId == "child-small" })
        let firstChildDay = try #require(
            firstChild.days[CostUsageScanner.CostUsageDayRange.dayKey(from: day)])
        let firstChildTokens = try #require(
            firstChildDay[CostUsagePricing.normalizeCodexModel("openai/gpt-5.2-codex")])

        #expect(elapsed < 2.0)
        #expect(firstCache.files.keys.contains {
            URL(fileURLWithPath: $0).lastPathComponent == childURL.lastPathComponent
        })
        #expect(firstChildTokens == [80, 5, 2])
        #expect(firstChild.forkBaselineDependencyKey != nil)
        #expect(firstChild.codexBufferedSubagentLines == nil)
        #expect(firstParent.codexScanComplete == false)
        #expect(firstParent.codexTokenSnapshots?.count == 2)
        #expect(firstParent.codexTokenSnapshots?.last?.last == .init(input: 20, cached: 5, output: 3))
        #expect(firstParent.codexTokenCheckpoints?.isEmpty == false)
        #expect(firstParent.codexTokenIndexAnchor != nil)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let secondCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let parent = try #require(secondCache.files.values.first { $0.sessionId == "parent-giant" })
        let child = try #require(secondCache.files.values.first { $0.sessionId == "child-small" })
        let childDay = try #require(child.days[CostUsageScanner.CostUsageDayRange.dayKey(from: day)])
        let childTokens = try #require(
            childDay[CostUsagePricing.normalizeCodexModel("openai/gpt-5.2-codex")])

        #expect(parent.codexScanComplete == false)
        #expect(parent.codexTokenSnapshots?.count == 2)
        #expect(childTokens == [80, 5, 2])
        #expect(child.forkBaselineDependencyKey != nil)
    }

    @Test
    func `appended parent resolves from a validated cached prefix without rereading it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        let appendedISO = env.isoString(for: day.addingTimeInterval(10))

        let parentBody = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"parent-append"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "parent-append.jsonl",
            contents: parentBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let indexedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let indexedParentEntry = try #require(
            indexedCache.files.first { $0.value.sessionId == "parent-append" })
        let parentCachePath = indexedParentEntry.key
        let indexedParent = indexedParentEntry.value
        let indexedSize = indexedParent.size
        #expect(indexedParent.codexScanComplete == true)
        #expect(indexedParent.codexTokenIndexAnchor?.indexedBytes == indexedSize)
        #expect(indexedParent.codexTokenCheckpoints?.isEmpty == false)

        let appendedLine = #"{"type":"event_msg","timestamp":"\#(appendedISO)","payload":{"type":"token_count","info":"#
            + #"{"total_token_usage":{"input_tokens":900,"cached_input_tokens":90,"output_tokens":45},"#
            + #""model":"openai/gpt-5.2-codex"}}}"# + "\n"
        let parentHandle = try FileHandle(forWritingTo: parentURL)
        try parentHandle.seekToEnd()
        try parentHandle.write(contentsOf: Data(appendedLine.utf8))
        try parentHandle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: parentURL.path)

        let childBody = [
            #"{"type":"session_meta","timestamp":"\#(forkISO)","payload":{"session_id":"child-append","#
                + #""forked_from_id":"parent-append"}}"#,
            #"{"type":"turn_context","timestamp":"\#(forkISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":600,"cached_input_tokens":60,"output_tokens":30},"#
                + #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined(separator: "\n") + "\n"
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "child-append.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: childURL.path)
        let childSize = CostUsageScanner.codexFileMetadata(fileURL: childURL).size

        options.maxCodexSessionFileBytes = 64 * 1024 * 1024
        options.maxCodexScanBytesPerRefresh = childSize + Self.codexLookbackDiscoveryWork(options: options)
        options.preferNewestCodexSessionsFirst = true
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(120),
            options: options)

        let refreshedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let deferredParent = try #require(refreshedCache.files[parentCachePath])
        let child = try #require(
            refreshedCache.files.values.first { $0.sessionId == "child-append" })
        let childDay = try #require(child.days[CostUsageScanner.CostUsageDayRange.dayKey(from: day)])
        let childTokens = try #require(
            childDay[CostUsagePricing.normalizeCodexModel("openai/gpt-5.2-codex")])

        #expect(childTokens == [100, 10, 5])
        #expect(child.forkBaselineDependencyKey != nil)
        #expect(deferredParent.size == indexedSize)
        #expect(CostUsageScanner.codexFileMetadata(fileURL: parentURL).size > deferredParent.size)
    }

    @Test
    func `rewritten parent prefix rejects its cached token index`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let forkISO = env.isoString(for: day.addingTimeInterval(1))
        let originalBody = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"parent-rewrite"}}"#,
            #"{"type":"event_msg","timestamp":"\#(forkISO)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":25}}}}"#,
        ].joined(separator: "\n") + "\n"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "parent-rewrite.jsonl",
            contents: originalBody)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let usage = try #require(cache.files.values.first { $0.sessionId == "parent-rewrite" })
        let anchor = try #require(usage.codexTokenIndexAnchor)

        let rewrittenBody = originalBody.replacingOccurrences(
            of: #""input_tokens":500"#,
            with: #""input_tokens":900"#)
        #expect(rewrittenBody.utf8.count == originalBody.utf8.count)
        try rewrittenBody.write(to: parentURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: parentURL.path)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: parentURL)
        #expect(!CostUsageScanner.codexTokenIndexAnchorMatches(
            anchor,
            fileURL: parentURL,
            metadata: metadata))

        let fileIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [parentURL],
            roots: [env.codexSessionsRoot])
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: fileIndex,
            checkCancellation: nil,
            scanBudget: CostUsageScanner.CodexScanBudget(maxFileBytes: 1, maxBytesPerRefresh: 1),
            cachedFiles: cache.files)
        guard case .unresolved = try resolver.inheritedTotals(
            for: "parent-rewrite",
            atOrBefore: forkISO)
        else {
            Issue.record("rewritten prefix must not reuse the cached fork baseline")
            return
        }
    }

    private static func writeSyntheticCodexCorpus(
        env: CostUsageTestEnvironment,
        day: Date,
        files: Int,
        turnsPerFile: Int,
        model: String = "openai/gpt-5.2-codex",
        inputTokensPerTurn: Int = 100) throws -> [URL]
    {
        let baseISO = env.isoString(for: day)
        var fileURLs: [URL] = []
        for fileIndex in 0..<files {
            var lines: [String] = []
            lines.reserveCapacity(turnsPerFile + 2)
            lines.append(
                #"{"type":"session_meta","timestamp":"\#(baseISO)","payload":{"session_id":"perf-\#(fileIndex)"}}"#)
            lines.append(
                #"{"type":"turn_context","timestamp":"\#(baseISO)","payload":{"model":"\#(model)"}}"#)
            if turnsPerFile > 0 {
                for turn in 1...turnsPerFile {
                    let inputTokens = turn * inputTokensPerTurn
                    let cachedTokens = turn * 20
                    let outputTokens = turn * 10
                    lines.append(
                        #"{"type":"event_msg","timestamp":"\#(baseISO)","payload":{"type":"token_count","info":"#
                            + #"{"total_token_usage":{"input_tokens":\#(inputTokens),"#
                            + #""cached_input_tokens":\#(cachedTokens),"output_tokens":\#(outputTokens)},"#
                            + #""model":"\#(model)"}}}"#)
                }
            }
            let fileURL = try env.writeCodexSessionFile(
                day: day,
                filename: "session-\(fileIndex).jsonl",
                contents: lines.joined(separator: "\n") + "\n")
            fileURLs.append(fileURL)
        }
        return fileURLs
    }

    private static func replaceTraceBody(dbURL: URL, rowID: Int64, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "update logs set feedback_log_body = ? where id = ?", -1, &statement, nil)
            == SQLITE_OK
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 2, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func codexLookbackDiscoveryWork(options: CostUsageScanner.Options) -> Int64 {
        let existingRootCount = CostUsageScanner.codexSessionsRoots(options: options).count {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return Int64(CostUsageScanner.codexActiveSessionLookbackDays * existingRootCount)
    }

    private static func dayKeyString(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

private final class HeadParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
#endif
