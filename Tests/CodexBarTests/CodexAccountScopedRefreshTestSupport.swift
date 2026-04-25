import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
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

    func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    func liveAccount(email: String, identity: CodexIdentity = .unresolved) -> ObservedSystemCodexAccount {
        ObservedSystemCodexAccount(
            email: email,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: identity)
    }

    func codexSnapshot(email: String, usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    func credits(remaining: Double) -> CreditsSnapshot {
        CreditsSnapshot(remaining: remaining, events: [], updatedAt: Date())
    }

    func dashboard(email: String, creditsRemaining: Double, usedPercent: Double) -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: 88,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondaryLimit: nil,
            creditsRemaining: creditsRemaining,
            accountPlan: "Pro",
            updatedAt: Date())
    }

    func makeManagedAccountStoreURL(accounts: [ManagedCodexAccount]) throws -> URL {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))
        return storeURL
    }

    func installBlockingCodexProvider(on store: UsageStore, blocker: BlockingCodexFetchStrategy) {
        let baseSpec = store.providerSpecs[.codex]!
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) {
            try await blocker.awaitResult()
        }
    }

    func installImmediateCodexProvider(on store: UsageStore, snapshot: UsageSnapshot) {
        let baseSpec = store.providerSpecs[.codex]!
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) {
            snapshot
        }
    }

    func installFailingCodexProvider(on store: UsageStore, error: Error) {
        let baseSpec = store.providerSpecs[.codex]!
        store.providerSpecs[.codex] = Self.makeThrowingCodexProviderSpec(baseSpec: baseSpec) {
            throw error
        }
    }

    static func makeCodexProviderSpec(
        baseSpec: ProviderSpec,
        loader: @escaping @Sendable () async throws -> UsageSnapshot) -> ProviderSpec
    {
        let baseDescriptor = baseSpec.descriptor
        let strategy = TestCodexFetchStrategy(loader: loader)
        let descriptor = ProviderDescriptor(
            id: .codex,
            metadata: baseDescriptor.metadata,
            branding: baseDescriptor.branding,
            tokenCost: baseDescriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth],
                pipeline: ProviderFetchPipeline { _ in [strategy] }),
            cli: baseDescriptor.cli)
        return ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)
    }

    static func makeThrowingCodexProviderSpec(
        baseSpec: ProviderSpec,
        loader: @escaping @Sendable () async throws -> UsageSnapshot) -> ProviderSpec
    {
        let baseDescriptor = baseSpec.descriptor
        let strategy = ThrowingTestCodexFetchStrategy(loader: loader)
        let descriptor = ProviderDescriptor(
            id: .codex,
            metadata: baseDescriptor.metadata,
            branding: baseDescriptor.branding,
            tokenCost: baseDescriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth],
                pipeline: ProviderFetchPipeline { _ in [strategy] }),
            cli: baseDescriptor.cli)
        return ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)
    }
}

struct TestRefreshError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

struct TestCodexFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot

    var id: String {
        "test-codex"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.loader()
        return self.makeResult(usage: snapshot, sourceLabel: "test-codex")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

struct ThrowingTestCodexFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot

    var id: String {
        "test-codex-throwing"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.loader()
        return self.makeResult(usage: snapshot, sourceLabel: "test-codex-throwing")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

actor BlockingCodexFetchStrategy {
    private var waiters: [CheckedContinuation<Result<UsageSnapshot, Error>, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func awaitResult() async throws -> UsageSnapshot {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        let result = await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
        return try result.get()
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume(with result: Result<UsageSnapshot, Error>) {
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

actor BlockingOpenAIDashboardLoader {
    private var waiters: [CheckedContinuation<Result<OpenAIDashboardSnapshot, Error>, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func awaitResult() async throws -> OpenAIDashboardSnapshot {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        let result = await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
        return try result.get()
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume(with result: Result<OpenAIDashboardSnapshot, Error>) {
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

actor BlockingWidgetSnapshotSaver {
    private var snapshots: [WidgetSnapshot] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func save(_ snapshot: WidgetSnapshot) async {
        self.snapshots.append(snapshot)
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func waitUntilStarted(count: Int) async {
        if self.snapshots.count >= count { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func startedCount() -> Int {
        self.snapshots.count
    }

    func resumeNext() {
        guard !self.waiters.isEmpty else { return }
        let waiter = self.waiters.removeFirst()
        waiter.resume()
    }

    func savedSnapshots() -> [WidgetSnapshot] {
        self.snapshots
    }
}
