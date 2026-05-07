import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexAccountsSettingsSectionTests {
    @Test
    func `codex accounts section shows live badge only for live only multi account row`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-live-badge")
        let store = Self.makeUsageStore(settings: settings)
        let managedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managedStoreURL) }

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccount]))

        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())
        let liveAccount = try #require(state.visibleAccounts.first { $0.email == "live@example.com" })
        let managedVisibleAccount = try #require(state.visibleAccounts.first { $0.email == "managed@example.com" })

        #expect(state.showsLiveBadge(for: liveAccount))
        #expect(state.showsLiveBadge(for: managedVisibleAccount) == false)
    }

    @Test
    func `single account codex settings uses simple account view instead of picker`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-single-account")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "solo@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.visibleAccounts.count == 1)
        #expect(state.showsActivePicker == false)
        #expect(state.singleVisibleAccount?.email == "solo@example.com")
    }

    @Test
    func `single account codex settings state includes workspace display name`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-single-workspace")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "solo@example.com",
            workspaceLabel: "Team Alpha",
            workspaceAccountID: "account-live",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "account-live"))

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.singleVisibleAccount?.displayName == "solo@example.com — Team Alpha")
    }

    @Test
    func `codex accounts section disables managed mutations when store is unreadable`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-unreadable")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_unreadableManagedCodexAccountStore = true
        defer { settings._test_unreadableManagedCodexAccountStore = false }

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())
        let liveAccount = try #require(state.visibleAccounts.first)

        #expect(state.hasUnreadableManagedAccountStore)
        #expect(state.canAddAccount == false)
        #expect(state.notice?.tone == .warning)
        #expect(state.canReauthenticate(liveAccount))
    }

    @Test
    func `selecting merged visible account from settings keeps live system source`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-select-merged")
        let store = Self.makeUsageStore(settings: settings)
        let managedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managedStoreURL) }

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "same@example.com",
            managedHomePath: "/tmp/managed",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccount]))

        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "SAME@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)

        let pane = ProvidersPane(settings: settings, store: store)
        await pane._test_selectCodexVisibleAccount(id: "same@example.com")

        #expect(settings.codexActiveSource == .liveSystem)
        let state = try #require(pane._test_codexAccountsSectionState())
        #expect(state.activeVisibleAccountID == "same@example.com")
    }

    @Test
    func `settings account selection can target the managed row when same email rows split by identity`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-select-split")
        let store = Self.makeUsageStore(settings: settings)
        let managedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: managedStoreURL)
            try? FileManager.default.removeItem(at: managedHome)
        }

        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "same@example.com",
            plan: "pro",
            accountID: "account-managed")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "same@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccount]))

        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "SAME@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "same@example.com"))
        settings.codexActiveSource = .liveSystem

        let pane = ProvidersPane(settings: settings, store: store)
        let initialState = try #require(pane._test_codexAccountsSectionState())
        let managedVisibleAccount = try #require(initialState.visibleAccounts
            .first { $0.storedAccountID == managedAccount.id })

        await pane._test_selectCodexVisibleAccount(id: managedVisibleAccount.id)

        #expect(settings.codexActiveSource == .managedAccount(id: managedAccount.id))
        let updatedState = try #require(pane._test_codexAccountsSectionState())
        #expect(updatedState.activeVisibleAccountID == managedVisibleAccount.id)
    }

    @Test
    func `codex accounts section disables add and reauth while managed authentication is in flight`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-in-flight")
        let store = Self.makeUsageStore(settings: settings)
        let managedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managedStoreURL) }

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccount]))
        settings._test_managedCodexAccountStoreURL = managedStoreURL

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = BlockingManagedCodexLoginRunnerForSettingsSectionTests()
        let service = ManagedCodexAccountService(
            store: managedStore,
            homeFactory: TestManagedCodexHomeFactoryForSettingsSectionTests(root: root),
            loginRunner: runner,
            identityReader: StubManagedCodexIdentityReaderForSettingsSectionTests(emails: ["managed@example.com"]))
        let coordinator = ManagedCodexAccountCoordinator(service: service)
        let authTask = Task { try await coordinator.authenticateManagedAccount() }
        await runner.waitUntilStarted()

        let pane = ProvidersPane(
            settings: settings,
            store: store,
            managedCodexAccountCoordinator: coordinator)
        let state = try #require(pane._test_codexAccountsSectionState())
        let visibleAccount = try #require(state.visibleAccounts.first { $0.email == "managed@example.com" })

        #expect(state.canAddAccount == false)
        #expect(state.addAccountTitle == "Adding Account…")
        #expect(state.canReauthenticate(visibleAccount) == false)

        await runner.resume()
        _ = try await authTask.value
    }

    @Test
    func `adding managed codex account auto selects the merged live row`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-add-merged")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "same@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let coordinator = Self.makeManagedCoordinator(settings: settings, email: "same@example.com")
        let pane = ProvidersPane(
            settings: settings,
            store: store,
            managedCodexAccountCoordinator: coordinator)

        await pane._test_addManagedCodexAccount()

        #expect(settings.codexActiveSource == .liveSystem)
        let state = try #require(pane._test_codexAccountsSectionState())
        #expect(state.activeVisibleAccountID == "same@example.com")
    }

    @Test
    func `adding managed codex account selects the new managed account when email differs`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-add-managed")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let coordinator = Self.makeManagedCoordinator(settings: settings, email: "managed@example.com")
        let pane = ProvidersPane(
            settings: settings,
            store: store,
            managedCodexAccountCoordinator: coordinator)

        await pane._test_addManagedCodexAccount()

        guard case .managedAccount = settings.codexActiveSource else {
            Issue.record("Expected the new managed account to become active")
            return
        }
        let state = try #require(pane._test_codexAccountsSectionState())
        #expect(state.activeVisibleAccountID == "managed@example.com")
    }

    private static func makeManagedCoordinator(
        settings: SettingsStore,
        email: String)
        -> ManagedCodexAccountCoordinator
    {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        settings._test_managedCodexAccountStoreURL = storeURL
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactoryForSettingsSectionTests(root: root),
            loginRunner: StubManagedCodexLoginRunnerForSettingsSectionTests.success,
            identityReader: StubManagedCodexIdentityReaderForSettingsSectionTests(emails: [email]))
        return ManagedCodexAccountCoordinator(service: service)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }
}

