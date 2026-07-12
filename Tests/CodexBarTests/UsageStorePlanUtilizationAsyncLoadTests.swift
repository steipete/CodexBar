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
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let badURL = directoryURL.appendingPathComponent("codex.json")
        try Data("{not valid json".utf8).write(to: badURL)
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

        for _ in 0..<1000 where gate.pendingWaiterCount == 0 {
            await Task.yield()
        }
        #expect(gate.pendingWaiterCount == 1)

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
        await store._waitForPlanUtilizationHistoryPersistenceForTesting()

        let inMemory = findSeries(
            store.planUtilizationHistory[.claude]?.unscoped ?? [],
            name: .session,
            windowMinutes: 300)
        let persisted = findSeries(
            historyStore.load()[.claude]?.unscoped ?? [],
            name: .session,
            windowMinutes: 300)
        #expect(inMemory?.entries.map(\.capturedAt) == [oldCapture, newCapture])
        #expect(inMemory?.entries.map(\.usedPercent) == [20, 42])
        #expect(persisted == inMemory)
    }

    @MainActor
    @Test
    func `cancel during load drains the exact gate waiter`() async {
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

        for _ in 0..<1000 where gate.pendingWaiterCount == 0 {
            await Task.yield()
        }
        #expect(gate.pendingWaiterCount == 1)

        store._cancelPlanUtilizationHistoryLoadForTesting()
        await store._waitForPlanUtilizationHistoryLoadForTesting()

        #expect(gate.pendingWaiterCount == 0)
        #expect(!gate.isOpen)
        #expect(store.planUtilizationHistory.isEmpty)
        #expect(store.planUtilizationHistoryRevision == 0)
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
}
