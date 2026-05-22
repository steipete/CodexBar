import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct CodexBackgroundRefreshCoalescingTests {
    @Test
    func `rapid regular refreshes coalesce concurrent Codex credits fetches`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-credits-coalescing")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
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
    func `regular credits refresh reschedules when Codex account changes`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-credits-account-switch")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        let alphaAccount = try Self.makeManagedAccount(email: "alpha@example.com")
        let betaAccount = try Self.makeManagedAccount(email: "beta@example.com")
        defer {
            try? FileManager.default.removeItem(atPath: alphaAccount.managedHomePath)
            try? FileManager.default.removeItem(atPath: betaAccount.managedHomePath)
        }
        settings._test_activeManagedCodexAccount = alphaAccount
        settings.codexActiveSource = .managedAccount(id: alphaAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = self.makeStore(settings: settings)
        let blocker = BlockingCreditsLoader()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            try await blocker.awaitResult()
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let alphaRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
        }
        await blocker.waitUntilStarted(count: 1)

        settings._test_activeManagedCodexAccount = betaAccount
        settings.codexActiveSource = .managedAccount(id: betaAccount.id)
        let betaRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
        }
        await blocker.waitUntilStarted(count: 2)

        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 10, events: [], updatedAt: Date())))
        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())))

        await alphaRefreshTask.value
        await betaRefreshTask.value
        await store.creditsRefreshTask?.value

        #expect(await blocker.startedCount() == 2)
        #expect(store.lastCreditsSnapshotAccountKey == "beta@example.com")
        #expect(store.credits?.remaining == 25)
    }

    @Test
    func `force refresh cancels stale background Codex credits fetch`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-credits-force-cancels-background")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let blocker = BlockingCreditsLoader()
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_codexCreditsLoaderOverride = {
            try await blocker.awaitResult()
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        let regularRefreshTask = Task {
            await store.refresh(forceTokenUsage: false)
        }
        await blocker.waitUntilStarted(count: 1)

        let forceRefreshTask = Task {
            await store.refresh(forceTokenUsage: true)
        }
        await blocker.waitUntilStarted(count: 2)

        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 10, events: [], updatedAt: Date())))
        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())))

        await regularRefreshTask.value
        await forceRefreshTask.value

        #expect(await blocker.startedCount() == 2)
        #expect(store.credits?.remaining == 25)
    }

    @Test
    func `rapid regular refreshes coalesce concurrent OpenAI dashboard fetches`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "CodexBackgroundRefreshCoalescingTests-dashboard-coalescing")
        settings.statusChecksEnabled = false
        let managedAccount = try Self.installManagedAccount(
            email: "managed@example.com",
            settings: settings)
        defer { try? FileManager.default.removeItem(atPath: managedAccount.managedHomePath) }

        let store = self.makeStore(settings: settings)
        let blocker = BlockingManagedOpenAIDashboardLoader()
        let firstCompletion = RefreshCompletionProbe()
        let secondCompletion = RefreshCompletionProbe()
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

        let backgroundTask = try #require(store.openAIDashboardBackgroundRefreshTask)
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

        await firstRefreshTask.value
        await secondRefreshTask.value
        await backgroundTask.value

        #expect(store.openAIDashboard?.creditsRemaining == 25)
    }

    private func makeSettingsStore(suite: String) throws -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.providerDetectionCompleted = true
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        return settings
    }

    private func makeStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private static func installManagedAccount(
        email: String,
        settings: SettingsStore) throws -> ManagedCodexAccount
    {
        let account = try Self.makeManagedAccount(email: email)
        settings._test_activeManagedCodexAccount = account
        settings.codexActiveSource = .managedAccount(id: account.id)
        return account
    }

    private static func makeManagedAccount(email: String) throws -> ManagedCodexAccount {
        let managedHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHomeURL,
            email: email,
            plan: "Pro")
        return ManagedCodexAccount(
            id: UUID(),
            email: email,
            managedHomePath: managedHomeURL.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan),
        ]
        let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": plan,
            ],
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