extension CodexAccountsSettingsSectionTests {
    private static func writeCodexAuthFile(
        homeURL: URL,
        email: String,
        plan: String,
        accountID: String? = nil) throws
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan, accountID: accountID),
        ]
        if let accountID {
            tokens["account_id"] = accountID
        }
        let auth = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String, accountID: String? = nil) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var payloadObject: [String: Any] = [
            "email": email,
            "chatgpt_plan_type": plan,
        ]
        if let accountID {
            payloadObject["https://api.openai.com/auth"] = [
                "chatgpt_account_id": accountID,
            ]
        }
        let payload = (try? JSONSerialization.data(withJSONObject: payloadObject)) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}

private struct TestManagedCodexHomeFactoryForSettingsSectionTests: ManagedCodexHomeProducing {
    let root: URL
    private let nextID = UUID().uuidString

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(self.nextID, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct StubManagedCodexLoginRunnerForSettingsSectionTests: ManagedCodexLoginRunning {
    let result: CodexLoginRunner.Result

    func run(homePath _: String, timeout _: TimeInterval) async -> CodexLoginRunner.Result {
        self.result
    }

    static let success = StubManagedCodexLoginRunnerForSettingsSectionTests(
        result: CodexLoginRunner.Result(outcome: .success, output: "ok"))
}

private actor BlockingManagedCodexLoginRunnerForSettingsSectionTests: ManagedCodexLoginRunning {
    private var waiters: [CheckedContinuation<CodexLoginRunner.Result, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func run(homePath _: String, timeout _: TimeInterval) async -> CodexLoginRunner.Result {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume() {
        let result = CodexLoginRunner.Result(outcome: .success, output: "ok")
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

private final class StubManagedCodexIdentityReaderForSettingsSectionTests: ManagedCodexIdentityReading,
@unchecked Sendable {
    private var emails: [String]

    init(emails: [String]) {
        self.emails = emails
    }

    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        let email = self.emails.isEmpty ? nil : self.emails.removeFirst()
        return CodexAuthBackedAccount(
            identity: CodexIdentityResolver.resolve(accountId: nil, email: email),
            email: email,
            plan: "Pro")
    }
}
