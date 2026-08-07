import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreCodexCostCatchUpTests {
    @Test
    func `bounded catch-up automatically publishes only the final stable snapshot`() async throws {
        let store = try Self.makeStore(suite: "publishes-final")
        var snapshotLoadCount = 0
        var statusLoadCount = 0
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            snapshotLoadCount += 1
            return Self.tokenSnapshot(cost: Double(snapshotLoadCount), now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: statusLoadCount == 1,
                progressKey: "status-\(statusLoadCount)")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: "advance-\(advanceCount)")
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        await store.refreshTokenUsage(.codex, force: true)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil && snapshotLoadCount == 2
        }

        #expect(advanceCount == 2)
        #expect(statusLoadCount == 2)
        #expect(snapshotLoadCount == 2)
        #expect(sleepDurations.first == 8)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 2)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 2)
        #expect(store.tokenError(for: .codex) == nil)
    }

    @Test
    func `catch-up retries one unchanged pass before declaring no progress`() async throws {
        let store = try Self.makeStore(suite: "no-progress")
        var snapshotLoadCount = 0
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            snapshotLoadCount += 1
            return Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "unchanged")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "unchanged")
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        await store.refreshTokenUsage(.codex, force: true)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil && advanceCount == 2
        }

        #expect(advanceCount == 2)
        #expect(sleepDurations.contains(1))
        #expect(snapshotLoadCount == 1)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 1)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 1)
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `transient unchanged pass backs off and can recover`() async throws {
        let store = try Self.makeStore(suite: "transient-no-progress")
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: advanceCount < 2 ? "unchanged" : "complete")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: advanceCount < 2 ? "unchanged" : "complete")
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(advanceCount == 2)
        #expect(sleepDurations.contains(1))
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
        #expect(store.codexCostCatchUpActivity?.pauseReason == nil)
    }

    @Test
    func `concurrent writer contention retries even when the published cache still looks complete`() async throws {
        let store = try Self.makeStore(suite: "concurrent-writer")
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: advanceCount < 2 ? "published-before-owner" : "complete")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            if advanceCount == 1 {
                return CostUsageFetcher.CodexScanCatchUpStatus(
                    pending: false,
                    progressKey: "published-before-owner",
                    deferredByConcurrentWriter: true)
            }
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: false,
                progressKey: "complete")
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(advanceCount == 2)
        #expect(sleepDurations.contains(1))
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
        #expect(store.codexCostCatchUpActivity?.pauseReason == nil)
    }

    @Test
    func `unavailable refresh lock is retryable and backs off`() async throws {
        let store = try Self.makeStore(suite: "unavailable-refresh-lock")
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: advanceCount < 2 ? "published-before-lock" : "complete")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            if advanceCount == 1 {
                return CostUsageFetcher.CodexScanCatchUpStatus(
                    pending: false,
                    progressKey: "published-before-lock",
                    refreshLockUnavailable: true)
            }
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: false,
                progressKey: "complete")
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(advanceCount == 2)
        #expect(sleepDurations.contains(1))
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
        #expect(store.codexCostCatchUpActivity?.pauseReason == nil)
    }

    @Test
    func `repeated unavailable refresh lock pauses with an error`() async throws {
        let store = try Self.makeStore(suite: "unavailable-refresh-lock-stalls")
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "unavailable")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: false,
                progressKey: "unavailable",
                refreshLockUnavailable: true)
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(advanceCount == 2)
        #expect(sleepDurations.count(where: { $0 == 1 }) == 1)
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .error(
            CostUsageFetcher.CodexScanCatchUpStatus.refreshLockUnavailableErrorMessage))
    }

    @Test
    func `initial complete cache stays pending while another writer owns the lock`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreInitialLockProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: sessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: cacheRoot)
        var cache = CostUsageCache()
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.codexScanCatchUpPending = false
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)

        let acquisition = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: cacheRoot)
        guard case let .acquired(lease) = acquisition else {
            Issue.record("Expected the test to own the refresh lock")
            return
        }
        defer { lease.release() }

        let store = try Self.makeStore(
            suite: "initial-complete-lock-probe",
            costUsageFetcher: CostUsageFetcher(scannerOptions: options))
        var advanceCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            lease.release()
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: false,
                progressKey: "complete")
        }
        store._test_codexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(advanceCount == 1)
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
        #expect(store.codexCostCatchUpActivity?.pauseReason == nil)
    }

    @Test
    func `final snapshot does not finish while another writer owns the lock`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreFinalLockProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: sessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: cacheRoot)
        var cache = CostUsageCache()
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.codexScanCatchUpPending = true
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)

        let store = try Self.makeStore(
            suite: "final-snapshot-lock-probe",
            costUsageFetcher: CostUsageFetcher(scannerOptions: options))
        var advanceCount = 0
        var snapshotLoadCount = 0
        var finalSnapshotLease: CostUsageCodexRefreshLock.Lease?
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            snapshotLoadCount += 1
            if snapshotLoadCount == 1 {
                let acquisition = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: cacheRoot)
                guard case let .acquired(lease) = acquisition else {
                    throw CancellationError()
                }
                finalSnapshotLease = lease
            }
            return Self.tokenSnapshot(cost: Double(snapshotLoadCount), now: now)
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            if advanceCount == 1 {
                cache.codexScanCatchUpPending = false
                CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
            } else {
                finalSnapshotLease?.release()
                finalSnapshotLease = nil
            }
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: false,
                progressKey: "complete")
        }
        store._test_codexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }
        finalSnapshotLease?.release()

        #expect(advanceCount == 2)
        #expect(snapshotLoadCount == 2)
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
        #expect(store.codexCostCatchUpActivity?.pauseReason == nil)
    }

    @Test
    func `accelerated catch-up runs without an inter-pass delay and publishes progress`() async throws {
        let store = try Self.makeStore(suite: "accelerated")
        var statusLoadCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: statusLoadCount == 1,
                progressKey: "status-\(statusLoadCount)",
                processedBytes: statusLoadCount == 1 ? 25 : 100,
                totalBytes: 100,
                completedFiles: statusLoadCount == 1 ? 0 : 1,
                totalFiles: 1)
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: false,
                progressKey: "complete",
                processedBytes: 100,
                totalBytes: 100,
                completedFiles: 1,
                totalFiles: 1)
        }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.battery, true, .serious)
        }

        store.startCodexCostCatchUpIfNeeded(mode: .accelerated)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(sleepDurations.first == 0)
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
        #expect(store.codexCostCatchUpActivity?.mode == .accelerated)
        #expect(store.codexCostCatchUpActivity?.fractionCompleted == 1)
    }

    @Test
    func `stop during an idle delay preserves progress without starting a pass`() async throws {
        let store = try Self.makeStore(suite: "stop-idle")
        var advanceCount = 0
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: true,
                progressKey: "partial",
                processedBytes: 50,
                totalBytes: 100)
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(pending: false, progressKey: "unexpected")
        }
        store._test_codexCostCatchUpSleepOverride = { _ in
            store.stopCodexCostCatchUp()
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startCodexCostCatchUpIfNeeded()
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil
        }

        #expect(advanceCount == 0)
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .user)
        #expect(store.codexCostCatchUpActivity?.fractionCompleted == 0.5)
    }

    @Test
    func `settled deferred fork does not keep catch-up pending`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreSettledFork-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: sessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: cacheRoot)
        var usage = CostUsageFileUsage(mtimeUnixMs: 1, size: 100, days: [:])
        usage.sessionId = "settled-child"
        usage.forkedFromId = "missing-parent"
        usage.forkBaselineDependencyKey = "missing|settled"
        usage.codexDeferredForkScan = true
        usage.codexScanComplete = false

        var cache = CostUsageCache()
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.codexScanCatchUpPending = false
        cache.files[sessionsRoot.appendingPathComponent("settled-child.jsonl").path] = usage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)

        let settled = await CostUsageFetcher(cacheRoot: cacheRoot)
            .codexScanCatchUpStatus(codexHomePath: codexHome.path)
        #expect(settled.pending == false)
        #expect(settled.historyCoverageIsEstablished == false)

        usage.forkBaselineDependencyKey = nil
        cache.files[sessionsRoot.appendingPathComponent("settled-child.jsonl").path] = usage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let retryable = await CostUsageFetcher(cacheRoot: cacheRoot)
            .codexScanCatchUpStatus(codexHomePath: codexHome.path)
        #expect(retryable.pending == true)
        #expect(retryable.historyCoverageIsEstablished == false)

        usage.codexDeferredForkScan = nil
        usage.forkBaselineDependencyKey = "missing|settled-replay"
        usage.codexDeferredReplayState = CostUsageCodexDeferredReplayState(
            phase: .replaying,
            mode: .inheritedSubagentFork,
            ownedSuffixStartOffset: nil,
            rawTotalsBaseline: nil,
            parentTotalsAtBoundary: nil,
            legacySubagentShape: nil,
            replayStarted: false)
        cache.files[sessionsRoot.appendingPathComponent("settled-child.jsonl").path] = usage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let settledReplay = await CostUsageFetcher(cacheRoot: cacheRoot)
            .codexScanCatchUpStatus(codexHomePath: codexHome.path)
        #expect(settledReplay.pending == false)
        #expect(settledReplay.historyCoverageIsEstablished == false)

        usage.forkBaselineDependencyKey = nil
        usage.codexDeferredReplayState?.phase = .indexing
        usage.codexDeferredReplayState?.mode = .legacySubagentClassification
        cache.files[sessionsRoot.appendingPathComponent("settled-child.jsonl").path] = usage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let indexing = await CostUsageFetcher(cacheRoot: cacheRoot)
            .codexScanCatchUpStatus(codexHomePath: codexHome.path)

        usage.codexDeferredReplayState?.phase = .replaying
        usage.codexDeferredReplayState?.mode = .independentSubagent
        cache.files[sessionsRoot.appendingPathComponent("settled-child.jsonl").path] = usage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let replayReady = await CostUsageFetcher(cacheRoot: cacheRoot)
            .codexScanCatchUpStatus(codexHomePath: codexHome.path)

        usage.codexDeferredReplayState?.replayStarted = true
        cache.files[sessionsRoot.appendingPathComponent("settled-child.jsonl").path] = usage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let replayStarted = await CostUsageFetcher(cacheRoot: cacheRoot)
            .codexScanCatchUpStatus(codexHomePath: codexHome.path)

        #expect(indexing.progressKey != replayReady.progressKey)
        #expect(replayReady.progressKey != replayStarted.progressKey)
    }

    @Test
    func `metadata only discovery passes keep Finish Now progress distinct`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreDiscoveryProgress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: sessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: cacheRoot)
        var cache = CostUsageCache()
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.codexScanCatchUpPending = true
        cache.codexSessionDiscovery = CostUsageCodexSessionDiscovery(
            roots: [sessionsRoot.standardizedFileURL.path],
            generation: "redacted-generation",
            directoryStamps: [:],
            directoryPaths: ["redacted-directory"],
            nextDirectoryIndex: 0,
            filePaths: ["redacted-a", "redacted-b", "redacted-c"],
            nextFileIndex: 0,
            fileStamps: [:],
            headScan: nil,
            filePathBySessionId: [:],
            missingSessionIds: [],
            pendingSessionIds: ["redacted-parent"],
            validationDirectoryIndex: 0,
            validationFileIndex: nil,
            isComplete: false)

        var progressKeys: [String] = []
        for cursor in 0...2 {
            cache.codexSessionDiscovery?.nextFileIndex = cursor
            CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
            let status = await CostUsageFetcher(cacheRoot: cacheRoot)
                .codexScanCatchUpStatus(codexHomePath: codexHome.path)
            #expect(status.pending == true)
            progressKeys.append(status.progressKey)
        }

        #expect(Set(progressKeys).count == progressKeys.count)

        let lastProgressKey = try #require(progressKeys.last)
        cache.codexDependencyLaneStartsNext = true
        cache.codexForegroundScheduleCursor = 99
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: cacheRoot)
        let schedulingOnly = await CostUsageFetcher(cacheRoot: cacheRoot)
            .codexScanCatchUpStatus(codexHomePath: codexHome.path)
        #expect(schedulingOnly.progressKey == lastProgressKey)
    }

    @Test
    func `fetcher surfaces an unavailable refresh lock as retryable work`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreUnavailableLock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let occupiedCacheRoot = root.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("occupied".utf8).write(to: occupiedCacheRoot)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexHome.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)

        let status = try await CostUsageFetcher(cacheRoot: occupiedCacheRoot)
            .advanceCodexScanCatchUp(
                now: Date(timeIntervalSince1970: 1_800_000_000),
                codexHomePath: codexHome.path,
                historyDays: 1)

        #expect(status.pending == true)
        #expect(status.refreshLockUnavailable == true)
        #expect(status.requiresTransientRetry == true)
        #expect(status.deferredByConcurrentWriter == false)
    }

    private static func makeStore(
        suite: String,
        costUsageFetcher: CostUsageFetcher = CostUsageFetcher()) throws -> UsageStore
    {
        let settings = testSettingsStore(suiteName: "UsageStoreCodexCostCatchUpTests-\(suite)")
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: costUsageFetcher,
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func tokenSnapshot(cost: Double, now: Date) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-07-30",
                inputTokens: 4,
                outputTokens: 6,
                totalTokens: 10,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now)
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool) async
    {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for Codex cost catch-up task")
    }
}
