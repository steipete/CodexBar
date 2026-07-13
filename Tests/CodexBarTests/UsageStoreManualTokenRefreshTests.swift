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
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
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
        let waiters = self.finishWaiters
        self.finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func hasFinished() -> Bool {
        self.didFinish
    }

    func waitForFinish() async {
        if self.didFinish { return }
        await withCheckedContinuation { continuation in
            self.finishWaiters.append(continuation)
        }
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

    func waitForCallCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.calls.count < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
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
    func `scoped manual refresh drains scheduled token-cost refresh before forced pass`() async {
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
            await store.refreshTokenUsageNow(for: .codex, force: true)
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
    func `scoped manual refresh leaves unrelated scheduled token-cost refresh running`() async {
        let store = Self.makeStore(enabledProviders: [.claude, .codex])
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
            await store.refreshTokenUsageNow(for: .claude, force: true)
            await completion.markCompleted()
        }

        await forcedGate.waitForStart()
        #expect(await scheduledGate.hasFinished() == false)
        #expect(await completion.isCompleted() == false)
        #expect(await recorder.calls.map(\.provider) == [.codex, .claude])
        #expect(await recorder.calls.map(\.force) == [false, true])

        await forcedGate.release()
        await task.value
        #expect(await completion.isCompleted())
        #expect(await scheduledGate.hasFinished() == false)

        await scheduledGate.release()
        await scheduledGate.waitForFinish()
    }

    @Test
    func `scoped manual refresh preserves an unrelated token sequence before it starts`() async {
        let store = Self.makeStore(enabledProviders: [.claude, .codex])
        let recorder = TokenRefreshRecorder()
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
        }

        // Do not yield between installing the scheduled slot and starting the scoped refresh. This
        // exercises the window before the scheduled task receives its first MainActor turn.
        store.scheduleTokenRefreshForTesting()
        await store.refreshTokenUsageNow(for: .claude, force: true)

        let recordedBothRefreshes = await recorder.waitForCallCount(2)
        #expect(recordedBothRefreshes)
        let scheduledTask = store.tokenRefreshSequenceTask
        await scheduledTask?.value

        let calls = await recorder.calls
        #expect(calls.contains { $0.provider == .codex && !$0.force })
        #expect(calls.contains { $0.provider == .claude && $0.force })
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
    func `forced background refresh bypasses a fresh token cache`() async {
        let store = Self.makeStore()
        let recorder = TokenRefreshRecorder()
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        await store.refresh(forceTokenUsage: false)
        let didRecordScheduledRefresh = await recorder.waitForCallCount(1)
        #expect(didRecordScheduledRefresh)
        guard didRecordScheduledRefresh else {
            store.cancelForcedRefreshEnrichment()
            return
        }
        await store.refresh(enrichmentMode: .forcedBackground)
        await store.awaitForcedRefreshEnrichment()

        #expect(await recorder.calls.map(\.provider) == [.codex, .codex])
        #expect(await recorder.calls.map(\.force) == [false, true])
    }

    private static func makeStore(enabledProviders: Set<UsageProvider> = [.codex]) -> UsageStore {
        let settings = testSettingsStore(suiteName: "UsageStoreManualTokenRefreshTests")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: enabledProviders.contains(provider))
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }
}
