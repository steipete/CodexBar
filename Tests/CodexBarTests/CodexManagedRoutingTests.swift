import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct CodexManagedRoutingTests {
    @Test
    func `provider registry injects managed home when active source is managed account`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-registry")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/codex-managed-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
        }

        let codexEnv = ProviderRegistry.makeEnvironment(
            base: ["PATH": "/usr/bin"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)
        let claudeEnv = ProviderRegistry.makeEnvironment(
            base: ["PATH": "/usr/bin"],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(codexEnv["CODEX_HOME"] == managedAccount.managedHomePath)
        #expect(claudeEnv["CODEX_HOME"] == nil)
    }

    @Test
    func `provider registry preserves ambient live system home when active source is live system`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-live-system-routing")
        let managedHomePath = "/tmp/managed-remote-home"
        let liveHomePath = "/tmp/system-remote-home"
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHomePath,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveSystemAccount = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: liveHomePath,
            observedAt: Date())

        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveSystemAccount
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": liveHomePath],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(env["CODEX_HOME"] == liveHomePath)
        #expect(env["CODEX_HOME"] != managedHomePath)
    }

    @Test
    func `provider registry keeps managed home when live account differs`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-active-vs-live")
        let managedHomePath = "/tmp/managed-remote-home"
        let liveHomePath = "/tmp/system-remote-home"
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHomePath,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveSystemAccount = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: liveHomePath,
            observedAt: Date())

        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveSystemAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": liveHomePath],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(env["CODEX_HOME"] == managedHomePath)
        #expect(env["CODEX_HOME"] != liveHomePath)
    }

    @Test
    func `provider registry prefers live system routing when managed and live share email`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-same-email-prefers-live")
        let managedHomePath = "/tmp/managed-remote-home"
        let liveHomePath = "/tmp/system-remote-home"
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "person@example.com",
            managedHomePath: managedHomePath,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveSystemAccount = ObservedSystemCodexAccount(
            email: "PERSON@example.com",
            codexHomePath: liveHomePath,
            observedAt: Date())

        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveSystemAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": liveHomePath],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(settings.codexResolvedActiveSource == .liveSystem)
        #expect(env["CODEX_HOME"] == liveHomePath)
        #expect(env["CODEX_HOME"] != managedHomePath)
    }

    @Test
    func `provider registry keeps managed routing when same email rows differ by identity strength`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-same-email-split-by-identity")
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let liveHomePath = "/tmp/system-remote-home"
        defer { try? FileManager.default.removeItem(at: managedHome) }

        try self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "person@example.com",
            plan: "pro",
            accountId: "account-managed")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "person@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveSystemAccount = ObservedSystemCodexAccount(
            email: "PERSON@example.com",
            codexHomePath: liveHomePath,
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "person@example.com"))

        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveSystemAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": liveHomePath],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(settings.codexResolvedActiveSource == .managedAccount(id: managedAccount.id))
        #expect(env["CODEX_HOME"] == managedHome.path)
        #expect(env["CODEX_HOME"] != liveHomePath)
    }

    @Test
    func `persisted managed source corrects to live system when selected row collapses with live account`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-same-email-persist-correction")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "person@example.com",
            managedHomePath: "/tmp/managed-remote-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveSystemAccount = ObservedSystemCodexAccount(
            email: "PERSON@example.com",
            codexHomePath: "/tmp/system-remote-home",
            observedAt: Date())

        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveSystemAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let corrected = settings.persistResolvedCodexActiveSourceCorrectionIfNeeded()

        #expect(corrected)
        #expect(settings.codexActiveSource == .liveSystem)
    }

    @Test
    func `codex provider refresh persists live correction for stale managed source`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-provider-refresh-persists-correction")
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ambientHome) }

        try? self.writeCodexAuthFile(homeURL: ambientHome, email: "live@example.com", plan: "pro")
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: ambientHome.path,
            observedAt: Date())
        settings.codexActiveSource = .managedAccount(id: UUID())
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": ambientHome.path]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(settings.codexActiveSource != .liveSystem)

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(settings.codexActiveSource == .liveSystem)
    }

    @Test
    func `full refresh persists live correction for stale managed source`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-full-refresh-persists-correction")
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ambientHome) }

        try? self.writeCodexAuthFile(homeURL: ambientHome, email: "live@example.com", plan: "pro")
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: ambientHome.path,
            observedAt: Date())
        settings.codexActiveSource = .managedAccount(id: UUID())
        defer { settings._test_liveSystemCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": ambientHome.path]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(settings.codexActiveSource != .liveSystem)

        await store.refresh()

        #expect(settings.codexActiveSource == .liveSystem)
    }

    @Test
    func `provider registry fails closed when managed account store is unreadable`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-unreadable-store")
        settings._test_unreadableManagedCodexAccountStore = true
        settings.codexActiveSource = .managedAccount(id: UUID())
        defer { settings._test_unreadableManagedCodexAccountStore = false }

        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": "/Users/example/.codex"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(env["CODEX_HOME"] != nil)
        #expect(env["CODEX_HOME"] != "/Users/example/.codex")
        #expect(env["CODEX_HOME"]?.isEmpty == false)
    }

    @Test
    func `provider registry bootstraps live system source instead of inferring managed fallback`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-unreadable-legacy-source")
        settings._test_unreadableManagedCodexAccountStore = true
        defer { settings._test_unreadableManagedCodexAccountStore = false }

        let ambientHome = "/Users/example/.codex"
        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": ambientHome],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)
        let snapshot = settings.codexSettingsSnapshot(tokenOverride: nil)

        #expect(env["CODEX_HOME"] == ambientHome)
        #expect(settings.providerConfig(for: .codex)?.codexActiveSource == nil)
        #expect(snapshot.managedAccountStoreUnreadable == false)
        #expect(snapshot.managedAccountTargetUnavailable == false)
    }

    @Test
    func `provider registry fails closed when selected managed source is missing from readable store`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-missing-managed-source")
        let storedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "stored@example.com",
            managedHomePath: "/tmp/stored-managed-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-routing-\(UUID().uuidString).json")
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [storedAccount]))
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: UUID())
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": "/Users/example/.codex"]
        defer {
            settings._test_codexReconciliationEnvironment = nil
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        let ambientHome = "/Users/example/.codex"
        let expectedFailClosedPath = ManagedCodexHomeFactory.defaultRootURL()
            .appendingPathComponent("managed-store-unreadable", isDirectory: true)
            .path
        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": ambientHome],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(env["CODEX_HOME"] == expectedFailClosedPath)
        #expect(env["CODEX_HOME"] != ambientHome)
        #expect(env["CODEX_HOME"] != storedAccount.managedHomePath)
    }

    @Test
    func `codex settings snapshot marks missing selected managed source as unavailable`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-missing-managed-snapshot")
        let storedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "stored@example.com",
            managedHomePath: "/tmp/stored-managed-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-snapshot-\(UUID().uuidString).json")
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [storedAccount]))
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: UUID())
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        let snapshot = settings.codexSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.managedAccountStoreUnreadable == false)
        #expect(snapshot.managedAccountTargetUnavailable == true)
    }

    @Test
    func `codex settings snapshot ignores unreadable added account store when live system is active`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-live-system-snapshot")
        settings._test_unreadableManagedCodexAccountStore = true
        settings.codexActiveSource = .liveSystem
        defer { settings._test_unreadableManagedCodexAccountStore = false }

        let snapshot = settings.codexSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.managedAccountStoreUnreadable == false)
        #expect(snapshot.managedAccountTargetUnavailable == false)
    }

    @Test
    func `codex settings snapshot keeps unreadable managed store fail closed when live account is present`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-unreadable-store-live-present")
        settings._test_unreadableManagedCodexAccountStore = true
        settings.codexActiveSource = .managedAccount(id: UUID())
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/example/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-live"))
        defer {
            settings._test_unreadableManagedCodexAccountStore = false
            settings._test_liveSystemCodexAccount = nil
        }

        let snapshot = settings.codexSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.managedAccountStoreUnreadable == true)
        #expect(snapshot.managedAccountTargetUnavailable == false)
    }

    @Test
    func `codex settings snapshot keeps missing managed target fail closed when live account is present`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-missing-managed-live-present")
        let storedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "stored@example.com",
            managedHomePath: "/tmp/stored-managed-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-live-present-\(UUID().uuidString).json")
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [storedAccount]))
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: UUID())
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/example/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-live"))
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        let snapshot = settings.codexSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.managedAccountStoreUnreadable == false)
        #expect(snapshot.managedAccountTargetUnavailable == true)
    }

    @Test
    func `provider registry ignores debug managed home override without explicit managed source`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-debug-home-override")
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        settings._test_activeManagedCodexRemoteHomePath = managedHome.path
        defer { settings._test_activeManagedCodexRemoteHomePath = nil }
        try self.writeCodexAuthFile(homeURL: managedHome, email: "managed@example.com", plan: "pro")

        let ambientHome = "/Users/example/.codex"
        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": ambientHome],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(env["CODEX_HOME"] == ambientHome)
        #expect(settings.providerConfig(for: .codex)?.codexActiveSource == nil)
    }

    @Test
    func `provider registry builds codex fetcher scoped to managed home`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-registry-fetcher")
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        settings._test_activeManagedCodexRemoteHomePath = managedHome.path
        settings.codexActiveSource = .managedAccount(id: UUID())
        try self.writeCodexAuthFile(homeURL: managedHome, email: "managed@example.com", plan: "pro")
        defer {
            settings._test_activeManagedCodexRemoteHomePath = nil
        }

        let browserDetection = BrowserDetection(cacheTTL: 0)
        let specs = ProviderRegistry.shared.specs(
            settings: settings,
            metadata: ProviderDescriptorRegistry.metadata,
            codexFetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        let context = try #require(specs[.codex]?.makeFetchContext())

        let account = context.fetcher.loadAccountInfo()
        #expect(account.email == "managed@example.com")
        #expect(account.plan == "pro")
    }

    @Test
    func `usage store builds codex token account fetcher scoped to managed home`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-usage-store")
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        settings._test_activeManagedCodexRemoteHomePath = managedHome.path
        settings.codexActiveSource = .managedAccount(id: UUID())
        try self.writeCodexAuthFile(homeURL: managedHome, email: "token@example.com", plan: "team")
        defer {
            settings._test_activeManagedCodexRemoteHomePath = nil
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let context = store.makeFetchContext(provider: .codex, override: nil)

        let account = context.fetcher.loadAccountInfo()
        #expect(account.email == "token@example.com")
        #expect(account.plan == "team")
    }

    @Test
    func `usage store builds codex credits fetcher scoped to managed home`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-credits-fetcher")
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        settings._test_activeManagedCodexRemoteHomePath = managedHome.path
        settings.codexActiveSource = .managedAccount(id: UUID())
        try self.writeCodexAuthFile(homeURL: managedHome, email: "credits@example.com", plan: "enterprise")
        defer {
            settings._test_activeManagedCodexRemoteHomePath = nil
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let account = store.codexCreditsFetcher().loadAccountInfo()

        #expect(account.email == "credits@example.com")
        #expect(account.plan == "enterprise")
    }

    @Test
    func `default managed codex identity reader preserves provider account from scoped auth`() throws {
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed@example.com",
            plan: "pro",
            accountId: "managed-account-id")

        let reader = DefaultManagedCodexIdentityReader()
        let account = try reader.loadAccountIdentity(homePath: managedHome.path)

        #expect(account.email == "managed@example.com")
        #expect(account.plan == "pro")
        #expect(account.identity == .providerAccount(id: "managed-account-id"))
    }

    @Test
    func `codex O auth strategy availability reads auth from context env`() async throws {
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": managedHome.path])

        let strategy = CodexOAuthFetchStrategy()
        let available = await strategy.isAvailable(self.makeContext(env: ["CODEX_HOME": managedHome.path]))

        #expect(available)
    }

    @Test
    func `codex O auth credentials store loads and saves using explicit env`() throws {
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "account-id",
            lastRefresh: Date())
        let env = ["CODEX_HOME": managedHome.path]

        try CodexOAuthCredentialsStore.save(credentials, env: env)

        let authURL = CodexOAuthCredentialsStore._authFileURLForTesting(env: env)
        #expect(authURL.path == managedHome.appendingPathComponent("auth.json").path)

        let loaded = try CodexOAuthCredentialsStore.load(env: env)
        #expect(loaded.accessToken == credentials.accessToken)
        #expect(loaded.refreshToken == credentials.refreshToken)
        #expect(loaded.idToken == credentials.idToken)
        #expect(loaded.accountId == credentials.accountId)
    }

    @Test
    func `codex no data message uses explicit environment home`() {
        let env = ["CODEX_HOME": "/tmp/managed-codex-home"]

        let message = CodexProviderDescriptor._noDataMessageForTesting(env: env)

        #expect(message.contains("/tmp/managed-codex-home/sessions"))
        #expect(message.contains("/tmp/managed-codex-home/archived_sessions"))
    }

    private func makeContext(env: [String: String]) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: InMemoryZaiTokenStore(),
            syntheticTokenStore: InMemorySyntheticTokenStore(),
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

    private func writeCodexAuthFile(
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
        let auth = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: auth)
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

private final class InMemoryZaiTokenStore: ZaiTokenStoring, @unchecked Sendable {
    func loadToken() throws -> String? {
        nil
    }

    func storeToken(_: String?) throws {}
}

private final class InMemorySyntheticTokenStore: SyntheticTokenStoring, @unchecked Sendable {
    func loadToken() throws -> String? {
        nil
    }

    func storeToken(_: String?) throws {}
}
