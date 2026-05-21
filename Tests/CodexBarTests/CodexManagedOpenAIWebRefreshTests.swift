import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct CodexManagedOpenAIWebRefreshTests {
    @Test
    func `regular refresh does not await OpenAI web scrape`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebRefreshTests-regular-refresh-nonblocking")
        settings.statusChecksEnabled = false
        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        let managedHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? Self.writeCodexAuthFile(
            homeURL: managedHomeURL,
            email: "managed@example.com",
            plan: "Pro")
        defer { try? FileManager.default.removeItem(at: managedHomeURL) }
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHomeURL.path,
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
        let completion = RefreshCompletionProbe()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let refreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await completion.markCompleted()
        }

        try? await Task.sleep(for: .milliseconds(200))

        #expect(await blocker.startedCount() == 1)
        #expect(await completion.isCompleted == true)

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

        await refreshTask.value
    }

    @Test
    func `regular refresh does not await Codex credits fetch`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexManagedOpenAIWebRefreshTests-regular-refresh-nonblocking-credits")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        let managedHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? Self.writeCodexAuthFile(
            homeURL: managedHomeURL,
            email: "managed@example.com",
            plan: "Pro")
        defer { try? FileManager.default.removeItem(at: managedHomeURL) }
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHomeURL.path,
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
        let blocker = BlockingCreditsLoader()
        let completion = RefreshCompletionProbe()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            try await blocker.awaitResult()
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let refreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await completion.markCompleted()
        }

        await blocker.waitUntilStarted(count: 1)

        #expect(await blocker.startedCount() == 1)
        #expect(await completion.isCompleted == true)

        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())))

        await refreshTask.value
    }

    @Test
    func `rapid regular refreshes coalesce concurrent Codex credits fetches`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexManagedOpenAIWebRefreshTests-credits-coalescing")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        let managedHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? Self.writeCodexAuthFile(
            homeURL: managedHomeURL,
            email: "managed@example.com",
            plan: "Pro")
        defer { try? FileManager.default.removeItem(at: managedHomeURL) }
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHomeURL.path,
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
        let blocker = BlockingCreditsLoader()
        let firstCompletion = RefreshCompletionProbe()
        let secondCompletion = RefreshCompletionProbe()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            try await blocker.awaitResult()
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let firstRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await firstCompletion.markCompleted()
        }
        await blocker.waitUntilStarted(count: 1)
        #expect(await firstCompletion.isCompleted == true)

        let secondRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
            await secondCompletion.markCompleted()
        }

        try? await Task.sleep(for: .milliseconds(200))

        #expect(await blocker.startedCount() == 1)
        #expect(await secondCompletion.isCompleted == true)

        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())))

        await firstRefreshTask.value
        await secondRefreshTask.value
    }

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
    func `navigation timeout imports cookies and retries dashboard refresh`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebRefreshTests-timeout-import-retry")
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
        store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
            _ = await importTracker.recordCall()
            return OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "Chrome",
                cookieCount: 2,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }
        defer { store._test_openAIDashboardCookieImportOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        let refreshTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)
        }
        await blocker.waitUntilStarted(count: 1)

        await blocker.resumeNext(with: .failure(URLError(.timedOut)))
        await importTracker.waitUntilCalls(count: 1)
        await blocker.waitUntilStarted(count: 2)
        await blocker.resumeNext(with: .success(OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 90,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 25,
            accountPlan: "Pro",
            updatedAt: Date())))

        await refreshTask.value

        #expect(await blocker.startedCount() == 2)
        #expect(store.openAIDashboard?.creditsRemaining == 25)
        #expect(store.lastOpenAIDashboardError == nil)
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
        #expect(UsageStore.openAIWebDashboardFetchTimeout(didImportCookies: false) == 25)
        #expect(UsageStore.openAIWebDashboardFetchTimeout(didImportCookies: true) == 25)
        #expect(UsageStore.openAIWebRetryDashboardFetchTimeout(afterCookieImport: false) == 8)
        #expect(UsageStore.openAIWebRetryDashboardFetchTimeout(afterCookieImport: true) == 25)
    }

    private func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        return settings
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String, accountId: String? = nil) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan, accountId: accountId),
        ]
        if let accountId {
            tokens["accountId"] = accountId
        }
        let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String, accountId: String? = nil) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var authClaims: [String: Any] = [
            "chatgpt_plan_type": plan,
        ]
        if let accountId {
            authClaims["chatgpt_account_id"] = accountId
        }
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": authClaims,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
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

private actor RefreshCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        self.isCompleted = true
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

private actor BlockingCreditsLoader {
    private var continuations: [CheckedContinuation<Result<CreditsSnapshot, Error>, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var started = 0

    func awaitResult() async throws -> CreditsSnapshot {
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

    func resumeNext(with result: Result<CreditsSnapshot, Error>) {
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
