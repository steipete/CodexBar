import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageStoreReadWorkTests {
    @Test(arguments: [2, 16])
    func `characterize valid store and caller reads`(fileCount: Int) async throws {
        let fixture = try ReadWorkFixture(fileCount: fileCount, rowsPerFile: fileCount == 2 ? 4 : 64)
        defer { fixture.remove() }
        let persisted = await fixture.store.readSnapshot()
        let configuration = try #require(await fixture.store.configuration())
        let fileBytes = await fixture.store.fileSizeBytes()
        #expect(persisted.files.count == fileCount)
        #expect(persisted.usageRows.count == fixture.rowCount)
        #expect(persisted.tokenSnapshots.count == fixture.rowCount)
        #expect(persisted.fileDayAggregates.count == fileCount)
        #expect(persisted.dayAggregates.count == 1)
        print("[cost-store-read-proof] files=\(fileCount) rows=\(fixture.rowCount) " +
            "schema=\(configuration.userVersion) db_bytes=\(fileBytes)")

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let (sameStore, _) = await Self.measure("same-store-load", fixture: fixture, recorder: recorder) {
            fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        }
        #expect(sameStore == fixture.canonical)
        let (freshStore, _) = await Self.measure("fresh-access-read", fixture: fixture, recorder: recorder) {
            CostUsageStoreAccess.read(cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar)
        }
        #expect(freshStore == fixture.canonical)
        let (status, _) = await Self.measure("status-only", fixture: fixture, recorder: recorder) {
            await CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus()
        }
        fixture.expectStatus(status)
        let (cached, _) = await Self.measure("cached-totals", fixture: fixture, recorder: recorder) {
            await fixture.cachedSnapshot()
        }
        try fixture.expectSnapshot(cached)
        let (detailed, detailedWork) = await Self.measure(
            "cached-default-details",
            fixture: fixture,
            recorder: recorder)
        {
            await fixture.cachedSnapshot(details: true)
        }
        try fixture.expectSnapshot(detailed, details: true)
        #expect(detailedWork.usageRows == fixture.rowCount)
        #expect(detailedWork.usagePayloadBytes > 0)
        #expect(detailedWork.tokenSnapshotRows == 0)
        #expect(detailedWork.accumulatorRows == 0)
        let (fullDetailed, _) = await Self.measure(
            "full-load-details-baseline", fixture: fixture, recorder: recorder)
        {
            fixture.fullCachedSnapshot()
        }
        #expect(detailed?.snapshot == fullDetailed)

        var refreshed = fixture.canonical
        refreshed.lastScanUnixMs += 1000
        let before = await fixture.store.persistenceWriteMetricsForTesting()
        let (unchanged, _) = await Self.measure("unchanged-save", fixture: fixture, recorder: recorder) {
            fixture.save(refreshed)
        }
        let after = await fixture.store.persistenceWriteMetricsForTesting()
        #expect(!unchanged.catchUpRequired)
        #expect(unchanged.deletedRows == 0)
        #expect(after.rows - before.rows == 1)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == refreshed)

        var changed = refreshed
        changed.codexProjectMetadataVersion = (changed.codexProjectMetadataVersion ?? 0) + 1
        let (metadataSave, _) = await Self.measure("metadata-only-save", fixture: fixture, recorder: recorder) {
            fixture.save(changed)
        }
        let changedWrites = await fixture.store.persistenceWriteMetricsForTesting()
        #expect(!metadataSave.catchUpRequired)
        #expect(metadataSave.deletedRows == 0)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == changed)
        print("[cost-store-read-proof] files=\(fileCount) unchanged_row_writes=\(after.rows - before.rows) " +
            "metadata_only_row_writes=\(changedWrites.rows - after.rows)")
    }

    @Test
    func `recorder excludes other database paths and preserves read results`() async throws {
        let observed = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { observed.remove() }
        let other = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { other.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: observed.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        #expect(CostUsageStoreAccess.read(cacheRoot: other.env.cacheRoot, calendar: other.calendar) == other.canonical)
        #expect(!other.save(other.canonical).catchUpRequired)
        #expect(recorder.snapshot() == CostUsageStoreReadWorkMetrics())

        let snapshot = await observed.store.readSnapshot()
        #expect(recorder.snapshot().fullSnapshotReads == 1)
        #expect(recorder.snapshot().usageRows == snapshot.usageRows.count)
        #expect(recorder.snapshot().usagePayloadBytes == snapshot.usageRows.reduce(0) { $0 + $1.payload.count })
        #expect(recorder.snapshot().cacheConversions == 0)
        recorder.reset()
        #expect(recorder.snapshot() == CostUsageStoreReadWorkMetrics())
        #expect(observed.store.syncLoadCodexCache(calendar: observed.calendar) == observed.canonical)
        recorder.reset()
        let path = try #require(observed.canonical.files.keys.min())
        let rows = await observed.store.fetchUsageRows(path: path)
        let tokens = await observed.store.fetchTokenSnapshots(path: path)
        #expect(recorder.snapshot().fullSnapshotReads == 0)
        #expect(recorder.snapshot().usageRows == rows.count)
        #expect(recorder.snapshot().usagePayloadBytes == rows.reduce(0) { $0 + $1.payload.count })
        #expect(recorder.snapshot().tokenSnapshotRows == tokens.count)
    }

    @Test(arguments: [false, true])
    func `complete and incomplete controls retain totals and reject other scopes`(incomplete: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: incomplete)
        defer { fixture.remove() }
        let status = await CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus()
        fixture.expectStatus(status)
        try await fixture.expectSnapshot(fixture.cachedSnapshot())

        var otherScope = fixture.options
        otherScope.codexSessionsRoot = fixture.env.root.appendingPathComponent("other-home/sessions")
        let rejected = await CostUsageFetcher(scannerOptions: otherScope).codexScanCatchUpStatus()
        #expect(rejected == .init(pending: false, progressKey: "scope-mismatch"))
        #expect(await fixture.cachedSnapshot(options: otherScope) == nil)
        #expect(await fixture.cachedSnapshot(historyDays: 365) == nil)

        var otherCalendar = fixture.options
        otherCalendar.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
        #expect(await fixture.cachedSnapshot(options: otherCalendar) == nil)
    }

    @Test(arguments: [false, true])
    func `status reads progress without historical usage payloads`(incomplete: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: incomplete)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let (status, work) = await Self.measure("status-contract", fixture: fixture, recorder: recorder) {
            await CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus()
        }
        fixture.expectStatus(status)

        #expect(work.usageRows == 0)
        #expect(work.usagePayloadBytes == 0)
        #expect(work.usageRowDecodeAttempts == 0)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.bufferedPayloadBytes == 0)
        #expect(work.accumulatorRows == 0)
        #expect(work.fileRows == fixture.fileCount)
        #expect(work.retryPresenceRows == (incomplete ? 1 : 0))
        #expect(work.integrityChecks == 1)
        #expect(work.readViewConversions == 1)
        #expect(work.readViewConversionsInTransaction == 0)
    }

    @Test(arguments: [false, true])
    func `cached totals exclude raw token usage and replay details`(incomplete: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: incomplete)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let (cached, work) = await Self.measure("report-contract", fixture: fixture, recorder: recorder) {
            await fixture.cachedSnapshot()
        }
        try fixture.expectSnapshot(cached)

        #expect(work.tokenSnapshotRows == 0)
        #expect(work.bufferedLines == 0)
        #expect(work.bufferedPayloadBytes == 0)
        #expect(work.accumulatorRows == 0)
        #expect(work.usageRows == 0)
        #expect(work.usageRowDecodeAttempts == 0)
        #expect(work.usagePayloadBytes == 0)
        #expect(work.retryPresenceRows == (incomplete ? 1 : 0))
        #expect(work.readViewConversions == 1)
        #expect(work.readViewConversionsInTransaction == 0)
    }

    private static func measure<Value>(
        _ operation: String,
        fixture: ReadWorkFixture,
        recorder: CostUsageStoreReadWorkRecorder,
        work: () async -> Value) async -> (Value, CostUsageStoreReadWorkMetrics)
    {
        recorder.reset()
        let started = ContinuousClock.now
        let value = await work()
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let metrics = recorder.snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(metrics)).flatMap { String(data: $0, encoding: .utf8) } ?? "encoding-failed"
        print("[cost-store-read-proof] files=\(fixture.fileCount) rows=\(fixture.rowCount) " +
            "incomplete=\(fixture.incomplete) op=\(operation) elapsed_ms=\(milliseconds) metrics=\(json)")
        return (value, metrics)
    }
}

