import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreCodexCostCatchUpTests {
    @Test(arguments: [CodexCurrentWindowFixture.Kind.historical, .unresolved], ["normal", "low-power", "thermal"])
    func `cached native readiness is checked before the first duty-cycle or resource-pause sleep`(
        _ kind: CodexCurrentWindowFixture.Kind, resource: String) async throws
    {
        let fixture = try CodexCurrentWindowFixture(kind: kind)
        defer { fixture.base.remove() }
        let store = try Self.makeStore(suite: "native-pre-sleep")
        defer { store.cancelCodexCostCatchUp() }
        store.settings.costUsageHistoryDays = 1
        store.settings.backgroundWorkLowPowerModePreference = .off
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, resource == "low-power", resource == "thermal" ? .serious : .nominal)
        }
        var advances = 0
        var sleeps = 0
        var widgets: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgets.append($0) }
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: fixture.base.now), provider: .codex)
        store._test_codexCostCatchUpStatusOverride = { _ in
            await CostUsageFetcher(scannerOptions: fixture.base.options).codexScanCatchUpStatus()
        }
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, days in
            #expect(days == 1)
            return await fixture.strictSnapshot().map { ($0.snapshot, $0.lastRefreshAt, $0.staleSnapshotUpdatedAt) }
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advances += 1
            return .init(pending: false, progressKey: "unexpected-scan")
        }
        store._test_codexCostCatchUpSleepOverride = { delay in
            sleeps += 1
            #expect(delay == (resource == "normal" ? 1998 : CodexCostCatchUpPolicy.constrainedRetryDelay))
            #expect(advances == 0)
            if resource != "normal" {
                #expect(store.codexCostCatchUpActivity?.phase == .paused)
                #expect(store.codexCostCatchUpActivity?.pauseReason == (resource == "thermal" ? .thermal : .lowPower))
            }
            if kind == .historical {
                #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 52)
                #expect(store.tokenSnapshot(for: .codex)?.updatedAt == fixture.base.now)
                #expect(store.lastTokenFetchAt[.codex] == fixture.base.now)
            } else {
                #expect(store.tokenSnapshot(for: .codex) == nil)
                #expect(store.lastTokenFetchAt[.codex] == nil)
            }
            throw CancellationError()
        }

        store.startCodexCostCatchUpIfNeeded()
        await store.codexCostCatchUpTask?.value
        await store.widgetSnapshotPersistTask?.value

        #expect(sleeps == 1)
        #expect(advances == 0)
        if kind == .historical {
            let widget = try #require(widgets.last?.entries.first { $0.provider == .codex })
            #expect(widget.tokenUsage?.last30DaysTokens == 52)
            #expect(widget.tokenUsage?.updatedAt == fixture.base.now)
        }
        store._test_widgetSnapshotSaveOverride = nil
    }

    @Test
    func `a ready native window publishes before a genuine no-progress pause`() async throws {
        let fixture = try CodexCurrentWindowFixture(kind: .incompleteCost)
        defer { fixture.base.remove() }
        let store = try Self.makeStore(suite: "native-no-progress")
        defer { store.cancelCodexCostCatchUp() }
        store.settings.costUsageHistoryDays = 1
        store.settings.backgroundWorkLowPowerModePreference = .off
        store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        let fetcher = CostUsageFetcher(scannerOptions: fixture.base.options)
        let initialStatus = await fetcher.codexScanCatchUpStatus()
        #expect(await fixture.strictSnapshot() == nil)
        var advances = 0
        var sleeps: [TimeInterval] = []
        store._test_codexCostCatchUpStatusOverride = { _ in await fetcher.codexScanCatchUpStatus() }
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in
            await fixture.strictSnapshot().map { ($0.snapshot, $0.lastRefreshAt, $0.staleSnapshotUpdatedAt) }
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advances += 1
            var cache = CostUsageStoreAccess.read(
                cacheRoot: fixture.base.env.cacheRoot,
                calendar: fixture.base.calendar)
            cache.files[fixture.pendingURL.path]?.codexCostCacheComplete = true
            CostUsageStoreAccess.replace(
                cacheRoot: fixture.base.env.cacheRoot, cache: cache, calendar: fixture.base.calendar)
            let status = await fetcher.codexScanCatchUpStatus()
            #expect(status.pending)
            #expect(status.progressKey == initialStatus.progressKey)
            return status
        }
        store._test_codexCostCatchUpSleepOverride = { delay in sleeps.append(delay) }

        store.startCodexCostCatchUpIfNeeded()
        await store.codexCostCatchUpTask?.value
        await store.widgetSnapshotPersistTask?.value

        #expect(advances == 1)
        #expect(sleeps == [1998])
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysTokens == 52)
        #expect(store.tokenSnapshot(for: .codex)?.updatedAt == fixture.base.now)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `automatic sleep uses active scan duration instead of awaited latency`() async throws {
        let store = try Self.makeStore(suite: "active-duration")
        store.settings.backgroundWorkLowPowerModePreference = .off
        var sleeps: [TimeInterval] = []
        store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store._test_codexCostCatchUpStatusOverride = { _ in
            .init(pending: true, progressKey: "pending")
        }
        store._test_codexCostCatchUpActiveDuration = 2
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            try await Task.sleep(for: .milliseconds(20))
            return .init(pending: true, progressKey: "progressed")
        }
        store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, _ in
            (Self.tokenSnapshot(cost: 1, now: now), now, nil)
        }
        store._test_codexCostCatchUpSleepOverride = { delay in
            sleeps.append(delay)
            if sleeps.count == 2 { throw CancellationError() }
        }
        store.startCodexCostCatchUpIfNeeded()
        let task = try #require(store.codexCostCatchUpTask)
        await task.value
        #expect(sleeps == [1998, 1998])
    }

    @Test(arguments: [CodexCostCatchUpPowerSource.ac, .battery, .unknown])
    func `app low power mode floors automatic catch-up decisions`(source: CodexCostCatchUpPowerSource) throws {
        let store = try Self.makeStore(suite: "app-low-power-policy")
        let resources = (source, false, ProcessInfo.ThermalState.nominal)
        store.settings.backgroundWorkLowPowerModePreference = .on
        let decision = store.codexCostCatchUpDecision(
            mode: .automatic, previousActiveDuration: 0.1, resourceState: resources)
        #expect(decision.action == .runAfter(1800))
        #expect(store.codexCostCatchUpDecision(
            mode: .accelerated, previousActiveDuration: 0.1, resourceState: resources).action == .runAfter(0))
        store.settings.backgroundWorkLowPowerModePreference = .off
        #expect(store.codexCostCatchUpDecision(
            mode: .automatic, previousActiveDuration: 0.1, resourceState: resources)
            == CodexCostCatchUpPolicy().decision(for: .init(
                mode: .automatic,
                previousActiveDuration: 0.1,
                powerSource: source,
                lowPowerModeEnabled: false,
                thermalState: .nominal)))
        store.settings.backgroundWorkLowPowerModePreference = .on
        #expect(store.codexCostCatchUpDecision(
            mode: .automatic,
            previousActiveDuration: nil,
            resourceState: (.ac, false, .nominal)).action == .runAfter(1998))
        #expect(store.codexCostCatchUpDecision(
            mode: .automatic,
            previousActiveDuration: 0.1,
            resourceState: (source, true, .nominal)).action == .pause(60, .lowPower))
        #expect(store.codexCostCatchUpDecision(
            mode: .automatic,
            previousActiveDuration: 0.1,
            resourceState: (source, true, .serious)).action == .pause(60, .thermal))
    }

    @Test(arguments: [CodexCostCatchUpMode.automatic, .accelerated])
    func `app low power preference survives current window priority`(mode: CodexCostCatchUpMode) async throws {
        let store = try Self.makeStore(suite: "app-low-power-worker")
        store.settings.backgroundWorkLowPowerModePreference = .on
        var sleeps: [TimeInterval] = []
        store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "pending")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "progressed")
        }
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in nil }
        store._test_codexCostCatchUpSleepOverride = { delay in
            sleeps.append(delay)
            if sleeps.count == 2 { throw CancellationError() }
        }
        store.startCodexCostCatchUpIfNeeded(mode: mode)
        let task = try #require(store.codexCostCatchUpTask)
        await task.value
        #expect(sleeps.count == 2)
        if mode == .automatic {
            #expect(sleeps == [1998, 1800])
        } else {
            #expect(sleeps == [0, 0])
        }
    }

    @Test
    func `combined low power and thermal pressure publishes thermal pause without scanning`() async throws {
        let store = try Self.makeStore(suite: "combined-thermal-pause")
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(pending: true, progressKey: "pending")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(pending: false, progressKey: "complete")
        }
        store._test_codexCostCatchUpResourceStateOverride = { (.battery, true, .serious) }
        store._test_codexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            throw CancellationError()
        }

        store.startCodexCostCatchUpIfNeeded()
        let task = try #require(store.codexCostCatchUpTask)
        await task.value

        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .thermal)
        #expect(sleepDurations == [CodexCostCatchUpPolicy.constrainedRetryDelay])
        #expect(advanceCount == 0)
    }

    @Test
    func `incomplete refresh cannot replace an established same-scope snapshot`() throws {
        let store = try Self.makeStore(suite: "retains-established")
        store.publishTokenSnapshot(Self.tokenSnapshot(cost: 3, now: Date()), for: .codex)
        let establishedRevision = store.tokenSnapshotPublicationRevision(for: .codex)

        store.publishTokenSnapshot(
            Self.tokenSnapshot(
                cost: 9,
                now: Date().addingTimeInterval(1),
                historyCoverageIsEstablished: false),
            for: .codex)

        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 3)
        #expect(store.tokenSnapshot(for: .codex)?.historyCoverageIsEstablished == true)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == establishedRevision)

        store.publishTokenSnapshot(
            Self.tokenSnapshot(cost: 4, now: Date().addingTimeInterval(2)),
            for: .codex)

        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 4)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == establishedRevision + 1)
    }

    @Test
    func `incomplete refresh does not retain an established snapshot from another scope`() throws {
        let store = try Self.makeStore(suite: "scope-change")
        store.publishTokenSnapshot(Self.tokenSnapshot(cost: 3, now: Date()), for: .codex)

        store.settings.costUsageHistoryDays = 7
        store.publishTokenSnapshot(
            Self.tokenSnapshot(
                cost: 9,
                now: Date().addingTimeInterval(1),
                historyCoverageIsEstablished: false),
            for: .codex)

        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 9)
        #expect(store.tokenSnapshot(for: .codex)?.historyCoverageIsEstablished == false)
    }

    @Test
    func `bounded catch-up publishes current window before historical completion`() async throws {
        let store = try Self.makeStore(suite: "publishes-final")
        var snapshotLoadCount = 0
        var cachedLoadCount = 0
        var statusLoadCount = 0
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_codexCostCatchUpActiveDuration = 2
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            snapshotLoadCount += 1
            return Self.tokenSnapshot(cost: Double(snapshotLoadCount), now: now)
        }
        store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, _ in
            cachedLoadCount += 1
            return (Self.tokenSnapshot(cost: advanceCount == 2 ? 1 : 2, now: now), now, nil)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: "status-\(statusLoadCount)")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            if advanceCount == 2 {
                #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 2)
            }
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
            store.codexCostCatchUpTask == nil && cachedLoadCount == 2
        }

        #expect(advanceCount == 2)
        #expect(statusLoadCount == 3)
        #expect(snapshotLoadCount == 1)
        #expect(cachedLoadCount == 2)
        #expect(sleepDurations == [1998, 1998])
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 1)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 3)
        #expect(store.tokenError(for: .codex) == nil)
    }

    @Test
    func `catch-up stops after one bounded pass that makes no progress`() async throws {
        let store = try Self.makeStore(suite: "no-progress")
        store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in nil }
        var snapshotLoadCount = 0
        var advanceCount = 0
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
        store._test_codexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_codexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        await store.refreshTokenUsage(.codex, force: true)
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil && advanceCount == 1
        }

        #expect(advanceCount == 1)
        #expect(snapshotLoadCount == 1)
        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 1)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == 1)
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `catch-up stops when bounded progress revisits an earlier semantic state`() async throws {
        let store = try Self.makeStore(suite: "cyclic-progress")
        let progressKeys = ["validation-1", "validation-2", "validation-0"]
        var advanceCount = 0
        store._test_codexCostCatchUpStatusOverride = { _ in
            CostUsageFetcher.CodexScanCatchUpStatus(
                pending: true,
                progressKey: "validation-0")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: true,
                progressKey: progressKeys[min(advanceCount - 1, progressKeys.count - 1)])
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

        #expect(advanceCount == 3)
        #expect(store.codexCostCatchUpActivity?.phase == .paused)
        #expect(store.codexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `catch-up continues when existing complete file backlog advances`() async throws {
        let store = try Self.makeStore(suite: "existing-complete-backlog")
        let first = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 125,
            days: [:],
            parsedBytes: 125,
            codexScanFileId: "1:1",
            codexScanComplete: true)
        let second = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 125,
            days: [:],
            parsedBytes: 125,
            codexScanFileId: "2:2",
            codexScanComplete: true)
        let files = [
            "/sessions/first.jsonl": first,
            "/sessions/second.jsonl": second,
        ]
        var caches = [CostUsageCache(), CostUsageCache(), CostUsageCache()]
        caches[0].codexScanCompletedFiles = 0
        caches[1].codexScanCompletedFiles = 1
        caches[2].codexScanCompletedFiles = 2
        let keys = caches.map {
            CostUsageFetcher.codexScanProgressKey(cache: $0, scopedFiles: files)
        }
        var statusLoadCount = 0
        var advanceCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, _ in
            guard advanceCount == 2 else { return nil }
            return (Self.tokenSnapshot(cost: 1, now: now), now, nil)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: statusLoadCount == 1,
                progressKey: statusLoadCount == 1 ? keys[0] : keys[2])
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: advanceCount < 2,
                progressKey: keys[advanceCount])
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

        #expect(Set(keys).count == 3)
        #expect(advanceCount == 2)
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
    }

    @Test
    func `a same-mode refresh queues a worker after the completing task`() async throws {
        let store = try Self.makeStore(suite: "same-mode-restart")
        var statusLoadCount = 0
        var advanceCount = 0
        store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, _ in
            guard advanceCount > 0 else { return nil }
            return (Self.tokenSnapshot(cost: 1, now: now), now, nil)
        }
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, now, _, _ in
            Self.tokenSnapshot(cost: 1, now: now)
        }
        store._test_codexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return CostUsageFetcher.CodexScanCatchUpStatus(
                pending: statusLoadCount == 2,
                progressKey: "status-\(statusLoadCount)")
        }
        store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
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

        store.startCodexCostCatchUpIfNeeded()
        store.startCodexCostCatchUpIfNeeded()
        await Self.waitUntil {
            store.codexCostCatchUpTask == nil && statusLoadCount == 3
        }

        #expect(statusLoadCount == 3)
        #expect(advanceCount == 1)
        #expect(store.codexCostCatchUpActivity?.phase == .complete)
    }

    @Test
    func `accelerated catch-up runs without an inter-pass delay and publishes progress`() async throws {
        let store = try Self.makeStore(suite: "accelerated")
        var statusLoadCount = 0
        var didAdvance = false
        store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, _ in
            guard didAdvance else { return nil }
            return (Self.tokenSnapshot(cost: 1, now: now), now, nil)
        }
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
            didAdvance = true
            return CostUsageFetcher.CodexScanCatchUpStatus(
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
    func `stopping an active pass clears a queued restart`() throws {
        let store = try Self.makeStore(suite: "stop-clears-restart")
        store.codexCostCatchUpTask = Task {}
        store.codexCostCatchUpPassIsRunning = true
        store.codexCostCatchUpRestartRequested = true

        store.stopCodexCostCatchUp()

        #expect(store.codexCostCatchUpStopRequested)
        #expect(!store.codexCostCatchUpRestartRequested)
        store.cancelCodexCostCatchUp()
    }

    private static func makeStore(suite: String) throws -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStoreCodexCostCatchUpTests-\(suite)",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, _ in
            (Self.tokenSnapshot(cost: 1, now: now), now, nil)
        }
        return store
    }

    private static func tokenSnapshot(
        cost: Double,
        now: Date,
        historyCoverageIsEstablished: Bool = true) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 10,
            last30DaysCostUSD: cost,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
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
