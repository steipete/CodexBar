import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor CLIProxyAPIUsageCollectionRecorder {
    private(set) var callCount = 0

    func collect() -> CLIProxyAPIUsageCollectionResult {
        self.callCount += 1
        return .collected(1)
    }
}

private actor CLIProxyAPIUsageCollectorCancellationRecorder {
    private(set) var wasCancelled = false

    func recordCancellation() {
        self.wasCancelled = true
    }
}

private final class CLIProxyAPICleanupRetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    func attempt() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.attempts += 1
        return self.attempts >= 2
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.attempts
    }
}

@MainActor
struct CLIProxyAPIUsageStoreTests {
    @Test
    func `cost tracking opt out prevents telemetry collection`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = false
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let recorder = CLIProxyAPIUsageCollectionRecorder()

        let disabledResult = await store.collectCLIProxyAPIUsageNow {
            await recorder.collect()
        }

        #expect(disabledResult == .disabled)
        #expect(await recorder.callCount == 0)

        settings.costUsageEnabled = true
        let enabledResult = await store.collectCLIProxyAPIUsageNow {
            await recorder.collect()
        }

        #expect(enabledResult == .collected(1))
        #expect(await recorder.callCount == 1)
    }

    @Test
    func `removing the integration cancels and clears the active telemetry task`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let recorder = CLIProxyAPIUsageCollectorCancellationRecorder()
        let collectorFinished = LockIsolated(false)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            await recorder.recordCancellation()
            let drainDelay = Task.detached {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await drainDelay.value
            collectorFinished.setValue(true)
        }
        store.cliProxyAPIUsageCollectorTask = task
        var collectorFinishedBeforePurge = false
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .claude)
        let codexPublicationRevision = store.tokenSnapshotPublicationRevision(for: .codex)
        let claudePublicationRevision = store.tokenSnapshotPublicationRevision(for: .claude)
        let claudePublicationGuard = store.tokenRefreshPublicationGuard(for: .claude)
        let claudeScopeSignature = store.tokenSnapshotScopeSignature(for: .claude)

        let removed = await store.removeCLIProxyAPIConfiguration {
            collectorFinishedBeforePurge = collectorFinished.value
            return .removed
        }
        await task.value

        #expect(removed == .removed)
        #expect(collectorFinishedBeforePurge)
        #expect(store.cliProxyAPIUsageCollectorTask == nil)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == codexPublicationRevision + 1)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .claude) == claudePublicationRevision + 1)
        #expect(!store.tokenRefreshPublicationIsCurrent(
            provider: .claude,
            publicationGuard: claudePublicationGuard,
            historyDays: settings.costUsageHistoryDays,
            costScopeSignature: claudeScopeSignature))
        #expect(await recorder.wasCancelled)
    }

    @Test
    func `removing the integration preserves telemetry when configuration removal fails`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        let removed = await store.removeCLIProxyAPIConfiguration {
            .configurationRemovalFailed
        }

        #expect(removed == .configurationRemovalFailed)
        #expect(store.tokenSnapshot(for: .codex) != nil)
    }

    @Test
    func `removing the integration reports telemetry cleanup failure after configuration removal`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        var scheduledCleanupRetry = false

        let removed = await store.removeCLIProxyAPIConfiguration(
            remove: { .telemetryCleanupFailed },
            scheduleCleanupRetry: { scheduledCleanupRetry = true })

        #expect(removed == .telemetryCleanupFailed)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(scheduledCleanupRetry)
    }

    @Test
    func `telemetry cleanup maintenance retries until transaction recovery succeeds`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let recorder = CLIProxyAPICleanupRetryRecorder()

        let task = store.startCLIProxyAPICleanupRetry(retryInterval: .milliseconds(1)) {
            recorder.attempt()
        }
        await task.value

        #expect(recorder.count == 2)
    }

    @Test
    func `reconnecting invalidates and force refreshes both proxy affected token snapshots`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .claude)
        let codexPublicationRevision = store.tokenSnapshotPublicationRevision(for: .codex)
        let claudePublicationRevision = store.tokenSnapshotPublicationRevision(for: .claude)
        var refreshes: [(UsageProvider, Bool)] = []

        await store.refreshCLIProxyAPICostAttribution { provider, force in
            refreshes.append((provider, force))
        }

        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == codexPublicationRevision + 1)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .claude) == claudePublicationRevision + 1)
        #expect(refreshes.map(\.0) == [.claude, .codex])
        #expect(refreshes.map(\.1) == [true, true])
    }

    @Test
    func `initial missing configuration preserves hydrated proxy snapshots`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let snapshot = Self.tokenSnapshot()
        store.publishTokenSnapshot(snapshot, for: .codex)
        store.publishTokenSnapshot(snapshot, for: .claude)
        let codexPublicationRevision = store.tokenSnapshotPublicationRevision(for: .codex)
        let claudePublicationRevision = store.tokenSnapshotPublicationRevision(for: .claude)

        let collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .notConfigured,
            collectorState: CLIProxyAPIUsageCollectorState(),
            isExplicitlyDisconnected: { false })

        #expect(collectorState.configurationAvailability == .unavailable)
        #expect(store.tokenSnapshot(for: .codex) == snapshot)
        #expect(store.tokenSnapshot(for: .claude) == snapshot)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == codexPublicationRevision)
        #expect(store.tokenSnapshotPublicationRevision(for: .claude) == claudePublicationRevision)
    }

    @Test
    func `background disconnect invalidates once and remote reconnect refreshes snapshots`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .claude)
        let codexPublicationRevision = store.tokenSnapshotPublicationRevision(for: .codex)
        let claudePublicationRevision = store.tokenSnapshotPublicationRevision(for: .claude)
        let dashboardRevision = store.spendDashboardCodexCostCatchUpRevision
        let dashboardConfiguration = SpendDashboardSource.configuration(settings: settings, store: store)

        var collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .notConfigured,
            collectorState: CLIProxyAPIUsageCollectorState(configurationAvailability: .available),
            isExplicitlyDisconnected: { false })

        #expect(collectorState.configurationAvailability == .unavailable)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == codexPublicationRevision + 1)
        #expect(store.tokenSnapshotPublicationRevision(for: .claude) == claudePublicationRevision + 1)
        #expect(store.spendDashboardCodexCostCatchUpRevision == dashboardRevision + 1)
        #expect(
            SpendDashboardSource.configuration(settings: settings, store: store).sourceRevisions !=
                dashboardConfiguration.sourceRevisions)

        collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .notConfigured,
            collectorState: collectorState,
            isExplicitlyDisconnected: { false })

        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == codexPublicationRevision + 1)
        #expect(store.tokenSnapshotPublicationRevision(for: .claude) == claudePublicationRevision + 1)
        #expect(store.spendDashboardCodexCostCatchUpRevision == dashboardRevision + 1)

        var refreshes: [(UsageProvider, Bool)] = []
        collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .failed("temporary failure"),
            collectorState: collectorState,
            isExplicitlyDisconnected: { false })
        #expect(collectorState.configurationAvailability == .unavailable)
        collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .collected(0),
            collectorState: collectorState,
            isExplicitlyDisconnected: { false },
            refresh: { provider, force in
                refreshes.append((provider, force))
            })
        #expect(collectorState.configurationAvailability == .available)
        #expect(refreshes.map(\.0) == [.claude, .codex])
        #expect(refreshes.map(\.1) == [true, true])
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .notConfigured,
            collectorState: collectorState,
            isExplicitlyDisconnected: { false })

        #expect(collectorState.configurationAvailability == .unavailable)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == codexPublicationRevision + 4)
    }

    @Test
    func `configuration generation detects a reconnect missed between polls`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let snapshot = Self.tokenSnapshot()
        store.publishTokenSnapshot(snapshot, for: .codex)
        store.publishTokenSnapshot(snapshot, for: .claude)
        var refreshes: [(UsageProvider, Bool)] = []

        let collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .collected(0),
            collectorState: CLIProxyAPIUsageCollectorState(
                configurationAvailability: .available,
                configurationGeneration: "before-removal"),
            isExplicitlyDisconnected: { false },
            configurationGeneration: { "after-reconnect" },
            refresh: { provider, force in
                refreshes.append((provider, force))
            })

        #expect(collectorState.configurationAvailability == .available)
        #expect(collectorState.configurationGeneration == "after-reconnect")
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(refreshes.map(\.0) == [.claude, .codex])
        #expect(refreshes.map(\.1) == [true, true])
    }

    @Test
    func `failed generation transition stays pending until collection succeeds`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        var refreshes: [(UsageProvider, Bool)] = []

        var collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .failed("replacement unavailable"),
            collectorState: CLIProxyAPIUsageCollectorState(
                configurationAvailability: .available,
                configurationGeneration: "old-generation"),
            configurationGeneration: { "new-generation" })

        #expect(collectorState.configurationAvailability == .unavailable)
        #expect(collectorState.configurationGeneration == "new-generation")

        collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .collected(0),
            collectorState: collectorState,
            configurationGeneration: { "new-generation" },
            refresh: { provider, force in
                refreshes.append((provider, force))
            })

        #expect(collectorState.configurationAvailability == .available)
        #expect(refreshes.map(\.0) == [.claude, .codex])
        #expect(refreshes.map(\.1) == [true, true])
    }

    @Test
    func `first collection detects a generation change after startup hydration`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let snapshot = Self.tokenSnapshot()
        store.publishTokenSnapshot(snapshot, for: .codex)
        store.publishTokenSnapshot(snapshot, for: .claude)
        var refreshes: [(UsageProvider, Bool)] = []

        let collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .collected(0),
            collectorState: CLIProxyAPIUsageCollectorState(
                configurationGeneration: "hydrated-generation"),
            configurationGeneration: { "replacement-generation" },
            refresh: { provider, force in
                refreshes.append((provider, force))
            })

        #expect(collectorState.configurationAvailability == .available)
        #expect(collectorState.configurationGeneration == "replacement-generation")
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(refreshes.map(\.0) == [.claude, .codex])
        #expect(refreshes.map(\.1) == [true, true])
    }

    @Test
    func `first failed collection invalidates stale snapshots after configuration changes`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let snapshot = Self.tokenSnapshot()
        store.publishTokenSnapshot(snapshot, for: .codex)
        store.publishTokenSnapshot(snapshot, for: .claude)

        var collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .failed("replacement endpoint unavailable"),
            collectorState: CLIProxyAPIUsageCollectorState(
                configurationGeneration: "before-replacement"),
            configurationGeneration: { "after-replacement" })

        #expect(collectorState.configurationAvailability == .unavailable)
        #expect(collectorState.configurationGeneration == "after-replacement")
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshot(for: .claude) == nil)

        store.publishTokenSnapshot(snapshot, for: .codex)
        collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .failed("still unavailable"),
            collectorState: collectorState,
            configurationGeneration: { "after-replacement" })

        #expect(store.tokenSnapshot(for: .codex) == snapshot)
    }

    @Test
    func `clearing cost cache drains the active proxy collector before deletion`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let collectorFinished = LockIsolated(false)
        let deletionStartedAfterDrain = LockIsolated(false)
        store.cliProxyAPIUsageCollectorTask = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            let drainDelay = Task.detached {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await drainDelay.value
            collectorFinished.setValue(true)
        }

        let error = await store.clearCostUsageCache(clearDirectories: {
            deletionStartedAfterDrain.setValue(collectorFinished.value)
            return (cleared: 0, errorMessage: nil)
        })
        store.stopCLIProxyAPIUsageCollector()

        #expect(error == nil)
        #expect(deletionStartedAfterDrain.value)
    }

    @Test
    func `clearing cost cache cancels and drains token scans before deletion`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let refreshStarted = LockIsolated(false)
        let refreshFinished = LockIsolated(false)
        let deletionStartedAfterDrain = LockIsolated(false)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        let publicationRevision = store.tokenSnapshotPublicationRevision(for: .codex)
        store._test_tokenUsageRefreshOverride = { _, _ in
            refreshStarted.setValue(true)
            while !Task.isCancelled {
                await Task.yield()
            }
            refreshFinished.setValue(true)
        }
        defer { store._test_tokenUsageRefreshOverride = nil }
        let refreshTask = Task {
            await store.refreshTokenUsageNow(for: .codex, force: true)
        }
        while !refreshStarted.value {
            await Task.yield()
        }

        let error = await store.clearCostUsageCache(clearDirectories: {
            deletionStartedAfterDrain.setValue(refreshFinished.value)
            return (cleared: 0, errorMessage: nil)
        })
        await refreshTask.value

        #expect(error == nil)
        #expect(deletionStartedAfterDrain.value)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshotPublicationRevision(for: .codex) == publicationRevision + 1)
        #expect(store.tokenRefreshInFlight.isEmpty)
        #expect(store.tokenRefreshSequenceTask == nil)
    }

    @Test
    func `clearing cost cache uses the shared locked deletion path`() async throws {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-store-\(UUID().uuidString)", isDirectory: true)
        let fileManager = CLIProxyAPITestFileManager(root: root)
        let cacheDirectory = CostUsageCacheLocations.directories(fileManager: fileManager)[0]
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let usageFile = cacheDirectory.appendingPathComponent("usage.json")
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let error = await store.clearCostUsageCache(fileManager: fileManager)

        #expect(error == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
    }

    @Test
    func `partial cost cache clear invalidates in memory snapshots`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)

        let error = await store.clearCostUsageCache(clearDirectories: {
            (cleared: 1, errorMessage: "Could not remove every cache directory")
        })

        #expect(error != nil)
        #expect(store.tokenSnapshot(for: .codex) == nil)
    }

    private static func tokenSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.01,
            last30DaysTokens: 10,
            last30DaysCostUSD: 0.01,
            currencyCode: "USD",
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_784_203_200))
    }
}

private final class CLIProxyAPITestFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in _: FileManager.SearchPathDomainMask) -> [URL]
    {
        switch directory {
        case .cachesDirectory:
            [self.root.appendingPathComponent("Caches", isDirectory: true)]
        case .applicationSupportDirectory:
            [self.root.appendingPathComponent("Application Support", isDirectory: true)]
        default:
            super.urls(for: directory, in: .userDomainMask)
        }
    }
}
