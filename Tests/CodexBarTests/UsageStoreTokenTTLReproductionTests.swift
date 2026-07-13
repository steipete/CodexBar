import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor TokenRefreshGate {
    private var didStart = false
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
}

private actor TokenRefreshRecorder {
    private(set) var calls: [(provider: UsageProvider, force: Bool)] = []

    func record(provider: UsageProvider, force: Bool) {
        self.calls.append((provider, force))
    }

    func clear() {
        self.calls.removeAll()
    }
}

@MainActor
@Suite(.serialized)
struct UsageStoreTokenTTLReproductionTests {
    @Test
    func `token refresh follows configured frequency and cooldown checks`() async throws {
        let store = Self.makeStore()
        let gate = TokenRefreshGate()
        let recorder = TokenRefreshRecorder()

        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
            await gate.start(provider: provider, force: force)
            await gate.waitForRelease()
        }

        // Test Case 1: First refresh (no last fetch) -> triggers fetch
        let t1 = Task { @MainActor in await store.refresh(forceTokenUsage: false) }
        await gate.waitForStart()
        await gate.release()
        await t1.value
        #expect(await recorder.calls.count == 1)
        await recorder.clear()

        // Test Case 2: Immediate second refresh (0s elapsed < 60s TTL) -> skipped
        await store.refresh(forceTokenUsage: false)
        #expect(await recorder.calls.isEmpty)

        // Test Case 3: Pass 61 seconds (by faking lastTokenFetchAt to be 61s ago) -> triggers fetch
        let originalLast = try #require(store.lastTokenFetchAt[.codex])
        store.lastTokenFetchAt[.codex] = originalLast.addingTimeInterval(-61)

        let gate2 = TokenRefreshGate()
        store._test_tokenUsageRefreshOverride = { provider, force in
            await recorder.record(provider: provider, force: force)
            await gate2.start(provider: provider, force: force)
            await gate2.waitForRelease()
        }

        let t2 = Task { @MainActor in await store.refresh(forceTokenUsage: false) }
        await gate2.waitForStart()
        await gate2.release()
        await t2.value
        #expect(await recorder.calls.count == 1)
        await recorder.clear()

        // Test Case 4: If refreshFrequency is .thirtyMinutes, 61s elapsed is still within the 30-minute TTL -> skipped
        store.settings.refreshFrequency = .thirtyMinutes
        store.lastTokenFetchAt[.codex] = Date().addingTimeInterval(-61) // 61s ago
        await store.refresh(forceTokenUsage: false)
        #expect(await recorder.calls.isEmpty)
    }

    private static func makeStore() -> UsageStore {
        let settings = testSettingsStore(suiteName: "UsageStoreTokenTTLReproductionTests")
        settings.refreshFrequency = .oneMinute
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
                enabled: provider == .codex)
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
