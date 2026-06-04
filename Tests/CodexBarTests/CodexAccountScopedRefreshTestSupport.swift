import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
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
        settings.providerDetectionCompleted = true
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

    func makeUsageStore(settings: SettingsStore, environmentBase: [String: String] = [:]) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environmentBase)
    }

    func liveAccount(email: String, identity: CodexIdentity = .unresolved) -> ObservedSystemCodexAccount {
        ObservedSystemCodexAccount(
            email: email,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: identity)
    }

    func codexSnapshot(email: String, usedPercent: Double, resetsAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: resetsAt,
                resetDescription: nil),
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

    @MainActor
    func withCodexVisibleAccountFailureStore(
        suite: String,
        errorMessage: String,
        body: (UsageStore, RecordingCodexAccountUsageSnapshotStore, [CodexAccountUsageSnapshot]) async throws -> Void)
        async throws
    {
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let priorSnapshots = settings.codexVisibleAccountProjection.visibleAccounts.map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.codexSnapshot(email: account.email, usedPercent: 17),
                error: nil,
                sourceLabel: "cached")
        }
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        self.installFailingCodexProvider(
            on: store,
            error: TestRefreshError(message: errorMessage))

        try await body(store, snapshotStore, priorSnapshots)
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

    static func makeCodexProviderSpec(
        baseSpec: ProviderSpec,
        resolveStrategies: @escaping @Sendable (ProviderFetchContext) async -> [any ProviderFetchStrategy])
        -> ProviderSpec
    {
        let baseDescriptor = baseSpec.descriptor
        let descriptor = ProviderDescriptor(
            id: .codex,
            metadata: baseDescriptor.metadata,
            branding: baseDescriptor.branding,
            tokenCost: baseDescriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: resolveStrategies)),
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

final class RecordingCodexAccountUsageSnapshotStore: CodexAccountUsageSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var loadedSnapshots: [CodexAccountUsageSnapshot]
    private var snapshotsStored: [CodexAccountUsageSnapshot] = []

    init(initialSnapshots: [CodexAccountUsageSnapshot]) {
        self.loadedSnapshots = initialSnapshots
    }

    var storedSnapshots: [CodexAccountUsageSnapshot] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.snapshotsStored
    }

    func load(for accounts: [CodexVisibleAccount]) -> [CodexAccountUsageSnapshot] {
        self.lock.lock()
        defer { self.lock.unlock() }
        let accountIDs = Set(accounts.map(\.id))
        return self.loadedSnapshots.filter { accountIDs.contains($0.id) }
    }

    func store(_ snapshots: [CodexAccountUsageSnapshot]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.snapshotsStored = snapshots
    }
}

struct TestCodexFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot
    var credits: CreditsSnapshot?
    var id = "test-codex"
    var kind: ProviderFetchKind = .cli
    var sourceLabel = "test-codex"

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.loader()
        return self.makeResult(
            usage: snapshot,
            credits: self.credits,
            sourceLabel: self.sourceLabel)
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

    func waitUntilStartedWithin(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let startedAt = ContinuousClock.now
        while self.snapshots.count < count {
            if startedAt.duration(to: .now) >= timeout {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
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

actor RecordingWidgetSnapshotSaver {
    private var snapshots: [WidgetSnapshot] = []

    func save(_ snapshot: WidgetSnapshot) {
        self.snapshots.append(snapshot)
    }

    func waitUntilSavedWithin(count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let startedAt = ContinuousClock.now
        while self.snapshots.count < count {
            if startedAt.duration(to: .now) >= timeout {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func savedSnapshots() -> [WidgetSnapshot] {
        self.snapshots
    }
}
