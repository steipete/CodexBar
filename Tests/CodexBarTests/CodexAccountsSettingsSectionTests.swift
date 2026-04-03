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
            codexHomePath: "/tmp/test-codex-home",
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
            codexHomePath: "/tmp/test-codex-home",
            observedAt: Date())

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.visibleAccounts.count == 1)
        #expect(state.showsActivePicker == false)
        #expect(state.singleVisibleAccount?.email == "solo@example.com")
    }

    @Test
    func `codex accounts section disables managed mutations when store is unreadable`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-unreadable")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/tmp/test-codex-home",
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
            codexHomePath: "/tmp/test-codex-home",
            observedAt: Date())
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)

        let pane = ProvidersPane(settings: settings, store: store)
        await pane._test_selectCodexVisibleAccount(id: "same@example.com")

        #expect(settings.codexActiveSource == .liveSystem)
        let state = try #require(pane._test_codexAccountsSectionState())
        #expect(state.activeVisibleAccountID == "same@example.com")
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
            codexHomePath: "/tmp/test-codex-home",
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
            codexHomePath: "/tmp/test-codex-home",
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

    @Test
    func `codex accounts section preserves stock alphabetical account ordering`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-alpha-order")
        let store = Self.makeUsageStore(settings: settings)
        let managedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managedStoreURL) }

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "zeta@example.com",
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
            email: "alpha@example.com",
            codexHomePath: "/tmp/test-codex-home",
            observedAt: Date())
        settings.codexActiveSource = .managedAccount(id: managedAccountID)

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.visibleAccounts.map(\.email) == ["alpha@example.com", "zeta@example.com"])
        #expect(state.activeVisibleAccountID == "zeta@example.com")
    }

    @Test
    func `codex accounts section shows empty local profiles state for first time user`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-local-profiles-empty")
        let store = Self.makeUsageStore(settings: settings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CodexLocalProfileManager(
            authFileURL: root.appendingPathComponent("auth.json"),
            fileManager: .default,
            runtime: NoopCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        let pane = ProvidersPane(settings: settings, store: store, codexLocalProfileManager: manager)
        let state = try #require(pane._test_codexLocalProfilesSectionState())

        #expect(state.settingsProfiles.isEmpty)
        #expect(state.hasValidLiveAuth == false)
        #expect(state.showsSaveCurrentProfileButton == false)
        #expect(state.areActionsDisabled == false)
        #expect(
            state.onboardingText
                == "Sign into a Codex account in the Codex app or Codex CLI, then save it here to switch later.")
        #expect(CodexLocalProfilesSectionView.helpSymbolName == "info.circle")
        #expect(CodexLocalProfilesSectionView.helpText.contains("Codex app or Codex CLI"))
    }

    @Test
    func `codex accounts section shows save action when live auth exists and no profiles are saved`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-local-profiles-save-visible")
        let store = Self.makeUsageStore(settings: settings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try Self.writeCodexAuthFile(to: authURL, email: "live@example.com", plan: "plus", accountID: "acct-live")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: NoopCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        let pane = ProvidersPane(settings: settings, store: store, codexLocalProfileManager: manager)
        let state = try #require(pane._test_codexLocalProfilesSectionState())

        #expect(state.settingsProfiles.isEmpty)
        #expect(state.hasValidLiveAuth)
        #expect(state.showsSaveCurrentProfileButton)
        #expect(
            state.onboardingText
                == "Sign into a Codex account in the Codex app or Codex CLI, then save it here to switch later.")
        #expect(CodexLocalProfilesSectionView.helpSymbolName == "info.circle")
    }

    @Test
    func `codex accounts section hides synthetic live profile row`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-local-profiles-hide-live")
        let store = Self.makeUsageStore(settings: settings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try Self.writeCodexAuthFile(to: authURL, email: "live@example.com", plan: "plus", accountID: "acct-live")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: NoopCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        let pane = ProvidersPane(settings: settings, store: store, codexLocalProfileManager: manager)
        let state = try #require(pane._test_codexLocalProfilesSectionState())

        #expect(state.settingsProfiles.isEmpty)
    }

    @Test
    func `codex accounts section exposes active saved local profile`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-local-profiles-active")
        let store = Self.makeUsageStore(settings: settings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
        try Self.writeCodexAuthFile(to: authURL, email: "plus-b@example.com", plan: "plus", accountID: "acct-b")
        try Self.writeCodexAuthFile(
            to: profilesURL.appendingPathComponent("plus-b.json"),
            email: "plus-b@example.com",
            plan: "plus",
            accountID: "acct-b")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: NoopCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        let pane = ProvidersPane(settings: settings, store: store, codexLocalProfileManager: manager)
        let state = try #require(pane._test_codexLocalProfilesSectionState())
        let profile = try #require(state.settingsProfiles.first)

        #expect(state.settingsProfiles.count == 1)
        #expect(profile.title == "plus-b@example.com")
        #expect(profile.subtitle == "Plus")
        #expect(profile.detail == nil)
        #expect(profile.isActive)
        #expect(state.hasValidLiveAuth)
        #expect(state.showsSaveCurrentProfileButton == false)
        #expect(state.onboardingText == nil)
        #expect(CodexLocalProfilesSectionView.helpSymbolName == "info.circle")
        #expect(CodexLocalProfilesSectionView.helpText.contains("Switch Local Profile"))
    }

    @Test
    func `codex accounts section keeps save action when same email profile is not an exact match`() throws {
        let settings = Self.makeSettingsStore(
            suite: "CodexAccountsSettingsSectionTests-local-profiles-same-email-new-profile")
        let store = Self.makeUsageStore(settings: settings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
        try Self.writeCodexAuthFile(to: authURL, email: "same@example.com", plan: "plus", accountID: "acct-current")
        try Self.writeCodexAuthFile(
            to: profilesURL.appendingPathComponent("same-email.json"),
            email: "same@example.com",
            plan: "plus",
            accountID: "acct-saved")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: NoopCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        let pane = ProvidersPane(settings: settings, store: store, codexLocalProfileManager: manager)
        let state = try #require(pane._test_codexLocalProfilesSectionState())

        #expect(state.settingsProfiles.count == 1)
        #expect(state.hasValidLiveAuth)
        #expect(state.settingsProfiles.first?.isActive == false)
        #expect(state.showsSaveCurrentProfileButton)
    }

    @Test
    func `codex accounts section shows alias fallback for duplicate email and plan`() throws {
        let settings = Self.makeSettingsStore(
            suite: "CodexAccountsSettingsSectionTests-local-profiles-duplicate-display")
        let store = Self.makeUsageStore(settings: settings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
        try Self.writeCodexAuthFile(to: authURL, email: "same@example.com", plan: "plus", accountID: "acct-a")
        try Self.writeCodexAuthFile(
            to: profilesURL.appendingPathComponent("plus-a.json"),
            email: "same@example.com",
            plan: "plus",
            accountID: "acct-a")
        try Self.writeCodexAuthFile(
            to: profilesURL.appendingPathComponent("plus-b.json"),
            email: "same@example.com",
            plan: "plus",
            accountID: "acct-b")
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            runtime: NoopCodexLocalProfileRuntime(),
            appURL: root.appendingPathComponent("Codex.app"))

        let pane = ProvidersPane(settings: settings, store: store, codexLocalProfileManager: manager)
        let state = try #require(pane._test_codexLocalProfilesSectionState())

        #expect(state.settingsProfiles.count == 2)
        #expect(state.settingsProfiles.allSatisfy { $0.title == "same@example.com" })
        #expect(state.settingsProfiles.allSatisfy { $0.subtitle == "Plus" })
        #expect(state.settingsProfiles.contains { $0.detail == "Saved as plus-a" })
        #expect(state.settingsProfiles.contains { $0.detail == "Saved as plus-b" })
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

    private static func writeCodexAuthFile(to url: URL, email: String, plan: String, accountID: String) throws {
        let token = self.fakeJWT(email: email, plan: plan)
        let payload: [String: Any] = [
            "tokens": [
                "access_token": "access-\(accountID)",
                "refresh_token": "refresh-\(accountID)",
                "id_token": token,
                "account_id": accountID,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url)
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
            "https://api.openai.com/profile": ["email": email],
        ])) ?? Data()
        return "\(self.base64URL(header)).\(self.base64URL(payload))."
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class NoopCodexLocalProfileRuntime: CodexLocalProfileRuntimeProtocol {
    func runningProcesses() async throws -> CodexLocalProfileRunningProcesses {
        .init(codexAppRunning: false, cliProcesses: [])
    }

    func close(processes _: CodexLocalProfileRunningProcesses) async throws {}

    func reopenCodexApp(at _: URL) async throws {}
}

private struct TestManagedCodexHomeFactoryForSettingsSectionTests: ManagedCodexHomeProducing, Sendable {
    let root: URL
    private let nextID = UUID().uuidString

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(self.nextID, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct StubManagedCodexLoginRunnerForSettingsSectionTests: ManagedCodexLoginRunning, Sendable {
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

    func loadAccountInfo(homePath _: String) throws -> AccountInfo {
        let email = self.emails.isEmpty ? nil : self.emails.removeFirst()
        return AccountInfo(email: email, plan: "Pro")
    }
}
