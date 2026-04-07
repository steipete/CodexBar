import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension CodexManagedOpenAIWebTests {
    @Test
    func `same account dashboard refresh requests coalesce while one is in flight`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-refresh-coalesce")
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
        let blocker = CoalescingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        let firstTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)
        }
        await blocker.waitUntilStarted()

        let secondTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await blocker.startedCount() == 1)

        await blocker.resume(with: .success(OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 90,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: 10,
            accountPlan: "Pro",
            updatedAt: Date())))

        await firstTask.value
        await secondTask.value

        #expect(await blocker.startedCount() == 1)
        #expect(store.openAIDashboard?.signedInEmail == managedAccount.email)
    }

    @Test
    func `friendly error shortens cookie mismatch copy`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-friendly-error-short")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        let message = store.openAIDashboardFriendlyError(
            body: "Sign in to continue",
            targetEmail: "ratulsarna@gmail.com",
            cookieImportStatus: "OpenAI cookies are for rdsarna@gmail.com, not ratulsarna@gmail.com.")

        #expect(
            message ==
                "OpenAI cookies are for rdsarna@gmail.com, not ratulsarna@gmail.com. " +
                "Switch chatgpt.com account, then refresh OpenAI cookies.")
    }

    func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings._test_activeManagedCodexAccount = nil
        settings._test_activeManagedCodexRemoteHomePath = nil
        settings._test_unreadableManagedCodexAccountStore = false
        settings._test_managedCodexAccountStoreURL = nil
        settings._test_liveSystemCodexAccount = nil
        settings._test_codexReconciliationEnvironment = nil
        return settings
    }

    static func writeCodexAuthFile(
        homeURL: URL,
        email: String,
        plan: String,
        accountId: String? = nil) throws
    {
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

    static func fakeJWT(email: String, plan: String, accountId: String? = nil) -> String {
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

actor CoalescingManagedOpenAIDashboardLoader {
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

    func resume(with result: Result<OpenAIDashboardSnapshot, Error>) {
        self.resumeNext(with: result)
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
