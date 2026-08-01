import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct UsageStoreCodexLocalProjectUsageRequestTests {
    @Test
    func `identical refresh triggers coalesce`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        settings.costUsageHistoryDays = 30
        let store = self.makeStore(settings: settings, probe: probe)

        store.scheduleCodexLocalProjectUsageRefreshIfNeeded(force: true)
        #expect(await probe.waitUntilStarted(count: 1))
        let activeRequest = store.activeCodexLocalProjectUsageRequestKey
        let activeGeneration = store.codexLocalProjectUsageRequestGeneration
        #expect(activeRequest != nil)
        #expect(store.pendingCodexLocalProjectUsageRequestKey == nil)

        store.scheduleCodexLocalProjectUsageRefreshIfNeeded(force: true)
        #expect(store.activeCodexLocalProjectUsageRequestKey == activeRequest)
        #expect(store.pendingCodexLocalProjectUsageRequestKey == nil)
        #expect(store.codexLocalProjectUsageRequestGeneration == activeGeneration)
        let calls = await probe.recordedCalls()
        #expect(calls.count == 1)

        await probe.releaseNext()
        await probe.cleanup()
    }

    @Test
    func `changed requests retain only the latest follow-up`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        settings.costUsageHistoryDays = 30
        let store = self.makeStore(settings: settings, probe: probe)

        store.scheduleCodexLocalProjectUsageRefreshIfNeeded()
        #expect(await probe.waitUntilStarted(count: 1))
        let activeRequest = store.activeCodexLocalProjectUsageRequestKey

        settings.costUsageHistoryDays = 180
        store.scheduleCodexLocalProjectUsageRefreshIfNeeded()
        #expect(store.activeCodexLocalProjectUsageRequestKey == activeRequest)
        #expect(store.pendingCodexLocalProjectUsageRequestKey?.contains("historyDays=180") == true)

        settings.costUsageHistoryDays = 365
        store.scheduleCodexLocalProjectUsageRefreshIfNeeded()
        #expect(store.pendingCodexLocalProjectUsageRequestKey?.contains("historyDays=365") == true)

        #expect(await probe.waitUntilStarted(count: 2))
        let calls = await probe.recordedCalls()
        #expect(calls.count == 2)
        #expect(store.activeCodexLocalProjectUsageRequestKey?.contains("historyDays=365") == true)
        #expect(store.pendingCodexLocalProjectUsageRequestKey == nil)

        await probe.releaseNext()
        await probe.cleanup()
    }

    @Test
    func `forced rebuild routes through the scheduler`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        let store = self.makeStore(settings: settings, probe: probe)

        store.scheduleCodexLocalProjectUsageRefreshIfNeeded()
        #expect(await probe.waitUntilStarted(count: 1))
        store.lastCodexLocalProjectUsageFetchAt = Date()
        store.lastCodexLocalProjectUsageFetchScope = "stale-scope"
        store.lastCodexLocalProjectUsageFailureAt = Date()
        store.codexLocalProjectUsageBackoffUntil = Date().addingTimeInterval(60)
        store.codexLocalProjectUsageFailureCount = 3

        store.rebuildCodexLocalProjectUsageIndex()
        #expect(store.pendingForcedCodexLocalProjectUsageRefresh)
        #expect(store.pendingCodexLocalProjectUsageRequestKey == store.activeCodexLocalProjectUsageRequestKey)
        #expect(store.lastCodexLocalProjectUsageFetchAt == nil)
        #expect(store.lastCodexLocalProjectUsageFetchScope == nil)
        #expect(store.lastCodexLocalProjectUsageFailureAt == nil)
        #expect(store.codexLocalProjectUsageBackoffUntil == nil)
        #expect(store.codexLocalProjectUsageFailureCount == 0)

        #expect(await probe.waitUntilStarted(count: 2))
        let calls = await probe.recordedCalls()
        #expect(calls.map(\.force) == [false, true])
        #expect(store.activeForcedCodexLocalProjectUsageRefresh)
        #expect(store.pendingCodexLocalProjectUsageRequestKey == nil)

        await probe.releaseNext()
        await probe.cleanup()
    }

    @Test
    func `enabling privacy clears raw projection before scheduling protected refresh`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        let store = self.makeStore(settings: settings, probe: probe)
        store.scheduleCodexLocalProjectUsageRefreshIfNeeded()
        #expect(await probe.waitUntilStarted(count: 1))
        let rawGeneration = store.codexLocalProjectUsageRequestGeneration
        let snapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            historyDays: 30,
            scopeSignature: "stable-scope",
            rootsFingerprint: [:],
            indexedFileCount: 1,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            daily: [])
        store.codexLocalProjectUsageSnapshot = snapshot
        store.codexLocalProjectUsageError = "raw projection error"
        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(phase: .scanningLogs)
        store.codexLocalProjectUsageRefreshInFlight = true
        store.lastCodexLocalProjectUsageFetchAt = Date()
        store.lastCodexLocalProjectUsageFetchScope = "raw-scope"
        store.lastCodexLocalProjectUsageFailureAt = Date()
        store.codexLocalProjectUsageBackoffUntil = Date().addingTimeInterval(60)
        store.codexLocalProjectUsageFailureCount = 2

        let previousHidePersonalInfo = settings.hidePersonalInfo
        settings.hidePersonalInfo = true
        store.refreshCodexLocalProjectUsageProjectionIfNeeded(
            previousHidePersonalInfo: previousHidePersonalInfo)

        #expect(store.codexLocalProjectUsageSnapshot == nil)
        #expect(store.codexLocalProjectUsageError == nil)
        #expect(store.codexLocalProjectUsageProgress == nil)
        #expect(!store.codexLocalProjectUsageRefreshInFlight)
        #expect(store.codexLocalProjectUsageLoadState == .idle)
        #expect(store.lastCodexLocalProjectUsageFetchAt == nil)
        #expect(store.lastCodexLocalProjectUsageFetchScope == nil)
        #expect(store.lastCodexLocalProjectUsageFailureAt == nil)
        #expect(store.codexLocalProjectUsageBackoffUntil == nil)
        #expect(store.codexLocalProjectUsageFailureCount == 0)
        #expect(store.pendingCodexLocalProjectUsageRequestKey?.contains("hidePersonalInfo=true") == true)
        #expect(store.codexLocalProjectUsageRequestGeneration > rawGeneration)

        #expect(await probe.waitUntilStarted(count: 2))
        let calls = await probe.recordedCalls()
        #expect(calls.map(\.force) == [false, false])
        #expect(calls[1].generation > calls[0].generation)
        #expect(store.activeCodexLocalProjectUsageRequestKey?.contains("hidePersonalInfo=true") == true)

        await probe.releaseNext()
        await probe.cleanup()
    }

    @Test
    func `disabling privacy retains protected projection while scheduling normal refresh`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        settings.hidePersonalInfo = true
        let store = self.makeStore(settings: settings, probe: probe)
        let protectedSnapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            historyDays: 30,
            scopeSignature: "protected-scope",
            rootsFingerprint: [:],
            indexedFileCount: 1,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            daily: [])
        store.codexLocalProjectUsageSnapshot = protectedSnapshot

        settings.hidePersonalInfo = false
        store.refreshCodexLocalProjectUsageProjectionIfNeeded(previousHidePersonalInfo: true)

        #expect(store.codexLocalProjectUsageSnapshot == protectedSnapshot)
        #expect(store.activeCodexLocalProjectUsageRequestKey?.contains("hidePersonalInfo=false") == true)

        #expect(await probe.waitUntilStarted(count: 1))
        let calls = await probe.recordedCalls()
        #expect(calls.map(\.force) == [false])

        await probe.releaseNext()
        await probe.cleanup()
    }

    @Test
    func `display preferences only update projections without scheduling a request`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        let store = self.makeStore(settings: settings, probe: probe)
        let snapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            historyDays: 30,
            scopeSignature: "stable-scope",
            rootsFingerprint: [:],
            indexedFileCount: 1,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            daily: [])
        store.codexLocalProjectUsageSnapshot = snapshot
        let requestGeneration = store.codexLocalProjectUsageRequestGeneration

        settings.codexLocalProjectUsageShowsEstimatedCost = false
        settings.codexLocalProjectUsageIncludesCachedInput = false
        store.refreshCodexLocalProjectUsageAvailabilityIfNeeded(previousEnabled: true)
        store.refreshCodexLocalProjectUsageProjectionIfNeeded(
            previousHidePersonalInfo: settings.hidePersonalInfo)
        await Task.yield()

        #expect(!store.codexLocalProjectUsageProjection.showsEstimatedCost)
        #expect(!store.codexLocalProjectUsageProjection.includesCachedInput)
        #expect(store.codexLocalProjectUsageRequestGeneration == requestGeneration)
        #expect(store.codexLocalProjectUsageSnapshot == snapshot)
        let calls = await probe.recordedCalls()
        #expect(calls.isEmpty)
        await probe.cleanup()
    }

    @Test
    func `availability preference routes enablement through the scheduler`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        let store = self.makeStore(settings: settings, probe: probe)
        let initialBackgroundRevision = settings.backgroundWorkSettingsRevision

        settings.codexLocalProjectUsageEnabled = false
        #expect(settings.backgroundWorkSettingsRevision == initialBackgroundRevision + 1)
        store.refreshCodexLocalProjectUsageAvailabilityIfNeeded(previousEnabled: true)
        let disabledCalls = await probe.recordedCalls()
        #expect(disabledCalls.isEmpty)
        #expect(store.codexLocalProjectUsageRefreshTask == nil)

        settings.codexLocalProjectUsageEnabled = true
        #expect(settings.backgroundWorkSettingsRevision == initialBackgroundRevision + 2)
        store.refreshCodexLocalProjectUsageAvailabilityIfNeeded(previousEnabled: false)
        #expect(await probe.waitUntilStarted(count: 1))
        let enabledCalls = await probe.recordedCalls()
        #expect(enabledCalls.map(\.force) == [false])

        await probe.releaseNext()
        await probe.cleanup()
    }

    @Test
    func `disabling cancels and resets refresh scheduling`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        let store = self.makeStore(settings: settings, probe: probe)

        store.scheduleCodexLocalProjectUsageRefreshIfNeeded(force: true)
        #expect(await probe.waitUntilStarted(count: 1))
        store.codexLocalProjectUsageError = "stale error"
        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(phase: .scanningLogs)
        store.codexLocalProjectUsageRefreshInFlight = true
        store.lastCodexLocalProjectUsageFetchAt = Date()
        store.lastCodexLocalProjectUsageFetchScope = "stale-scope"
        store.lastCodexLocalProjectUsageFailureAt = Date()
        store.codexLocalProjectUsageBackoffUntil = Date().addingTimeInterval(60)
        store.codexLocalProjectUsageFailureCount = 2

        settings.codexLocalProjectUsageEnabled = false
        store.scheduleCodexLocalProjectUsageRefreshIfNeeded()
        #expect(await probe.waitUntilCancelled(count: 1))
        #expect(store.codexLocalProjectUsageRefreshTask == nil)
        #expect(!store.codexLocalProjectUsageRefreshInFlight)
        #expect(store.codexLocalProjectUsageError == nil)
        #expect(store.codexLocalProjectUsageProgress == nil)
        #expect(store.lastCodexLocalProjectUsageFetchAt == nil)
        #expect(store.lastCodexLocalProjectUsageFetchScope == nil)
        #expect(store.lastCodexLocalProjectUsageFailureAt == nil)
        #expect(store.codexLocalProjectUsageBackoffUntil == nil)
        #expect(store.codexLocalProjectUsageFailureCount == 0)
        #expect(!store.activeForcedCodexLocalProjectUsageRefresh)
        #expect(!store.pendingForcedCodexLocalProjectUsageRefresh)
        #expect(store.activeCodexLocalProjectUsageRequestKey == nil)
        #expect(store.pendingCodexLocalProjectUsageRequestKey == nil)
        #expect(store.activeCodexLocalProjectUsageRequestGeneration == nil)
        #expect(store.codexLocalProjectUsageLoadState == .idle)
        await probe.cleanup()
    }

    @Test
    func `scheduled refresh does not retain its store`() async {
        let probe = CodexLocalProjectUsageRefreshExecutorProbe()
        let settings = self.makeCodexOnlySettings()
        var store: UsageStore? = self.makeStore(settings: settings, probe: probe)
        weak let weakStore = store

        store?.scheduleCodexLocalProjectUsageRefreshIfNeeded(force: true)
        #expect(await probe.waitUntilStarted(count: 1))

        store = nil

        #expect(weakStore == nil)
        #expect(await probe.waitUntilCancelled(count: 1))
        await probe.cleanup()
    }

    private func makeStore(
        settings: SettingsStore,
        probe: CodexLocalProjectUsageRefreshExecutorProbe) -> UsageStore
    {
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_codexLocalProjectUsageRefreshExecutor = { force, generation in
            await probe.run(force: force, generation: generation)
        }
        return store
    }

    private func makeCodexOnlySettings() -> SettingsStore {
        let suite = "UsageStoreCodexLocalProjectUsageRequestTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        return settings
    }
}

