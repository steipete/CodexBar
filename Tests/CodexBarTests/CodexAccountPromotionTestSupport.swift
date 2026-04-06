import CodexBarCore
import Foundation
@testable import CodexBar

@MainActor
final class CodexAccountPromotionTestContainer {
    let suiteName: String
    let rootURL: URL
    let liveHomeURL: URL
    let managedHomesURL: URL
    let managedStoreURL: URL
    let settings: SettingsStore
    let usageStore: UsageStore
    let fileStore: FileManagedCodexAccountStore
    let homeFactory: ManagedCodexHomeFactory
    let identityReader: DefaultManagedCodexIdentityReader
    let workspaceResolver: any ManagedCodexWorkspaceResolving
    let baseEnvironment: [String: String]

    init(
        suiteName: String,
        workspaceIdentities: [String: CodexOpenAIWorkspaceIdentity] = [:]) throws
    {
        self.suiteName = suiteName
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-account-promotion-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.liveHomeURL = self.rootURL.appendingPathComponent("liveHome", isDirectory: true)
        self.managedHomesURL = self.rootURL.appendingPathComponent("managed-codex-homes", isDirectory: true)
        self.managedStoreURL = self.rootURL.appendingPathComponent("managed-codex-accounts.json", isDirectory: false)
        self.baseEnvironment = ["CODEX_HOME": self.liveHomeURL.path]
        self.fileStore = FileManagedCodexAccountStore(fileURL: self.managedStoreURL, fileManager: .default)
        self.homeFactory = ManagedCodexHomeFactory(root: self.managedHomesURL, fileManager: .default)
        self.identityReader = DefaultManagedCodexIdentityReader()
        self.workspaceResolver = StubManagedCodexWorkspaceResolver(identities: workspaceIdentities)

        try FileManager.default.createDirectory(at: self.liveHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.managedHomesURL, withIntermediateDirectories: true)
        _ = try self.fileStore.ensureFileExists()

        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        self.settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        self.settings._test_activeManagedCodexAccount = nil
        self.settings._test_activeManagedCodexRemoteHomePath = nil
        self.settings._test_unreadableManagedCodexAccountStore = false
        self.settings._test_managedCodexAccountStoreURL = self.managedStoreURL
        self.settings._test_liveSystemCodexAccount = nil
        self.settings._test_codexReconciliationEnvironment = self.baseEnvironment
        self.settings.refreshFrequency = .manual
        self.settings.codexCookieSource = .off

        self.usageStore = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: self.settings,
            startupBehavior: .testing)
        self.installDynamicCodexUsageLoader()
        self.usageStore._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 17, events: [], updatedAt: Date())
        }
    }

    func tearDown() {
        self.usageStore._test_codexCreditsLoaderOverride = nil
        self.settings._test_activeManagedCodexAccount = nil
        self.settings._test_activeManagedCodexRemoteHomePath = nil
        self.settings._test_unreadableManagedCodexAccountStore = false
        self.settings._test_managedCodexAccountStoreURL = nil
        self.settings._test_liveSystemCodexAccount = nil
        self.settings._test_codexReconciliationEnvironment = nil
        self.settings.userDefaults.removePersistentDomain(forName: self.suiteName)
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func makeService(
        store: (any ManagedCodexAccountStoring)? = nil,
        liveAuthSwapper: (any CodexLiveAuthSwapping)? = nil,
        activeSourceWriter: (any CodexActiveSourceWriting)? = nil,
        accountScopedRefresher: (any CodexAccountScopedRefreshing)? = nil)
        -> CodexAccountPromotionService
    {
        CodexAccountPromotionService(
            store: store ?? self.fileStore,
            homeFactory: self.homeFactory,
            identityReader: self.identityReader,
            workspaceResolver: self.workspaceResolver,
            snapshotLoader: SettingsStoreCodexAccountReconciliationSnapshotLoader(settingsStore: self.settings),
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            liveAuthSwapper: liveAuthSwapper ?? DefaultCodexLiveAuthSwapper(),
            activeSourceWriter: activeSourceWriter
                ?? SettingsStoreCodexActiveSourceWriter(settingsStore: self.settings),
            accountScopedRefresher: accountScopedRefresher
                ?? UsageStoreCodexAccountScopedRefresher(usageStore: self.usageStore),
            baseEnvironment: self.baseEnvironment,
            fileManager: .default)
    }

    func installDynamicCodexUsageLoader(usedPercent: Double = 12) {
        let baseSpec = self.usageStore.providerSpecs[.codex]!
        self.usageStore
            .providerSpecs[.codex] = makeCodexProviderSpec(baseSpec: baseSpec) { [settings = self.settings] in
                let liveEmail = await MainActor.run {
                    settings.codexAccountReconciliationSnapshot.liveSystemAccount?.email ?? "unknown@example.com"
                }
                return UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: usedPercent,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: liveEmail,
                        accountOrganization: nil,
                        loginMethod: "Pro"))
            }
    }

    @discardableResult
    func createManagedAccount(
        id: UUID = UUID(),
        persistedEmail: String,
        authEmail: String? = nil,
        authAccountID: String? = nil,
        persistedProviderAccountID: String? = nil,
        useAuthAccountIDAsPersistedProviderAccountID: Bool = true,
        workspaceLabel: String? = nil,
        workspaceAccountID: String? = nil,
        plan: String = "Pro") throws -> ManagedCodexAccount
    {
        let homeURL = self.managedHomesURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let createdAt = Date().timeIntervalSince1970
        _ = try self.writeOAuthAuthFile(
            homeURL: homeURL,
            email: authEmail ?? persistedEmail,
            plan: plan,
            accountID: authAccountID)
        let persistedProviderAccountIDValue: String? =
            if useAuthAccountIDAsPersistedProviderAccountID {
                persistedProviderAccountID ?? authAccountID
            } else {
                persistedProviderAccountID
            }
        return ManagedCodexAccount(
            id: id,
            email: persistedEmail,
            providerAccountID: persistedProviderAccountIDValue,
            workspaceLabel: workspaceLabel,
            workspaceAccountID: workspaceAccountID ?? authAccountID,
            managedHomePath: homeURL.path,
            createdAt: createdAt,
            updatedAt: createdAt,
            lastAuthenticatedAt: createdAt)
    }

    func persistAccounts(_ accounts: [ManagedCodexAccount]) throws {
        try self.fileStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))
    }

    func loadAccounts() throws -> ManagedCodexAccountSet {
        try self.fileStore.loadAccounts()
    }

    @discardableResult
    func writeLiveOAuthAuthFile(
        email: String,
        plan: String = "Pro",
        accountID: String? = nil,
        apiKey: String? = nil) throws -> Data
    {
        try self.writeOAuthAuthFile(
            homeURL: self.liveHomeURL,
            email: email,
            plan: plan,
            accountID: accountID,
            apiKey: apiKey)
    }

    @discardableResult
    func writeLiveAPIKeyAuthFile(apiKey: String = "sk-live-only") throws -> Data {
        let data = try JSONSerialization.data(
            withJSONObject: ["OPENAI_API_KEY": apiKey],
            options: [.sortedKeys])
        try FileManager.default.createDirectory(at: self.liveHomeURL, withIntermediateDirectories: true)
        try data.write(to: Self.authFileURL(for: self.liveHomeURL), options: .atomic)
        return data
    }

    @discardableResult
    func writeLiveOAuthAuthFileWithoutEmail(accountID: String, apiKey: String? = nil) throws -> Data {
        try self.writeOAuthAuthFileWithoutEmail(
            homeURL: self.liveHomeURL,
            accountID: accountID,
            apiKey: apiKey)
    }

    @discardableResult
    func writeManagedOAuthAuthFileWithoutEmail(
        for account: ManagedCodexAccount,
        accountID: String,
        apiKey: String? = nil) throws -> Data
    {
        try self.writeOAuthAuthFileWithoutEmail(
            homeURL: URL(fileURLWithPath: account.managedHomePath, isDirectory: true),
            accountID: accountID,
            apiKey: apiKey)
    }

    @discardableResult
    private func writeOAuthAuthFileWithoutEmail(
        homeURL: URL,
        accountID: String,
        apiKey: String? = nil) throws -> Data
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let tokens: [String: Any] = [
            "accessToken": "access-\(accountID)",
            "refreshToken": "refresh-\(accountID)",
            "accountId": accountID,
        ]
        var json: [String: Any] = [
            "tokens": tokens,
            "last_refresh": "2026-04-05T00:00:00Z",
        ]
        if let apiKey {
            json["OPENAI_API_KEY"] = apiKey
        }

        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: Self.authFileURL(for: homeURL), options: .atomic)
        return data
    }

    func removeLiveAuthFile() throws {
        let authFileURL = Self.authFileURL(for: self.liveHomeURL)
        if FileManager.default.fileExists(atPath: authFileURL.path) {
            try FileManager.default.removeItem(at: authFileURL)
        }
    }

    func liveAuthData() throws -> Data? {
        let authFileURL = Self.authFileURL(for: self.liveHomeURL)
        guard FileManager.default.fileExists(atPath: authFileURL.path) else { return nil }
        return try Data(contentsOf: authFileURL)
    }

    func managedAuthData(for account: ManagedCodexAccount) throws -> Data {
        try Data(contentsOf: Self.authFileURL(for: URL(fileURLWithPath: account.managedHomePath, isDirectory: true)))
    }

    func managedHomeURLs() throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: self.managedHomesURL,
            includingPropertiesForKeys: nil)
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func seedScopedRefreshState(email: String, identity: CodexIdentity) {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 4, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Pro"))
        let credits = CreditsSnapshot(remaining: 3, events: [], updatedAt: Date())

        self.usageStore._setSnapshotForTesting(snapshot, provider: .codex)
        self.usageStore.credits = credits
        self.usageStore.lastCreditsSnapshot = credits
        self.usageStore.lastCreditsSnapshotAccountKey = email
        self.usageStore.lastCreditsSource = .api
        self.usageStore.lastCodexAccountScopedRefreshGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: identity,
            accountKey: email)
    }

    @discardableResult
    private func writeOAuthAuthFile(
        homeURL: URL,
        email: String,
        plan: String,
        accountID: String?,
        apiKey: String? = nil) throws -> Data
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

        var tokens: [String: Any] = [
            "accessToken": "access-\(email)",
            "refreshToken": "refresh-\(email)",
            "idToken": Self.fakeJWT(email: email, plan: plan, accountID: accountID),
        ]
        if let accountID {
            tokens["accountId"] = accountID
        }

        var json: [String: Any] = [
            "tokens": tokens,
            "last_refresh": "2026-04-05T00:00:00Z",
        ]
        if let apiKey {
            json["OPENAI_API_KEY"] = apiKey
        }

        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: Self.authFileURL(for: homeURL), options: .atomic)
        return data
    }

    private static func fakeJWT(email: String, plan: String, accountID: String?) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var authClaims: [String: Any] = [
            "chatgpt_plan_type": plan,
        ]
        if let accountID {
            authClaims["chatgpt_account_id"] = accountID
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

    private static func authFileURL(for homeURL: URL) -> URL {
        homeURL.appendingPathComponent("auth.json", isDirectory: false)
    }
}

