import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStorePiHistoryScopeTests {
    @Test
    func `concurrent Pi history consumers share one pending scope resolution`() async {
        let store = Self.makeStore()
        let resolver = PiHistoryScopeResolutionGate()
        let secondStarted = PiHistoryScopeCallSignal()
        store._test_piHistoryScopeResolver = { _ in await resolver.resolve() }

        let first = Task { @MainActor in
            await store.refreshPiHistoryScope(for: .codex)
        }
        await resolver.waitForStart()
        #expect(store.piHistoryScopeRefreshTask != nil)
        #expect(store.piHistoryScopeGeneration == 0)

        let second = Task { @MainActor in
            // Signal synchronously, then enter refresh without yielding the main actor.
            secondStarted.signal()
            return await store.refreshPiHistoryScope(for: .claude)
        }
        await secondStarted.wait()
        await resolver.release("scope-A")
        let firstSucceeded = await first.value
        let secondSucceeded = await second.value
        let coalescedCallCount = await resolver.callCount

        #expect(firstSucceeded)
        #expect(secondSucceeded)
        #expect(coalescedCallCount == 1)
        #expect(store.piHistoryScopeFingerprint == "scope-A")
        #expect(store.piHistoryScopeGeneration == 1)
        #expect(store.piHistoryScopeRefreshTask == nil)

        // Completion must clear the task so later refreshes inspect the source again.
        let refreshed = await store.refreshPiHistoryScope(for: .codex)
        let subsequentCallCount = await resolver.callCount
        #expect(refreshed)
        #expect(subsequentCallCount == 2)
        #expect(store.piHistoryScopeGeneration == 1)
        #expect(store.piHistoryScopeRefreshTask == nil)
    }

    @Test
    func `returning to the same Pi roots rejects publication from their previous generation`() async {
        let store = Self.makeStore()
        let resolver = PiHistoryScopeResolverState("scope-A")
        store._test_piHistoryScopeResolver = { _ in await resolver.resolve() }

        #expect(await store.refreshPiHistoryScope(for: .codex))
        let firstGeneration = store.piHistoryScopeGeneration
        let firstSignature = store.tokenSnapshotScopeSignature(for: .codex)
        let firstDashboardSignature = store.spendDashboardTokenSnapshotScopeSignature(for: .codex)
        let originalPublication = store.tokenRefreshPublicationScope(
            for: .codex,
            historyDays: store.settings.costUsageHistoryDays,
            costScopeSignature: firstSignature)
        #expect(store.tokenRefreshPublicationDisposition(
            provider: .codex,
            scope: originalPublication) == .current)

        #expect(await store.refreshPiHistoryScope(for: .claude))
        #expect(store.piHistoryScopeGeneration == firstGeneration)
        #expect(store.tokenSnapshotScopeSignature(for: .codex) == firstSignature)
        #expect(store.spendDashboardTokenSnapshotScopeSignature(for: .codex) == firstDashboardSignature)

        await resolver.setFingerprint("scope-B")
        #expect(await store.refreshPiHistoryScope(for: .codex))
        #expect(store.piHistoryScopeGeneration == firstGeneration + 1)
        #expect(store.tokenRefreshPublicationDisposition(
            provider: .codex,
            scope: originalPublication) == .scopeChanged)

        await resolver.setFingerprint("scope-A")
        #expect(await store.refreshPiHistoryScope(for: .codex))
        #expect(store.piHistoryScopeFingerprint == "scope-A")
        #expect(store.piHistoryScopeGeneration == firstGeneration + 2)
        // The fingerprint matches again; only the generation distinguishes this publication.
        #expect(store.tokenAccountingScopeIsCurrent(.piOnly(scope: "scope-A"), for: .codex))
        #expect(store.tokenSnapshotScopeSignature(for: .codex) != firstSignature)
        #expect(store.spendDashboardTokenSnapshotScopeSignature(for: .codex) != firstDashboardSignature)
        #expect(store.tokenRefreshPublicationDisposition(
            provider: .codex,
            scope: originalPublication) == .scopeChanged)

        let currentPublication = store.tokenRefreshPublicationScope(
            for: .codex,
            historyDays: store.settings.costUsageHistoryDays,
            costScopeSignature: store.tokenSnapshotScopeSignature(for: .codex))
        #expect(store.tokenRefreshPublicationDisposition(
            provider: .codex,
            scope: currentPublication) == .current)
    }

    private static func makeStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStorePiHistoryScopeTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        settings.refreshFrequency = .fiveMinutes
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == .claude)
        }
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}

private actor PiHistoryScopeResolutionGate {
    private(set) var callCount = 0
    private var releasedFingerprint: String?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resolutionWaiters: [CheckedContinuation<String, Never>] = []

    func resolve() async -> String {
        self.callCount += 1
        let waiters = self.startWaiters
        self.startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let fingerprint = self.releasedFingerprint { return fingerprint }
        return await withCheckedContinuation { continuation in
            self.resolutionWaiters.append(continuation)
        }
    }

    func waitForStart() async {
        guard self.callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func release(_ fingerprint: String) {
        self.releasedFingerprint = fingerprint
        let waiters = self.resolutionWaiters
        self.resolutionWaiters.removeAll()
        waiters.forEach { $0.resume(returning: fingerprint) }
    }
}

@MainActor
private final class PiHistoryScopeCallSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        self.signaled = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        guard !self.signaled else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }
}

private actor PiHistoryScopeResolverState {
    private var fingerprint: String

    init(_ fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func setFingerprint(_ fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func resolve() -> String {
        self.fingerprint
    }
}
