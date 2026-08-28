import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `malformed retained replay keeps read only coverage incomplete without reading its body`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let path = try #require(fixture.canonical.files.keys.min())
        let malformed = CostUsageStoreBufferedLine(
            path: path,
            kind: .unresolvedFork,
            lineIndex: 0,
            payload: Data("invalid replay JSON".utf8))
        #expect(await fixture.store.replaceBufferedLines(path: path, kind: .unresolvedFork, lines: [malformed]))
        let persisted = await fixture.store.readSnapshot()
        #expect(persisted.bufferedLines == [malformed])
        // The full loader currently drops undecodable bodies; the read view deliberately retains presence.
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == fixture.canonical)
        let expected = fixture.fullCachedSnapshot(cache: fixture.canonical)

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let fetcher = CostUsageFetcher(scannerOptions: fixture.options)
        let status = await fetcher.codexScanCatchUpStatus()
        let statusWork = recorder.snapshot()
        #expect(status.pending)
        #expect(status.totalFiles == 2)
        #expect(status.completedFiles == 2)
        #expect(statusWork.retryPresenceRows == 1)
        #expect(statusWork.usageRows == 0)
        #expect(statusWork.usageRowDecodeAttempts == 0)
        #expect(statusWork.bufferedLines == 0)
        #expect(statusWork.bufferedPayloadBytes == 0)
        #expect(statusWork.readViewConversions == 1)
        #expect(statusWork.readViewConversionsInTransaction == 0)
        #expect(await fetcher.codexScanCatchUpStatus() == status)

        recorder.reset()
        let result = try #require(await fixture.cachedSnapshot(details: true))
        let reportWork = recorder.snapshot()
        #expect(!result.snapshot.historyCoverageIsEstablished)
        #expect(result.snapshot.last30DaysTokens == 104)
        #expect(result.snapshot.last30DaysCostUSD == 0.008)
        #expect(result.snapshot.daily == expected.daily)
        #expect(result.snapshot.projects == expected.projects)
        #expect(result.snapshot.sessions == expected.sessions)
        #expect(reportWork.retryPresenceRows == 1)
        #expect(reportWork.usageRows == 8)
        #expect(reportWork.usageRowDecodeAttempts == 8)
        #expect(reportWork.usagePayloadBytes > 0)
        #expect(reportWork.bufferedLines == 0)
        #expect(reportWork.bufferedPayloadBytes == 0)
        #expect(reportWork.tokenSnapshotRows == 0)
        #expect(reportWork.accumulatorRows == 0)
        #expect(reportWork.readViewConversions == 1)
        #expect(reportWork.readViewConversionsInTransaction == 0)
        print("[cost-store-read-proof] malformed-replay pending=\(status.pending) " +
            "coverage=\(result.snapshot.historyCoverageIsEstablished) " +
            "status_usage_rows=\(statusWork.usageRows) report_usage_rows=\(reportWork.usageRows) " +
            "status_replay_bytes=\(statusWork.bufferedPayloadBytes) " +
            "report_replay_bytes=\(reportWork.bufferedPayloadBytes)")
        CostUsageStore.readWorkRecorderForTesting = nil
        #expect(await fixture.store.readSnapshot() == persisted)
    }

    @Test(arguments: [false, true])
    func `projections preserve retry kinds and full scanner state`(subagent: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        var cache = fixture.canonical
        let path = try #require(cache.files.keys.min())
        if subagent {
            let lines = cache.files[path]?.codexBufferedUnresolvedForkLines
            cache.files[path]?.codexBufferedSubagentLines = lines
            cache.files[path]?.codexBufferedUnresolvedForkLines = nil
        }
        // Retry presence alone must keep coverage pending, even with a completed byte scan.
        cache.files[path]?.codexScanComplete = true
        #expect(!fixture.save(cache).catchUpRequired)
        let baseline = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(baseline.files[path]?.hasBufferedCodexForkRetryLines == true)
        try fixture.expectProjectionParity(baseline)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        _ = fixture.store.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .report)
        #expect(recorder.snapshot().retryPresenceRows == 1)
        #expect(recorder.snapshot().bufferedPayloadBytes == 0)
        recorder.reset()
        let buffers = await fixture.store.fetchBufferedLines(path: path)
        #expect(buffers.count == 1)
        #expect(recorder.snapshot().bufferedLines == 1)
        #expect(recorder.snapshot().bufferedPayloadBytes == buffers.reduce(0) { $0 + $1.payload.count })
        #expect(await fixture.store.fetchAccumulator(path: path) != nil)
        #expect(recorder.snapshot().accumulatorRows == 1)
        #expect(baseline.files[path]?.lastCountedTotals != nil)
        #expect(baseline.files[path]?.codexTokenSnapshots?.count == 4)
        #expect(baseline.files[path]?.codexReadRetryBufferPresence == nil)
        #expect(!fixture.save(baseline).catchUpRequired)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == baseline)
    }

    @Test(arguments: [false, true])
    func `identity normalization and invalidation agree with full reads`(changed: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var file = try #require(await fixture.store.readSnapshot().files.first)
        let inode = try #require(file.scanState.fileIdentity?.split(separator: ":").last)
        file.scanState.fileIdentity = "0:\(inode)"
        #expect(await fixture.store.upsertFile(file))
        if changed {
            try Data("changed fixture\n".utf8).write(to: URL(fileURLWithPath: file.path))
        }
        let baseline = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(baseline.files[file.path]?.codexScanComplete == !changed)
        #expect(baseline.codexScanCatchUpPending == changed)
        try fixture.expectProjectionParity(baseline)
    }

    @Test
    func `deferred identity validation remains pending beyond the bounded slice`() async throws {
        let count = CostUsageScanner.codexCatchUpScanCandidateLimit + 2
        let fixture = try ReadWorkFixture(fileCount: count, rowsPerFile: 1)
        defer { fixture.remove() }
        let snapshot = await fixture.store.readSnapshot()
        for var file in snapshot.files {
            let inode = try #require(file.scanState.fileIdentity?.split(separator: ":").last)
            file.scanState.fileIdentity = "0:\(inode)"
            #expect(await fixture.store.upsertFile(file))
        }
        let baseline = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(baseline.codexActiveLookbackState?.pendingFilePaths.count == 2)
        #expect(baseline.codexScanCatchUpPending == true)
        try fixture.expectProjectionParity(baseline)
    }

    @Test
    func `previous report timestamps and completed pending reconciliation survive projections`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        var cache = fixture.canonical
        let range = fixture.range
        var previousCache = cache
        previousCache.lastScanUnixMs -= 60000
        cache.codexPreviousReport = CostUsageCodexPreviousReport(
            report: fixture.fullReport(cache),
            cache: previousCache,
            reportSinceKey: range.sinceKey,
            reportUntilKey: range.untilKey)
        #expect(!fixture.save(cache).catchUpRequired)
        var baseline = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        try fixture.expectProjectionParity(baseline)
        let cached = try #require(await fixture.cachedSnapshot(details: true))
        #expect(cached.snapshot.updatedAt == fixture.now.addingTimeInterval(-60))
        #expect(cached.lastRefreshAt == nil)
        #expect(cached.staleSnapshotUpdatedAt == fixture.now.addingTimeInterval(-60))
        #expect(cached.snapshot.projects.isEmpty)
        #expect(cached.snapshot.sessions.isEmpty)
        for path in cache.files.keys {
            cache.files[path]?.codexBufferedUnresolvedForkLines = nil
            cache.files[path]?.codexScanComplete = true
        }
        #expect(!fixture.save(cache).catchUpRequired)
        baseline = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(baseline.codexScanCatchUpPending == false)
        #expect(baseline.codexPreviousReport == nil)
        try fixture.expectProjectionParity(baseline)
        #expect(await fixture.cachedSnapshot(details: true)?.snapshot.updatedAt == fixture.now)
    }

    @Test
    func `default details preserve mixed authoritative and estimated row pricing`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var cache = fixture.canonical
        let path = try #require(cache.files.keys.min())
        let model = ReadWorkFixture.model
        cache.files[path]?.codexRows = [
            .init(
                day: ReadWorkFixture.day,
                model: model,
                turnID: "billed",
                eventIndex: 0,
                input: 10,
                cached: 2,
                output: 3,
                knownCostNanos: 2_000_000,
                pricingModel: model,
                pricingMode: "standard"),
            .init(
                day: ReadWorkFixture.day,
                model: model,
                turnID: "estimated",
                eventIndex: 1,
                input: 30,
                cached: 6,
                output: 9,
                pricingModel: model,
                pricingMode: "priority"),
        ]
        cache.files[path]?.codexStandardTokens = [ReadWorkFixture.day: [model: 13]]
        cache.files[path]?.codexPriorityTokens = [ReadWorkFixture.day: [model: 39]]
        #expect(!fixture.save(cache).catchUpRequired)
        let baseline = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        try fixture.expectProjectionParity(baseline)
        let result = try #require(await fixture.cachedSnapshot(details: true))
        let expected = fixture.fullReport(baseline)
        #expect(result.snapshot == fixture.fullCachedSnapshot(cache: baseline))
        #expect(result.snapshot.sessions == CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: baseline, range: fixture.range, modelsDevCacheRoot: fixture.env.cacheRoot))
        let breakdown = try #require(expected.data.first?.modelBreakdowns?.first)
        #expect(breakdown.standardTokens == 65)
        #expect(breakdown.priorityTokens == 39)
        #expect(try #require(breakdown.priorityCostUSD) > 0)
        #expect(try #require(breakdown.costUSD) > 0.006)
    }

    @Test
    func `missing parent forks retain unmetered coverage in project and session reports`() throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        var cache = fixture.canonical
        let path = try #require(cache.files.keys.min())
        cache.files[path]?.days = [:]
        cache.files[path]?.codexRows = []
        cache.files[path]?.forkedFromId = "missing-fixture-parent"
        cache.files[path]?.forkBaselineDependencyKey = "missing|fixture-parent"
        cache.files[path]?.codexSession?.startedAtUnixMs = cache.lastScanUnixMs
        cache.days = [:]
        for usage in cache.files.values {
            CostUsageScanner.applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
        }
        #expect(!fixture.save(cache).catchUpRequired)
        let baseline = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        try fixture.expectProjectionParity(baseline)
        let report = fixture.fullReport(baseline)
        #expect(report.data.first?.unmeteredRequestCount == 1)
        #expect(report.summary?.totalTokens == 52)
        let view = fixture.store.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .report)
        let sessions = view.sessions(
            range: fixture.range,
            cacheRoot: fixture.env.cacheRoot,
            roots: CostUsageScanner.codexSessionsRoots(options: fixture.options))
        #expect(sessions.count == 2)
    }

    @Test
    func `empty and malformed file metadata preserve owner behavior`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var file = try #require(await fixture.store.readSnapshot().files.first)
        file.scanState.detailsPayload = Data("malformed".utf8)
        #expect(await fixture.store.upsertFile(file))
        let baseline = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(baseline.files.count == 1)
        try fixture.expectProjectionParity(baseline)

        let empty = try ReadWorkFixture(fileCount: 0, rowsPerFile: 0)
        defer { empty.remove() }
        try empty.expectProjectionParity(empty.canonical)
        let established = try #require(await empty.cachedSnapshot(details: true))
        #expect(established.snapshot.historyCoverageIsEstablished)
        #expect(established.snapshot.last30DaysTokens == 0)
        #expect(established.snapshot.last30DaysCostUSD == 0)
        let missingRoot = empty.env.root.appendingPathComponent("uninitialized-cache")
        let missing = CostUsageStoreAccess.readView(cacheRoot: missingRoot, calendar: empty.calendar, purpose: .status)
        #expect(missing.lastScanUnixMs == 0)
        #expect(!missing.historyCoverageIsEstablished(
            range: empty.range, rootsFingerprint: CostUsageScanner.codexRootsFingerprint(options: empty.options)))
    }
}