private actor CodexLocalProjectUsageRefreshExecutorProbe {
    struct Call: Sendable {
        let force: Bool
        let generation: UInt64
    }

    private struct Waiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var calls: [Call] = []
    private var blockedCalls: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelledCallIDs: Set<UUID> = []
    private var startWaiters: [Waiter] = []
    private var cancellationWaiters: [Waiter] = []

    func run(force: Bool, generation: UInt64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.calls.append(Call(force: force, generation: generation))
                if Task.isCancelled {
                    self.recordCancellation(id: id)
                    continuation.resume()
                } else {
                    self.blockedCalls.append((id: id, continuation: continuation))
                }
                self.resumeSatisfiedStartWaiters()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitUntilStarted(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        guard self.calls.count < count else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return
                }
                await self?.timeoutStartWaiter(id: id)
            }
            self.startWaiters.append(Waiter(
                id: id,
                count: count,
                continuation: continuation,
                timeoutTask: timeoutTask))
        }
    }

    func waitUntilCancelled(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        guard self.cancelledCallIDs.count < count else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return
                }
                await self?.timeoutCancellationWaiter(id: id)
            }
            self.cancellationWaiters.append(Waiter(
                id: id,
                count: count,
                continuation: continuation,
                timeoutTask: timeoutTask))
        }
    }

    func releaseNext() {
        guard !self.blockedCalls.isEmpty else { return }
        self.blockedCalls.removeFirst().continuation.resume()
    }

    func recordedCalls() -> [Call] {
        self.calls
    }

    func cleanup() {
        let blockedCalls = self.blockedCalls
        self.blockedCalls.removeAll()
        for blockedCall in blockedCalls {
            blockedCall.continuation.resume()
        }
        self.resumeAndRemoveAllWaiters(&self.startWaiters)
        self.resumeAndRemoveAllWaiters(&self.cancellationWaiters)
    }

    private func cancel(id: UUID) {
        self.recordCancellation(id: id)
        guard let index = self.blockedCalls.firstIndex(where: { $0.id == id }) else { return }
        self.blockedCalls.remove(at: index).continuation.resume()
    }

    private func recordCancellation(id: UUID) {
        guard self.cancelledCallIDs.insert(id).inserted else { return }
        var remaining: [Waiter] = []
        for waiter in self.cancellationWaiters {
            if self.cancelledCallIDs.count >= waiter.count {
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(returning: true)
            } else {
                remaining.append(waiter)
            }
        }
        self.cancellationWaiters = remaining
    }

    private func resumeSatisfiedStartWaiters() {
        var remaining: [Waiter] = []
        for waiter in self.startWaiters {
            if self.calls.count >= waiter.count {
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(returning: true)
            } else {
                remaining.append(waiter)
            }
        }
        self.startWaiters = remaining
    }

    private func timeoutStartWaiter(id: UUID) {
        guard let index = self.startWaiters.firstIndex(where: { $0.id == id }) else { return }
        self.startWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func timeoutCancellationWaiter(id: UUID) {
        guard let index = self.cancellationWaiters.firstIndex(where: { $0.id == id }) else { return }
        self.cancellationWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func resumeAndRemoveAllWaiters(_ waiters: inout [Waiter]) {
        let outstandingWaiters = waiters
        waiters.removeAll()
        for waiter in outstandingWaiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: false)
        }
    }
}
