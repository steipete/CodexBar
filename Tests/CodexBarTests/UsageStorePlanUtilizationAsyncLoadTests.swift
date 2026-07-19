import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Tests for the startup async plan-utilization history load.
///
/// The decode of the persisted `PlanUtilizationHistoryStore` is moved off the
/// startup main thread because a mature two-year history can take ~150 ms to
/// parse. These tests pin the contract:
///   - `UsageStore.init` returns before disk I/O completes
///   - the load publishes exactly once after the gate releases
///   - sync menu accessors return the empty stub (no migration, no persistence
///     enqueue) while the load is in flight
///   - mutation paths wait for the load before touching the dictionary so a
///     startup refresh cannot overwrite real disk history with empty stubs
struct UsageStorePlanUtilizationAsyncLoadTests {
    @MainActor
    @Test
    func `testing startup without an injected history store skips disk loading`() {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-default-test-\(UUID().uuidString)"
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.planUtilizationHistoryLoadTask == nil)
        #expect(store.planUtilizationHistoryLoaded == true)
        #expect(store.planUtilizationHistory.isEmpty)
        #expect(store.planUtilizationHistoryStore.directoryURL == nil)
    }

    @MainActor
    @Test
    func `testing startup without an explicit gate skips background load`() {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-testing-\(UUID().uuidString)"
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        historyStore.save([.codex: PlanUtilizationHistoryBuckets(
            preferredAccountKey: nil,
            unscoped: [planSeries(
                name: .session,
                windowMinutes: 300,
                entries: [planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 42)])],
            accounts: [:])])
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing)

        #expect(store.planUtilizationHistoryLoadTask == nil)
        #expect(store.planUtilizationHistoryLoaded)
        #expect(store.planUtilizationHistory.isEmpty)
    }

    @MainActor
    @Test
    func `init returns before disk load completes`() {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-init-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: false)
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = settings // silence unused
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        defer { store._cancelPlanUtilizationHistoryLoadForTesting() }

        // The gate is still closed, so the background load has not run.
        #expect(store.planUtilizationHistory.isEmpty)
        #expect(store.planUtilizationHistoryLoaded == false)
        #expect(gate.isOpen == false)
    }

    @MainActor
    @Test
    func `gate release publishes loaded history and bumps revision once`() async {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-release-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        let codexSeries = planSeries(
            name: .session,
            windowMinutes: 300,
            entries: [planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 42)])
        let buckets = PlanUtilizationHistoryBuckets(
            preferredAccountKey: nil,
            unscoped: [codexSeries],
            accounts: [:])
        historyStore.save([.codex: buckets])
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = settings
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        defer { store._cancelPlanUtilizationHistoryLoadForTesting() }

        let revisionBeforeOpen = store.planUtilizationHistoryRevision
        gate.open()
        await store._waitForPlanUtilizationHistoryLoadForTesting()

        #expect(store.planUtilizationHistoryLoaded == true)
        #expect(store.planUtilizationHistory[.codex]?.unscoped.first?.name == .session)
        // Revision must increment by exactly one when the load completes.
        #expect(store.planUtilizationHistoryRevision == revisionBeforeOpen + 1)
    }

    @MainActor
    @Test
    func `sync menu accessor returns empty stub while loading`() {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-menuGate-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        // Pre-populate disk so a loaded store would return real history.
        let series = planSeries(
            name: .weekly,
            windowMinutes: 10080,
            entries: [planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 88)])
        historyStore.save([.claude: PlanUtilizationHistoryBuckets(
            preferredAccountKey: nil,
            unscoped: [series],
            accounts: [:])])
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = settings
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        defer { store._cancelPlanUtilizationHistoryLoadForTesting() }

        let selection = store.planUtilizationHistorySelection(for: .claude)
        #expect(selection.accountKey == nil)
        #expect(selection.histories.isEmpty)
        #expect(store.planUtilizationHistory[.claude]?.preferredAccountKey == nil)
    }

    @MainActor
    @Test
    func `empty directory loads to empty dictionary without error`() async {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-empty-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = settings
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        defer { store._cancelPlanUtilizationHistoryLoadForTesting() }

        gate.open()
        await store._waitForPlanUtilizationHistoryLoadForTesting()

        #expect(store.planUtilizationHistory.isEmpty)
        #expect(store.planUtilizationHistoryLoaded == true)
    }

    @MainActor
    @Test
    func `corrupt file loads best-effort empty`() async throws {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-corrupt-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        // Write a file that does not parse as the expected schema.
        let directoryURL = try #require(historyStore.directoryURL)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let badURL = directoryURL.appendingPathComponent("codex.json")
        try? Data("{not valid json".utf8).write(to: badURL)
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = settings
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        defer { store._cancelPlanUtilizationHistoryLoadForTesting() }

        gate.open()
        await store._waitForPlanUtilizationHistoryLoadForTesting()

        // Best-effort empty: no panic, no providers populated, loaded flag set.
        #expect(store.planUtilizationHistory.isEmpty)
        #expect(store.planUtilizationHistoryLoaded == true)
    }

    @MainActor
    @Test
    func `multi-provider multi-account ownership preserved after load`() async {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-multi-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        let codexSession = planSeries(
            name: .session,
            windowMinutes: 300,
            entries: [planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 31)])
        let claudeWeekly = planSeries(
            name: .weekly,
            windowMinutes: 10080,
            entries: [planEntry(at: Date(timeIntervalSince1970: 1_700_000_001), usedPercent: 65)])
        let accountKey = "hashed-account-key"
        let buckets = PlanUtilizationHistoryBuckets(
            preferredAccountKey: accountKey,
            unscoped: [],
            accounts: [accountKey: [codexSession, claudeWeekly]])
        historyStore.save([.codex: buckets, .claude: buckets])
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = settings
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        defer { store._cancelPlanUtilizationHistoryLoadForTesting() }

        gate.open()
        await store._waitForPlanUtilizationHistoryLoadForTesting()

        #expect(store.planUtilizationHistory[.codex]?.accounts[accountKey]?.count == 2)
        #expect(store.planUtilizationHistory[.claude]?.accounts[accountKey]?.count == 2)
        #expect(store.planUtilizationHistory[.codex]?.preferredAccountKey == accountKey)
    }

    @MainActor
    @Test
    func `record waits for disk load then merges and persists history`() async {
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-record-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        let oldCapture = Date(timeIntervalSince1970: 1_700_000_000)
        let newCapture = oldCapture.addingTimeInterval(3700)
        historyStore.save([.claude: PlanUtilizationHistoryBuckets(
            preferredAccountKey: nil,
            unscoped: [planSeries(
                name: .session,
                windowMinutes: 300,
                entries: [planEntry(at: oldCapture, usedPercent: 20)])],
            accounts: [:])])
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 42,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: newCapture,
            identity: nil)

        var recordStarted = false
        var recordCompleted = false
        let recordTask = Task { @MainActor in
            recordStarted = true
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: snapshot,
                now: newCapture)
            recordCompleted = true
        }
        for _ in 0..<1000 where !recordStarted {
            await Task.yield()
        }
        #expect(recordStarted)
        #expect(!recordCompleted)
        #expect(store.planUtilizationHistory.isEmpty)

        gate.open()
        await store._waitForPlanUtilizationHistoryLoadForTesting()
        await recordTask.value

        let inMemory = findSeries(
            store.planUtilizationHistory[.claude]?.unscoped ?? [],
            name: .session,
            windowMinutes: 300)
        var persisted: PlanUtilizationSeriesHistory?
        for _ in 0..<100 {
            persisted = findSeries(
                historyStore.load()[.claude]?.unscoped ?? [],
                name: .session,
                windowMinutes: 300)
            if persisted == inMemory { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(inMemory?.entries.map(\.capturedAt) == [oldCapture, newCapture])
        #expect(inMemory?.entries.map(\.usedPercent) == [20, 42])
        #expect(persisted == inMemory)
    }

    @MainActor
    @Test
    func `init work is independent of history size`() throws {
        // With a closed load gate, UsageStore.init must return even when the
        // persisted history would dominate startup time at production scale.
        // The closed gate decouples the assertion from wall-clock variance;
        // we verify the init returned before the load completed, not the
        // decode duration itself.
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-perf-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        // Write a multi-megabyte synthetic payload so a real load would block.
        let directoryURL = try #require(historyStore.directoryURL)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let bigURL = directoryURL.appendingPathComponent("codex.json")
        let payload = Self.makeSyntheticHistoryPayload(entriesPerProvider: 50000)
        try? payload.write(to: bigURL)
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = settings

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        defer { store._cancelPlanUtilizationHistoryLoadForTesting() }

        // Init returned without waiting on the disk load.
        #expect(store.planUtilizationHistoryLoaded == false)
        #expect(gate.isOpen == false)
    }

    @MainActor
    @Test
    func `cancel before load wait is registered still drains the task`() async throws {
        // Cancel immediately after init, intentionally without yielding. The
        // cancellation state must remain visible when the load task later
        // reaches `wait()`; otherwise the wakeup can be lost and the task leaks.
        let suiteName = "UsageStorePlanUtilizationAsyncLoad-cancel-\(UUID().uuidString)"
        let gate = PlanUtilizationHistoryLoadGate()
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suiteName, reset: true)
        let settings = Self.makeSettings(suiteName: suiteName)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = settings
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)

        let loadTask = try #require(store.planUtilizationHistoryLoadTask)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        await loadTask.value

        #expect(gate.isCancelled == true)
        #expect(store.planUtilizationHistoryLoaded == true)
        #expect(store.planUtilizationHistory.isEmpty)
        gate.open()
        #expect(gate.isOpen == false)
    }

    // MARK: - Helpers

    @MainActor
    private static func makeSettings(suiteName: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults.standard
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeSyntheticHistoryPayload(entriesPerProvider: Int) -> Data {
        // A non-decodable but valid JSON shape keeps the test independent of
        // the schema version while still forcing the JSON decoder to do real
        // work when the load runs.
        var entries: [String] = []
        entries.reserveCapacity(entriesPerProvider)
        for index in 0..<entriesPerProvider {
            entries.append("{\"i\":\(index),\"p\":0.5,\"r\":\"2026-01-01T00:00:00Z\"}")
        }
        let body = "{\"v\":1,\"u\":[\(entries.joined(separator: ","))],\"a\":{}}"
        return Data(body.utf8)
    }
}