extension ReadWorkFixture {
    /// The pre-projection full-load path, including the fetcher's existing merge normalization.
    func fullCachedSnapshot(cache: CostUsageCache? = nil) -> CostUsageTokenSnapshot {
        let roots = CostUsageScanner.codexSessionsRoots(options: self.options)
        let full = CostUsageScanner.codexCache(
            cache ?? CostUsageStoreAccess.read(cacheRoot: self.env.cacheRoot, calendar: self.calendar), scopedTo: roots)
        return CostUsageFetcher.tokenSnapshot(
            from: .merged([self.fullReport(full)]),
            now: self.now,
            historyDays: 1,
            calendar: self.calendar,
            historyCoverageIsEstablished: !self.incomplete,
            costProvenance: .listPriceEstimate,
            projects: CostUsageFetcher.mergedProjectBreakdowns(
                CostUsageScanner.buildCodexProjectBreakdownsFromCache(
                    cache: full, range: self.range, modelsDevCacheRoot: self.env.cacheRoot)),
            sessions: CostUsageScanner.buildCodexSessionBreakdownsFromCache(
                cache: full, range: self.range, modelsDevCacheRoot: self.env.cacheRoot, sessionRoots: roots),
            updatedAt: self.now)
    }

    var range: CostUsageScanner.CostUsageDayRange {
        .init(since: self.now, until: self.now, calendar: self.calendar)
    }