private func makeCodexProviderSpec(
    baseSpec: ProviderSpec,
    loader: @escaping @Sendable () async throws -> UsageSnapshot) -> ProviderSpec
{
    let baseDescriptor = baseSpec.descriptor
    let strategy = TestPromotionCodexFetchStrategy(loader: loader)
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

private struct TestPromotionCodexFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot

    var id: String {
        "test-promotion-codex"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.loader()
        return self.makeResult(usage: snapshot, sourceLabel: "test-promotion-codex")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

final class RecordingManagedCodexAccountStore: ManagedCodexAccountStoring, @unchecked Sendable {
    let base: any ManagedCodexAccountStoring
    var storedSnapshots: [ManagedCodexAccountSet] = []
    var onStore: (@Sendable (ManagedCodexAccountSet) throws -> Void)?

    init(
        base: any ManagedCodexAccountStoring,
        onStore: (@Sendable (ManagedCodexAccountSet) throws -> Void)? = nil)
    {
        self.base = base
        self.onStore = onStore
    }

    func loadAccounts() throws -> ManagedCodexAccountSet {
        try self.base.loadAccounts()
    }

    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        self.storedSnapshots.append(accounts)
        try self.onStore?(accounts)
        try self.base.storeAccounts(accounts)
    }

    func ensureFileExists() throws -> URL {
        try self.base.ensureFileExists()
    }
}

final class RecordingCodexLiveAuthSwapper: CodexLiveAuthSwapping, @unchecked Sendable {
    let base: any CodexLiveAuthSwapping
    var swapCallCount = 0
    var swappedData: [Data] = []
    var onSwap: (@Sendable (Data, URL) throws -> Void)?

    init(
        base: any CodexLiveAuthSwapping = DefaultCodexLiveAuthSwapper(),
        onSwap: (@Sendable (Data, URL) throws -> Void)? = nil)
    {
        self.base = base
        self.onSwap = onSwap
    }

    func swapLiveAuthData(_ data: Data, liveHomeURL: URL) throws {
        self.swapCallCount += 1
        self.swappedData.append(data)
        try self.onSwap?(data, liveHomeURL)
        try self.base.swapLiveAuthData(data, liveHomeURL: liveHomeURL)
    }
}

enum PromotionTestError: Error, Equatable {
    case storeWriteFailed
    case swapFailed
    case unexpectedDisposition
}

private struct StubManagedCodexWorkspaceResolver: ManagedCodexWorkspaceResolving, Sendable {
    let identities: [String: CodexOpenAIWorkspaceIdentity]

    func resolveWorkspaceIdentity(
        homePath _: String,
        providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity?
    {
        self.identities[providerAccountID]
    }
}
