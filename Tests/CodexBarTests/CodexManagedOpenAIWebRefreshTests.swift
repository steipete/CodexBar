import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct CodexManagedOpenAIWebRefreshTests {
    @Test
    func `manual cookie import bypasses same account refresh coalescing`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebRefreshTests-manual-import-bypass-coalesce")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }
        store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
            OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "Chrome",
                cookieCount: 2,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }
        defer { store._test_openAIDashboardCookieImportOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        let firstTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)
        }
        await blocker.waitUntilStarted(count: 1)

        let manualImportTask = Task {
            await store.importOpenAIDashboardBrowserCookiesNow()
        }
        await blocker.waitUntilStarted(count: 2)

        await blocker.resumeNext(with: .success(OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 70,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 1,
            accountPlan: "Free",
            updatedAt: Date())))
        await blocker.resumeNext(with: .success(OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 95,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 25,
            accountPlan: "Pro",
            updatedAt: Date())))

        await firstTask.value
        await manualImportTask.value

        #expect(await blocker.startedCount() == 2)
        #expect(store.openAIDashboard?.creditsRemaining == 25)
        #expect(store.openAIDashboard?.accountPlan == "Pro")
    }

    @Test
    func `stale cookie import status does not override later unrelated refresh failure`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebRefreshTests-stale-cookie-status")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store.openAIDashboardCookieImportStatus =
            "OpenAI cookies are for other@example.com, not managed@example.com."
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            throw ManagedDashboardTestError.networkTimeout
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(store.lastOpenAIDashboardError == ManagedDashboardTestError.networkTimeout.localizedDescription)
    }

    @Test
    func `reset open A I web state blocks stale in flight dashboard completion`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebRefreshTests-reset-invalidates-task")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        let refreshTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)
        }
        await blocker.waitUntilStarted()

        store.resetOpenAIWebState()
        #expect(store.openAIDashboardRefreshTaskToken == nil)

        await blocker.resumeNext(with: .success(OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 85,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 12,
            accountPlan: "Pro",
            updatedAt: Date())))

        await refreshTask.value

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError == nil)
    }

    @Test
    func `active refresh failure ignores stale import status from older task`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebRefreshTests-concurrent-import-status")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let blocker = BlockingManagedOpenAIDashboardLoader()
        let importTracker = OpenAIDashboardImportCallTracker()
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }
        store._test_openAIDashboardCookieImportOverride = { _, _, _, _, _ in
            let call = await importTracker.recordCall()
            if call == 1 {
                return OpenAIDashboardBrowserCookieImporter.ImportResult(
                    sourceLabel: "Chrome",
                    cookieCount: 2,
                    signedInEmail: managedAccount.email,
                    matchesCodexEmail: true)
            }
            throw OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(
                found: [.init(sourceLabel: "Chrome", email: "other@example.com")])
        }
        defer { store._test_openAIDashboardCookieImportOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        let firstTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)
        }
        await blocker.waitUntilStarted(count: 1)

        let secondTask = Task {
            await store.importOpenAIDashboardBrowserCookiesNow()
        }
        await blocker.waitUntilStarted(count: 2)

        await blocker.resumeNext(with: .failure(OpenAIDashboardFetcher.FetchError.loginRequired))
        await importTracker.waitUntilCalls(count: 2)
        await blocker.resumeNext(with: .failure(ManagedDashboardTestError.networkTimeout))

        await firstTask.value
        await secondTask.value

        #expect(store.lastOpenAIDashboardError == ManagedDashboardTestError.networkTimeout.localizedDescription)
    }

    @Test
    func `post import retry timeout exceeds normal retry timeout`() {
        #expect(UsageStore.openAIWebRetryDashboardFetchTimeout(afterCookieImport: false) == 8)
        #expect(UsageStore.openAIWebRetryDashboardFetchTimeout(afterCookieImport: true) == 25)
    }

    private func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}

private enum ManagedDashboardTestError: LocalizedError {
    case networkTimeout

    var errorDescription: String? {
        switch self {
        case .networkTimeout:
            "Network timeout"
        }
    }
}

private actor BlockingManagedOpenAIDashboardLoader {
    private var continuations: [CheckedContinuation<Result<OpenAIDashboardSnapshot, Error>, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var started: Int = 0

    func awaitResult() async throws -> OpenAIDashboardSnapshot {
        self.started += 1
        self.resumeReadyStartWaiters()
        let result = await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
        return try result.get()
    }

    func waitUntilStarted(count: Int = 1) async {
        if self.started >= count { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append((count: count, continuation: continuation))
        }
    }

    func startedCount() -> Int {
        self.started
    }

    func resumeNext(with result: Result<OpenAIDashboardSnapshot, Error>) {
        guard !self.continuations.isEmpty else { return }
        let continuation = self.continuations.removeFirst()
        continuation.resume(returning: result)
    }

    private func resumeReadyStartWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in self.startWaiters {
            if self.started >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.startWaiters = remaining
    }
}

private actor OpenAIDashboardImportCallTracker {
    private var calls: Int = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordCall() -> Int {
        self.calls += 1
        self.resumeReadyWaiters()
        return self.calls
    }

    func waitUntilCalls(count: Int) async {
        if self.calls >= count { return }
        await withCheckedContinuation { continuation in
            self.waiters.append((count: count, continuation: continuation))
        }
    }

    private func resumeReadyWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in self.waiters {
            if self.calls >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.waiters = remaining
    }
}