    func fullReport(_ cache: CostUsageCache) -> CostUsageDailyReport {
        CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: self.range,
            modelsDevCacheRoot: self.env.cacheRoot)
    }

    func expectProjectionParity(_ baseline: CostUsageCache) throws {
        let roots = CostUsageScanner.codexSessionsRoots(options: self.options)
        let fingerprint = CostUsageScanner.codexRootsFingerprint(options: self.options)
        let scoped = CostUsageScanner.codexCache(baseline, scopedTo: roots)
        let pending = baseline.codexScanCatchUpPending == true || scoped.files.values.contains {
            $0.codexScanComplete == false || $0.hasBufferedCodexForkRetryLines
        }
        let expectedStatus = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: pending,
            progressKey: CostUsageFetcher.codexScanProgressKey(cache: baseline, scopedFiles: scoped.files),
            processedBytes: baseline.codexScanProcessedBytes ?? 0,
            totalBytes: baseline.codexScanTotalBytes ?? 0,
            completedFiles: baseline.codexScanCompletedFiles ?? 0,
            totalFiles: baseline.codexScanTotalFiles ?? 0,
            staleSnapshotUpdatedAt: pending ? baseline.codexPreviousReport?.updatedAt : nil)
        for purpose in [CostUsageStoreReadPurpose.status, .report] {
            let view = self.store.syncLoadCodexReadView(calendar: self.calendar, purpose: purpose)
            #expect(view.catchUpStatus(roots: roots, rootsFingerprint: fingerprint) == expectedStatus)
            #expect(view.previousReport(range: self.range, rootsFingerprint: fingerprint)
                == CostUsageScanner.codexPreviousReport(
                    cache: baseline,
                    range: self.range,
                    rootsFingerprint: fingerprint))
            if purpose == .report {
                let report = view.scoped(to: roots).dailyReport(range: self.range, cacheRoot: self.env.cacheRoot)
                let full = self.fullReport(scoped)
                #expect(report.data == full.data)
                #expect(report.summary.map(CostUsageCodexPreviousReport.Summary.init)
                    == full.summary.map(CostUsageCodexPreviousReport.Summary.init))
                #expect(view.projects(range: self.range, cacheRoot: self.env.cacheRoot)
                    == CostUsageScanner.buildCodexProjectBreakdownsFromCache(
                        cache: baseline, range: self.range, modelsDevCacheRoot: self.env.cacheRoot))
                #expect(view.sessions(range: self.range, cacheRoot: self.env.cacheRoot, roots: roots)
                    == CostUsageScanner.buildCodexSessionBreakdownsFromCache(
                        cache: baseline,
                        range: self.range,
                        modelsDevCacheRoot: self.env.cacheRoot,
                        sessionRoots: roots))
            }
        }
    }
}