struct ReadWorkFixture {
    static let day = "2026-08-01"
    static let model = "gpt-5.4"
    let env: CostUsageTestEnvironment
    let calendar: Calendar
    let now: Date
    let options: CostUsageScanner.Options
    let store: CostUsageStore
    let canonical: CostUsageCache
    let fileCount: Int
    let rowCount: Int
    let incomplete: Bool

    init(fileCount: Int, rowsPerFile: Int, incomplete: Bool = false) throws {
        let env = try CostUsageTestEnvironment()
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12)))
            let trace = env.root.appendingPathComponent("missing-trace.sqlite")
            let options = CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot,
                claudeProjectsRoots: [env.claudeProjectsRoot],
                cacheRoot: env.cacheRoot,
                codexTraceDatabaseURL: trace,
                calendar: calendar)
            let range = CostUsageScanner.CostUsageDayRange(since: now, until: now, calendar: calendar)
            var cache = CostUsageCache()
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.timeZoneIdentifier = calendar.timeZone.identifier
            cache.lastScanUnixMs = Int64(now.timeIntervalSince1970 * 1000)
            cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
            cache.codexPricingKey = CostUsageScanner.codexPricingKey(modelsDevArtifact: nil)
            cache.codexPriorityMetadataKey = "missing:\(trace.standardizedFileURL.path)"
            cache.codexProjectMetadataVersion = CostUsageScanner.codexProjectMetadataVersion
            for index in 0..<fileCount {
                let url = env.codexSessionsRoot.appendingPathComponent("fixture-\(index).jsonl")
                cache.files[url.path] = try Self.usage(
                    url: url, index: index, rowCount: rowsPerFile, incomplete: incomplete && index == 0)
            }
            cache.days = [Self.day: [Self.model: [
                fileCount * rowsPerFile * 10,
                fileCount * rowsPerFile * 2,
                fileCount * rowsPerFile * 3,
            ]]]
            cache.codexScanCatchUpPending = incomplete
            cache.codexScanCompletedFiles = fileCount - (incomplete ? 1 : 0)
            cache.codexScanTotalFiles = fileCount
            cache.codexScanProcessedBytes = cache.files.values.reduce(0) { $0 + ($1.parsedBytes ?? 0) }
            cache.codexScanTotalBytes = cache.files.values.reduce(0) { $0 + $1.size }
            cache.codexScanInventoryPaths = cache.files.keys.sorted()
            let store = CostUsageStore(cacheRoot: env.cacheRoot)
            let saved = store.syncSaveCodexCache(
                cache,
                calendar: calendar,
                requestedScanWindow: (sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey))
            try #require(!saved.catchUpRequired)
            self.env = env
            self.calendar = calendar
            self.now = now
            self.options = options
            self.store = store
            self.canonical = store.syncLoadCodexCache(calendar: calendar)
            self.fileCount = fileCount
            self.rowCount = fileCount * rowsPerFile
            self.incomplete = incomplete
            #expect(self.canonical.files.count == fileCount)
            #expect(self.canonical.files.values.reduce(0) { $0 + ($1.codexRows?.count ?? 0) } == self.rowCount)
            #expect(self.canonical.files.values.allSatisfy { !CostUsageScanner.needsCodexPricingMetadata($0) })
        } catch {
            env.cleanup()
            throw error
        }
    }

    func save(_ cache: CostUsageCache) -> CostUsageStoreBudgetResult {
        self.store.syncSaveCodexCache(
            cache,
            calendar: self.calendar,
            requestedScanWindow: (sinceKey: self.canonical.scanSinceKey!, untilKey: self.canonical.scanUntilKey!),
            skipIdenticalContent: true)
    }

    func cachedSnapshot(
        options: CostUsageScanner.Options? = nil,
        historyDays: Int = 1,
        details: Bool = false) async -> CostUsageFetcher.CachedCodexTokenSnapshotResult?
    {
        if details {
            return await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
                now: self.now,
                historyDays: historyDays,
                includePiSessions: false,
                scannerOptions: options ?? self.options)
        }
        return await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: self.now,
            historyDays: historyDays,
            includePiSessions: false,
            includeProjectAndSessionBreakdowns: false,
            scannerOptions: options ?? self.options)
    }

    func expectStatus(_ status: CostUsageFetcher.CodexScanCatchUpStatus) {
        #expect(status.pending == self.incomplete)
        #expect(status.totalFiles == self.fileCount)
        #expect(status.completedFiles == self.fileCount - (self.incomplete ? 1 : 0))
        #expect(status.processedBytes == self.canonical.codexScanProcessedBytes)
        #expect(status.totalBytes == self.canonical.codexScanTotalBytes)
        #expect(status.progressKey == CostUsageFetcher.codexScanProgressKey(
            cache: self.canonical, scopedFiles: self.canonical.files))
    }

    func expectSnapshot(_ result: CostUsageFetcher.CachedCodexTokenSnapshotResult?, details: Bool = false) throws {
        let result = try #require(result)
        #expect(result.snapshot.historyCoverageIsEstablished == !self.incomplete)
        #expect(result.snapshot.last30DaysTokens == self.rowCount * 13)
        #expect(result.snapshot.sessionTokens == self.rowCount * 13)
        #expect(result.snapshot.daily.count == 1)
        let cost = try #require(result.snapshot.last30DaysCostUSD)
        #expect(abs(cost - Double(self.rowCount) * 0.001) < 0.000000001)
        if details {
            let range = CostUsageScanner.CostUsageDayRange(since: self.now, until: self.now, calendar: self.calendar)
            #expect(result.snapshot.projects == self.fullCachedSnapshot(cache: self.canonical).projects)
            #expect(result.snapshot.sessions == CostUsageScanner.buildCodexSessionBreakdownsFromCache(
                cache: self.canonical,
                range: range,
                modelsDevCacheRoot: self.env.cacheRoot,
                sessionRoots: CostUsageScanner.codexSessionsRoots(options: self.options)))
            #expect(result.snapshot.projects.count == 1)
            #expect(result.snapshot.sessions.count == self.fileCount)
            #expect(result.snapshot.projects.first?.totalTokens == self.rowCount * 13)
            #expect(result.snapshot.sessions.allSatisfy { $0.totalTokens == self.rowCount / self.fileCount * 13 })
        } else {
            #expect(result.snapshot.projects.isEmpty)
            #expect(result.snapshot.sessions.isEmpty)
        }
        #expect(result.lastRefreshAt == self.now)
        #expect(result.snapshot.updatedAt == self.now)
    }

    func remove() {
        self.env.cleanup()
    }

    private static func usage(
        url: URL,
        index: Int,
        rowCount: Int,
        incomplete: Bool) throws -> CostUsageFileUsage
    {
        let timestamp = "2026-08-01T12:00:00Z"
        let tokenLine = """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}
        """
        let contents = Array(repeating: tokenLine, count: rowCount).joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: url)
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: url)
        var usage = CostUsageFileUsage(
            mtimeUnixMs: metadata.mtimeUnixMs,
            size: metadata.size,
            days: [Self.day: [Self.model: [rowCount * 10, rowCount * 2, rowCount * 3]]])
        usage.parsedBytes = metadata.size
        usage.codexScanFileId = metadata.fileId
        usage.codexScanTargetSize = metadata.size
        usage.codexScanComplete = !incomplete
        usage.sessionId = "fixture-session-\(index)"
        usage.projectPath = url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("owned-project").path
        usage.canonicalProjectPath = usage.projectPath
        usage.codexSession = .init(sessionId: usage.sessionId, cwd: usage.projectPath, title: "Fixture \(index)")
        usage.lastCountedTotals = .init(input: rowCount * 10, cached: rowCount * 2, output: rowCount * 3)
        usage.codexCostCacheComplete = true
        usage.codexStandardTokens = [Self.day: [Self.model: rowCount * 13]]
        usage.codexTokenTimestampsMonotonic = true
        usage.codexRows = (0..<rowCount).map { event in
            CostUsageScanner.CodexUsageRow(
                day: Self.day,
                model: Self.model,
                turnID: "fixture-\(index)-\(event)",
                eventIndex: event,
                input: 10,
                cached: 2,
                output: 3,
                knownCostNanos: 1_000_000,
                pricingModel: Self.model,
                pricingMode: "standard")
        }
        usage.codexTokenSnapshots = (0..<rowCount).map { event in
            CostUsageCodexTokenSnapshot(
                timestamp: timestamp,
                last: CostUsageCodexTotals(input: 10, cached: 2, output: 3),
                total: nil,
                endOffset: Int64((event + 1) * (tokenLine.utf8.count + 1)))
        }
        if incomplete {
            usage.codexBufferedUnresolvedForkLines = [CostUsageScanner.CodexBufferedFastLine(
                lineIndex: rowCount,
                ordinal: rowCount,
                endOffset: metadata.size,
                line: .taskStarted(turnID: "fixture-replay"))]
        }
        return usage
    }
}
