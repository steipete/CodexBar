import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test(arguments: [
        CodexCurrentWindowFixture.Kind.unresolved, .subagent, .missingParent, .incompleteCost, .unknownCost,
        .unparsedSuffix, .staleParser,
    ])
    func `old started incomplete sources cannot establish a current window`(
        _ kind: CodexCurrentWindowFixture.Kind) async throws
    {
        let fixture = try CodexCurrentWindowFixture(kind: kind)
        defer { fixture.base.remove() }
        let before = await fixture.base.store.readSnapshot()
        let bytes = try Data(contentsOf: fixture.pendingURL)
        let roots = CostUsageScanner.codexRootsFingerprint(options: fixture.base.options)
        for purpose in [CostUsageStoreReadPurpose.activity, .report] {
            let view = fixture.base.store.syncLoadCodexReadView(calendar: fixture.base.calendar, purpose: purpose)
            #expect(!view.historyCoverageIsEstablished(range: fixture.base.range, rootsFingerprint: roots))
        }
        let cached = try #require(await fixture.base.cachedSnapshot())
        #expect(cached.snapshot.last30DaysTokens == 13)
        #expect(cached.snapshot.updatedAt == fixture.previousTime)
        #expect(cached.staleSnapshotUpdatedAt == fixture.previousTime)
        #expect(await fixture.strictSnapshot() == nil)
        #expect(await fixture.base.store.readSnapshot() == before)
        #expect(try Data(contentsOf: fixture.pendingURL) == bytes)
    }

    @Test
    func `historical bookkeeping permits a measured current window without completing the scan`() async throws {
        let fixture = try CodexCurrentWindowFixture(kind: .historical)
        defer { fixture.base.remove() }
        let cached = try #require(await fixture.strictSnapshot())
        #expect(cached.snapshot.last30DaysTokens == 52)
        #expect(cached.snapshot.updatedAt == fixture.base.now)
        #expect(cached.lastRefreshAt == fixture.base.now)
        #expect(cached.staleSnapshotUpdatedAt == nil)
        let status = await CostUsageFetcher(scannerOptions: fixture.base.options).codexScanCatchUpStatus()
        #expect(status.pending)
    }

    @Test(arguments: ["session", "head", "idle"])
    func `pending session discovery blocks publication while an idle index permits it`(work: String) async throws {
        let fixture = try CodexCurrentWindowFixture(kind: .historical)
        defer { fixture.base.remove() }
        #expect(await fixture.strictSnapshot() != nil)
        var cache = CostUsageStoreAccess.read(
            cacheRoot: fixture.base.env.cacheRoot, calendar: fixture.base.calendar)
        let roots = try #require(cache.roots).keys.sorted()
        cache.codexSessionDiscovery = .init(
            roots: roots,
            directoryStamps: [:],
            directoryPaths: roots,
            nextDirectoryIndex: 0,
            filePaths: [fixture.pendingURL.path],
            nextFileIndex: 0,
            fileStamps: [:],
            headScan: work == "head" ? .init(path: fixture.pendingURL.path, offset: 0) : nil,
            filePathBySessionId: [:],
            missingSessionIds: ["confirmed-missing-parent"],
            pendingSessionIds: work == "session" ? ["pending-fixture-parent"] : [],
            validationDirectoryIndex: 0,
            isComplete: false)
        CostUsageStoreAccess.replace(
            cacheRoot: fixture.base.env.cacheRoot, cache: cache, calendar: fixture.base.calendar)
        let before = await fixture.base.store.readSnapshot()
        let bytes = try Data(contentsOf: fixture.pendingURL)
        let strict = await fixture.strictSnapshot()
        if work == "idle" {
            #expect(strict?.snapshot.last30DaysTokens == 52)
        } else {
            #expect(strict == nil)
            let retained = try #require(await fixture.base.cachedSnapshot())
            #expect(retained.snapshot.last30DaysTokens == 13)
            #expect(retained.staleSnapshotUpdatedAt == fixture.previousTime)
        }
        #expect(await fixture.base.store.readSnapshot() == before)
        #expect(try Data(contentsOf: fixture.pendingURL) == bytes)
        let status = await CostUsageFetcher(scannerOptions: fixture.base.options).codexScanCatchUpStatus()
        #expect(status.pending)
        cache.codexSessionDiscovery?.pendingSessionIds = []
        cache.codexSessionDiscovery?.headScan = nil
        CostUsageStoreAccess.replace(
            cacheRoot: fixture.base.env.cacheRoot, cache: cache, calendar: fixture.base.calendar)
        #expect(await fixture.strictSnapshot()?.snapshot.last30DaysTokens == 52)
    }

    @Test
    func `a retained activity view keeps its day evidence when satisfying a status read`() throws {
        let fixture = try CodexCurrentWindowFixture(kind: .historical)
        defer { fixture.base.remove() }
        let roots = CostUsageScanner.codexRootsFingerprint(options: fixture.base.options)
        let cold = fixture.base.store.syncLoadCodexReadView(calendar: fixture.base.calendar, purpose: .status)
        #expect(!cold.historyCoverageIsEstablished(range: fixture.base.range, rootsFingerprint: roots))
        let activity = fixture.base.store.syncLoadCodexReadView(calendar: fixture.base.calendar, purpose: .activity)
        #expect(activity.historyCoverageIsEstablished(range: fixture.base.range, rootsFingerprint: roots))
        let retained = fixture.base.store.syncLoadCodexReadView(calendar: fixture.base.calendar, purpose: .status)
        #expect(retained.historyCoverageIsEstablished(range: fixture.base.range, rootsFingerprint: roots))
    }

    @Test
    func `unresolved work without a retained report stays explicitly incomplete`() async throws {
        let fixture = try CodexCurrentWindowFixture(kind: .unresolved, retainedReport: false)
        defer { fixture.base.remove() }
        let cached = try #require(await fixture.base.cachedSnapshot())
        #expect(cached.snapshot.last30DaysTokens == 52)
        #expect(!cached.snapshot.historyCoverageIsEstablished)
        #expect(await fixture.strictSnapshot() == nil)
    }

    @Test
    func `the final report rechecks readiness after activity evidence was accepted`() async throws {
        let fixture = try CodexCurrentWindowFixture(kind: .historical)
        defer { fixture.base.remove() }
        #expect(await fixture.strictSnapshot() != nil)
        let writer = try BaselineSQLiteConnection(url: fixture.base.store.databaseURL)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.base.store.databaseURL)
        let writes = LockIsolated(0)
        let inTransaction = LockIsolated(-1)
        let failure = LockIsolated<String?>(nil)
        CostUsageStore.readWorkRecorderForTesting = recorder
        CostUsageStore.codexCatchUpReconciliationVisitForTesting = {
            let work = recorder.snapshot()
            guard work.readViewConversions == 2, writes.value == 0 else { return }
            writes.setValue(1)
            inTransaction.setValue(work.readViewConversionsInTransaction)
            do {
                try writer.execute("UPDATE files SET scan_complete = 0 WHERE session_id = 'fixture-session-0'")
            } catch {
                failure.setValue(error.localizedDescription)
            }
        }
        defer {
            CostUsageStore.codexCatchUpReconciliationVisitForTesting = nil
            CostUsageStore.readWorkRecorderForTesting = nil
        }

        let result = await fixture.strictSnapshot()
        let work = recorder.snapshot()
        CostUsageStore.codexCatchUpReconciliationVisitForTesting = nil
        CostUsageStore.readWorkRecorderForTesting = nil

        #expect(result == nil)
        #expect(writes.value == 1)
        #expect(failure.value == nil)
        #expect(inTransaction.value == 0)
        #expect(work.readViewConversions == 3)
        #expect(work.readViewConversionsInTransaction == 0)
        #expect(work.usageRowDecodeAttempts > 0)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.bufferedLines == 0)
        #expect(work.bufferedPayloadBytes == 0)
        let retained = try #require(await fixture.base.cachedSnapshot())
        #expect(retained.snapshot.last30DaysTokens == 13)
        #expect(retained.staleSnapshotUpdatedAt == fixture.previousTime)
    }

    @Test
    func `status reads cannot infer current day absence from omitted aggregates`() throws {
        let fixture = try CodexCurrentWindowFixture(kind: .currentMigration)
        defer { fixture.base.remove() }
        let roots = CostUsageScanner.codexRootsFingerprint(options: fixture.base.options)
        for purpose in [CostUsageStoreReadPurpose.status, .activity, .report] {
            let view = fixture.base.store.syncLoadCodexReadView(calendar: fixture.base.calendar, purpose: purpose)
            #expect(!view.historyCoverageIsEstablished(range: fixture.base.range, rootsFingerprint: roots))
        }
    }
}

