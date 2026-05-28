import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor TokenRefreshGate {
    private var didStart = false
    private var didFinish = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls: [(provider: UsageProvider, force: Bool)] = []

    func start(provider: UsageProvider, force: Bool) {
        self.didStart = true
        self.calls.append((provider, force))
        let waiters = self.startWaiters
        self.startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForStart() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if self.released { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func finish() {
        self.didFinish = true
    }

    func hasFinished() -> Bool {
        self.didFinish
    }
}

private actor CompletionFlag {
    private var completed = false

    func markCompleted() {
        self.completed = true
    }

    func isCompleted() -> Bool {
        self.completed
    }
}

private actor TokenRefreshRecorder {
    private(set) var calls: [(provider: UsageProvider, force: Bool)] = []

    func record(provider: UsageProvider, force: Bool) {
        self.calls.append((provider, force))
    }

    func waitUntilCalls(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let start = ContinuousClock.now
        while self.calls.count < count {
            if start.duration(to: .now) >= timeout { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private actor ProviderRefreshRecorder {
    private(set) var calls: [UsageProvider] = []

    func record(provider: UsageProvider) {
        self.calls.append(provider)
    }
}

@MainActor
@Suite(.serialized)
struct UsageStoreManualTokenRefreshTests {
    @Test
    func `manual refresh waits for token-cost refresh before completing`() async {
        let store = Self.makeStore()
        let gate = TokenRefreshGate()
        let completion = CompletionFlag()
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await gate.start(provider: provider, force: force)
            await gate.waitForRelease()
            await gate.finish()
        }

        let task = Task { @MainActor in
            await store.refresh(forceTokenUsage: true)
            await completion.markCompleted()
        }

        await gate.waitForStart()
        #expect(await completion.isCompleted() == false)
        #expect(await gate.hasFinished() == false)

        await gate.release()
        await task.value

        #expect(await completion.isCompleted())
        #expect(await gate.hasFinished())
        #expect(await gate.calls.map(\.provider) == [.codex])
        #expect(await gate.calls.map(\.force) == [true])
    }

    @Test
    func `manual refresh drains scheduled token-cost refresh before forced pass`() async {
        let store = Self.makeStore()
        let scheduledGate = TokenRefreshGate()
        let forcedGate = TokenRefreshGate()
        let recorder = TokenRefreshRecorder()
        let completion = CompletionFlag()
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
            if force {
                await forcedGate.start(provider: provider, force: force)
                await forcedGate.waitForRelease()
                await forcedGate.finish()
            } else {
                await scheduledGate.start(provider: provider, force: force)
                await scheduledGate.waitForRelease()
                await scheduledGate.finish()
            }
        }

        await store.refresh(forceTokenUsage: false)
        await scheduledGate.waitForStart()

        let task = Task { @MainActor in
            await store.refresh(forceTokenUsage: true)
            await completion.markCompleted()
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await completion.isCompleted() == false)

        await scheduledGate.release()
        await forcedGate.waitForStart()
        #expect(await completion.isCompleted() == false)

        await forcedGate.release()
        await task.value

        #expect(await completion.isCompleted())
        #expect(await scheduledGate.hasFinished())
        #expect(await forcedGate.hasFinished())
        #expect(await recorder.calls.map(\.provider) == [.codex, .codex])
        #expect(await recorder.calls.map(\.force) == [false, true])
    }

    @Test
    func `regular refresh schedules token-cost refresh without waiting`() async {
        let store = Self.makeStore()
        let gate = TokenRefreshGate()
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await gate.start(provider: provider, force: force)
            await gate.waitForRelease()
            await gate.finish()
        }

        await store.refresh(forceTokenUsage: false)
        #expect(await gate.hasFinished() == false)

        await gate.release()
        try? await Task.sleep(for: .milliseconds(50))
        let calls = await gate.calls
        if !calls.isEmpty {
            #expect(calls.map(\.provider) == [.codex])
            #expect(calls.map(\.force) == [false])
            #expect(await gate.hasFinished())
        }
    }

    @Test
    func `menu interaction defers regular token-cost refresh until idle`() async {
        let store = Self.makeStore()
        let recorder = TokenRefreshRecorder()
        store.tokenCostInteractionResumeDelay = 0.01
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
        }

        store.beginInteractiveMenuTokenCostDeferral(reason: "test-menu-open")
        await store.refresh(forceTokenUsage: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.calls.isEmpty)

        store.endInteractiveMenuTokenCostDeferral(reason: "test-menu-close")
        #expect(await recorder.waitUntilCalls(count: 1))

        #expect(await recorder.calls.map(\.provider) == [.codex])
        #expect(await recorder.calls.map(\.force) == [false])
    }

    @Test
    func `menu interaction starts missing token-cost snapshot scan so skeleton can hydrate`() async {
        let store = Self.makeStore()
        let recorder = TokenRefreshRecorder()
        store.tokenCostInteractionResumeDelay = 0.01
        store._test_cachedTokenUsageLoadOverride = { _ in nil }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
        }

        store.beginInteractiveMenuTokenCostDeferral(reason: "test-menu-open")
        store.ensureTokenCostSnapshotScheduled(for: .codex, reason: "test-missing-chart")

        #expect(await recorder.waitUntilCalls(count: 1))
        #expect(await recorder.calls.map(\.provider) == [.codex])
        #expect(await recorder.calls.map(\.force) == [false])

        store.endInteractiveMenuTokenCostDeferral(reason: "test-menu-close")
        #expect(await recorder.calls.map(\.provider) == [.codex])
        #expect(await recorder.calls.map(\.force) == [false])
    }

    @Test
    func `menu interaction hydrates cached token-cost snapshot before revalidation`() async {
        let store = Self.makeStore()
        let recorder = TokenRefreshRecorder()
        store.tokenCostInteractionResumeDelay = 0.01
        store._test_cachedTokenUsageLoadOverride = { _ in Self.tokenSnapshot() }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
        }

        store.beginInteractiveMenuTokenCostDeferral(reason: "test-menu-open")
        store.ensureTokenCostSnapshotScheduled(for: .codex, reason: "test-cached-chart")

        #expect(await Self.waitUntil(timeout: .seconds(1)) {
            store.tokenSnapshot(for: .codex)?.sessionTokens == 150
        })
        #expect(await recorder.calls.isEmpty)

        store.endInteractiveMenuTokenCostDeferral(reason: "test-menu-close")
        #expect(await recorder.waitUntilCalls(count: 1))
        #expect(await recorder.calls.map(\.provider) == [.codex])
        #expect(await recorder.calls.map(\.force) == [false])
    }

    @Test
    func `menu interaction defers stale token-cost refresh when cached data exists`() async {
        let store = Self.makeStore()
        let recorder = TokenRefreshRecorder()
        store.tokenCostInteractionResumeDelay = 0.01
        store._setTokenSnapshotForTesting(Self.tokenSnapshot(), provider: .codex)
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
        }

        store.beginInteractiveMenuTokenCostDeferral(reason: "test-menu-open")
        store.scheduleTokenRefresh(force: false, reason: "test-stale-chart")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.calls.isEmpty)

        store.endInteractiveMenuTokenCostDeferral(reason: "test-menu-close")
        #expect(await recorder.waitUntilCalls(count: 1))
        #expect(await recorder.calls.map(\.provider) == [.codex])
        #expect(await recorder.calls.map(\.force) == [false])
    }

    @Test
    func `menu interaction cancels token refresh even when unrelated provider is queued`() {
        let store = Self.makeStore()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        store.tokenRefreshSequenceTask = task
        store.tokenRefreshQueuedProviders = [.gemini]

        store.beginInteractiveMenuTokenCostDeferral(reason: "test-menu-open")

        #expect(task.isCancelled)
        store.tokenRefreshSequenceTask = nil
        store.endInteractiveMenuTokenCostDeferral(reason: "test-menu-close")
    }

    @Test
    func `menu interaction keeps protected missing chart refresh running`() {
        let store = Self.makeStore()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        store.tokenRefreshSequenceTask = task
        store.tokenRefreshQueuedProviders = [.codex]
        store.tokenRefreshMenuAllowedProviders = [.codex]

        store.beginInteractiveMenuTokenCostDeferral(reason: "test-menu-open")

        #expect(!task.isCancelled)
        task.cancel()
        store.tokenRefreshSequenceTask = nil
        store.endInteractiveMenuTokenCostDeferral(reason: "test-menu-close")
    }

    @Test
    func `menu interaction cancels stale in-flight refresh even with protected pending work`() {
        let store = Self.makeStore()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        store.tokenRefreshSequenceTask = task
        store.tokenRefreshQueuedProviders = [.claude, .codex]
        store.tokenRefreshMenuAllowedProviders = [.codex]
        store.tokenRefreshInFlightStartedAt[.claude] = Date()

        store.beginInteractiveMenuTokenCostDeferral(reason: "test-menu-open")

        #expect(task.isCancelled)
        store.tokenRefreshSequenceTask = nil
        store.endInteractiveMenuTokenCostDeferral(reason: "test-menu-close")
    }

    @Test
    func `menu interaction refreshes providers immediately but defers forced token-cost refresh until idle`() async {
        let store = Self.makeStore()
        let providerRecorder = ProviderRefreshRecorder()
        let tokenRecorder = TokenRefreshRecorder()
        store.tokenCostInteractionResumeDelay = 0.01
        store._test_providerRefreshOverride = { provider in
            await providerRecorder.record(provider: provider)
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await tokenRecorder.record(provider: provider, force: force)
        }

        store.beginInteractiveMenuTokenCostDeferral(reason: "test-menu-open")
        await store.refresh(forceTokenUsage: true)

        #expect(await providerRecorder.calls == [.codex])
        #expect(await tokenRecorder.calls.isEmpty)

        store.endInteractiveMenuTokenCostDeferral(reason: "test-menu-close")
        #expect(await tokenRecorder.waitUntilCalls(count: 1))

        #expect(await providerRecorder.calls == [.codex])
        #expect(await tokenRecorder.calls.map(\.provider) == [.codex])
        #expect(await tokenRecorder.calls.map(\.force) == [true])
    }

    private static func makeStore() -> UsageStore {
        let suite = "UsageStoreManualTokenRefreshTests-\(UUID().uuidString)"
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
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func tokenSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 150,
            sessionCostUSD: 0.12,
            last30DaysTokens: 150,
            last30DaysCostUSD: 0.12,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-28",
                    inputTokens: 100,
                    outputTokens: 50,
                    totalTokens: 150,
                    costUSD: 0.12,
                    modelsUsed: ["gpt-5"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5",
                            costUSD: 0.12,
                            totalTokens: 150),
                    ]),
            ],
            updatedAt: Date())
    }

    private static func waitUntil(timeout: Duration, predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while !predicate() {
            if start.duration(to: .now) >= timeout { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