struct CodexCurrentWindowFixture {
    enum Kind: Sendable {
        case historical, unresolved, subagent, missingParent, incompleteCost, unknownCost, unparsedSuffix
        case staleParser, currentMigration
    }

    let base: ReadWorkFixture
    let pendingURL: URL
    let previousTime: Date

    init(kind: Kind, retainedReport: Bool = true) throws {
        let base = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        do {
            var cache = base.canonical
            let path = try #require(cache.files.keys.max())
            let url = URL(fileURLWithPath: path)
            let oldDay = "2026-06-01"
            let hasCurrentEvents = [.unresolved, .subagent, .missingParent, .currentMigration].contains(kind)
            let eventDay = hasCurrentEvents ? ReadWorkFixture.day : oldDay
            let header = #"{"type":"session_meta","timestamp":"2026-06-01T12:00:00Z","# +
                #""payload":{"session_id":"fixture-session-1"}}"#
            let record = Self.tokenRecord(day: eventDay)
            let prefix = ([header] + Array(repeating: record, count: 4)).joined(separator: "\n") + "\n"
            let contents = kind == .unparsedSuffix ? prefix + Self.tokenRecord(day: ReadWorkFixture.day) + "\n" : prefix
            try Data(contents.utf8).write(to: url)
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: url)
            var usage = try #require(cache.files[path])
            usage.size = metadata.size
            usage.mtimeUnixMs = metadata.mtimeUnixMs
            usage.codexScanFileId = metadata.fileId
            usage.codexScanTargetSize = metadata.size
            usage.parsedBytes = metadata.size
            let oldTime = try #require(base.calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12)))
            usage.codexSession?.startedAtUnixMs = Int64(oldTime.timeIntervalSince1970 * 1000)
            usage.codexSession?.latestActivityUnixMs = hasCurrentEvents || kind == .unparsedSuffix
                ? cache.lastScanUnixMs : Int64(oldTime.timeIntervalSince1970 * 1000)
            usage.codexJSONLResumeState = nil
            usage.codexTokenIndexAnchor = nil
            let day = kind == .currentMigration ? ReadWorkFixture.day : oldDay
            usage.days = [day: [ReadWorkFixture.model: [40, 8, 12]]]
            usage.codexStandardTokens = [day: [ReadWorkFixture.model: 52]]
            usage.codexCostNanos = [day: [ReadWorkFixture.model: 4_000_000]]
            usage.codexStandardCostNanos = nil
            usage.codexPriorityCostNanos = nil
            usage.codexPrioritySurchargeNanos = nil
            usage.codexPriorityTokens = nil
            usage.codexRows = (0..<4).map { (index: Int) in
                .init(
                    day: day,
                    model: ReadWorkFixture.model,
                    turnID: "history-\(index)",
                    eventIndex: index,
                    input: 10,
                    cached: 2,
                    output: 3,
                    knownCostNanos: 1_000_000,
                    pricingModel: ReadWorkFixture.model,
                    pricingMode: "standard")
            }
            usage.codexTokenSnapshots = nil
            switch kind {
            case .unresolved, .subagent, .missingParent:
                usage.days = [:]
                usage.codexRows = []
                usage.codexStandardTokens = [:]
                usage.codexCostNanos = nil
                if kind != .subagent {
                    usage.forkedFromId = "missing-fixture-parent"
                    usage.forkBaselineDependencyKey = "missing|fixture-parent"
                }
                let buffered = CostUsageScanner.CodexBufferedFastLine(
                    lineIndex: 4,
                    ordinal: 4,
                    endOffset: metadata.size,
                    line: .tokenCount(.init(
                        timestamp: "2026-08-01T12:00:00Z",
                        model: ReadWorkFixture.model,
                        turnID: "fixture-owned-candidate",
                        last: .init(input: 10, cached: 2, output: 3),
                        total: .init(input: 110, cached: 22, output: 33))))
                if kind == .unresolved { usage.codexBufferedUnresolvedForkLines = [buffered] }
                if kind == .subagent { usage.codexBufferedSubagentLines = [buffered] }
            case .incompleteCost: usage.codexCostCacheComplete = false
            case .unknownCost: usage.codexCostCacheComplete = nil
            case .unparsedSuffix:
                usage.parsedBytes = Int64(prefix.utf8.count)
                usage.codexScanComplete = false
            case .staleParser: usage.codexParserRevision = nil
            case .historical, .currentMigration: break
            }
            cache.files[path] = usage
            cache.days = [:]
            for file in cache.files
                .values
            {
                CostUsageScanner.applyFileDays(cache: &cache, fileDays: file.days, sign: 1)
            }
            cache.codexScanCatchUpPending = true
            cache.codexScanInventoryPaths = nil
            let roots = CostUsageScanner.codexSessionsRoots(options: base.options)
                .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
            let queue = [.staleParser, .unparsedSuffix].contains(kind) ? [] : [path]
            cache.codexActiveLookbackState = .init(
                scanSinceKey: base.range.scanSinceKey,
                rootPaths: roots,
                completedRootPaths: roots,
                pendingFilePaths: queue,
                legacyRecursivePendingRootPaths: [],
                completedCurrentWindowRootPaths: roots,
                completedCurrentWindowFlatRootPaths: roots,
                cacheWideMigrationQueueActive: true)
            var previousCache = base.canonical
            previousCache.lastScanUnixMs -= 60000
            self.previousTime = Date(timeIntervalSince1970: Double(previousCache.lastScanUnixMs) / 1000)
            if retainedReport {
                cache.codexPreviousReport = CostUsageCodexPreviousReport(
                    report: .init(data: [.init(
                        date: ReadWorkFixture.day,
                        inputTokens: 10,
                        outputTokens: 3,
                        totalTokens: 13,
                        costUSD: nil,
                        modelsUsed: [ReadWorkFixture.model],
                        modelBreakdowns: nil)], summary: nil),
                    cache: previousCache,
                    reportSinceKey: base.range.sinceKey,
                    reportUntilKey: base.range.untilKey)
            }
            CostUsageStoreAccess.replace(cacheRoot: base.env.cacheRoot, cache: cache, calendar: base.calendar)
            self.base = base
            self.pendingURL = url
        } catch {
            base.remove()
            throw error
        }
    }

    private static func tokenRecord(day: String) -> String {
        """
        {"type":"event_msg","timestamp":"\(day)T12:00:00Z","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}
        """
    }

    func strictSnapshot() async -> CostUsageFetcher.CachedCodexTokenSnapshotResult? {
        await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: self.base.now,
            historyDays: 1,
            includePiSessions: false,
            requireCompleteHistory: true,
            scannerOptions: self.base.options)
    }
}
