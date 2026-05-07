import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@Suite(.serialized)
@MainActor
struct TokenAccountEnvironmentPrecedenceTests {
    @Test
    func `token account environment overrides config API key in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-app")
        settings.zaiAPIToken = "config-token"
        settings.addTokenAccount(provider: .zai, label: "Account 1", token: "account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .zai,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ZaiSettingsReader.apiTokenKey] == "account-token")
        #expect(env[ZaiSettingsReader.apiTokenKey] != "config-token")
    }

    @Test
    func `deepseek token account injects environment in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-deepseek-app")
        settings.addTokenAccount(provider: .deepseek, label: "Account 1", token: "account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .deepseek,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[DeepSeekSettingsReader.apiKeyEnvironmentKey] == "account-token")
    }

    @Test
    func `token account environment overrides config API key in CLI environment builder`() throws {
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(id: .zai, apiKey: "config-token"),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Account 1",
            token: "account-token",
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)

        let env = tokenContext.environment(base: [:], provider: .zai, account: account)

        #expect(env[ZaiSettingsReader.apiTokenKey] == "account-token")
        #expect(env[ZaiSettingsReader.apiTokenKey] != "config-token")
    }

    @Test
    func `deepseek token account injects environment in CLI environment builder`() throws {
        let config = CodexBarConfig(providers: [])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Account 1",
            token: "account-token",
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)

        let env = tokenContext.environment(base: [:], provider: .deepseek, account: account)

        #expect(env[DeepSeekSettingsReader.apiKeyEnvironmentKey] == "account-token")
    }

    @Test
    func `ollama token account selection forces manual cookie source in CLI settings snapshot`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "session=account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .ollama,
                    cookieSource: .auto,
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .ollama).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .ollama, account: account))
        let ollamaSettings = try #require(snapshot.ollama)

        #expect(ollamaSettings.cookieSource == .manual)
        #expect(ollamaSettings.manualCookieHeader == "session=account-token")
    }

    @Test
    func `claude OAuth token account overrides environment in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-app")
        settings.addTokenAccount(provider: .claude, label: "OAuth", token: "Bearer sk-ant-oat-account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == "sk-ant-oat-account-token")
    }

    @Test
    func `claude OAuth token selection forces OAuth in CLI settings snapshot`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "Bearer sk-ant-oat-account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    cookieSource: .auto,
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .claude).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: account))
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.usageDataSource == .oauth)
        #expect(claudeSettings.cookieSource == .off)
        #expect(claudeSettings.manualCookieHeader == nil)
    }

    @Test
    func `claude OAuth token selection injects environment override in CLI`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "Bearer sk-ant-oat-account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(id: .claude, tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .claude).first)

        let env = tokenContext.environment(base: ["FOO": "bar"], provider: .claude, account: account)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == "sk-ant-oat-account-token")
    }

    @Test
    func `claude OAuth token selection promotes auto source mode in CLI`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Primary",
            token: "Bearer sk-ant-oat-account-token",
            addedAt: 0,
            lastUsed: nil)
        let config = CodexBarConfig(providers: [ProviderConfig(id: .claude)])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)

        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: .auto,
            provider: .claude,
            account: account)

        #expect(effectiveSourceMode == .oauth)
    }

    @Test
    func `claude session key selection stays in manual cookie mode in CLI settings snapshot`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Primary",
                    token: "sk-ant-session-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    cookieSource: .auto,
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .claude).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: account))
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.usageDataSource == .auto)
        #expect(claudeSettings.cookieSource == .manual)
        #expect(claudeSettings.manualCookieHeader == "sessionKey=sk-ant-session-token")
    }

    @Test
    func `claude config manual cookie uses shared route in CLI settings snapshot`() throws {
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    cookieHeader: "Cookie: sessionKey=sk-ant-session-token; foo=bar"),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .claude, account: nil))
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.usageDataSource == .auto)
        #expect(claudeSettings.cookieSource == .manual)
        #expect(claudeSettings.manualCookieHeader == "sessionKey=sk-ant-session-token; foo=bar")
    }

    @Test
    func `claude config manual cookie does not promote auto source mode in CLI`() throws {
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .claude,
                    cookieHeader: "Cookie: sessionKey=sk-ant-session-token"),
            ])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)

        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: .auto,
            provider: .claude,
            account: nil)

        #expect(effectiveSourceMode == .auto)
    }

    @Test
    func `apply account label in app preserves snapshot fields`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-apply-app")
        let store = Self.makeUsageStore(settings: settings)
        let snapshot = Self.makeSnapshotWithAllFields(provider: .zai)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Team Account",
            token: "account-token",
            addedAt: 0,
            lastUsed: nil)

        let labeled = store.applyAccountLabel(snapshot, provider: .zai, account: account)

        Self.expectSnapshotFieldsPreserved(before: snapshot, after: labeled)
        #expect(labeled.identity?.providerID == .zai)
        #expect(labeled.identity?.accountEmail == "Team Account")
    }

    @Test
    func `apply account label in CLI preserves snapshot fields`() throws {
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: []),
            verbose: false)
        let snapshot = Self.makeSnapshotWithAllFields(provider: .zai)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "CLI Account",
            token: "account-token",
            addedAt: 0,
            lastUsed: nil)

        let labeled = context.applyAccountLabel(snapshot, provider: .zai, account: account)

        Self.expectSnapshotFieldsPreserved(before: snapshot, after: labeled)
        #expect(labeled.identity?.providerID == .zai)
        #expect(labeled.identity?.accountEmail == "CLI Account")
    }

    @Test
    func `codex known owners match between app and CLI for live system only`() throws {
        let ambientHome = Self.makeTempCodexHome(
            email: "live@example.com",
            plan: "pro",
            accountId: "acct-live")
        defer { try? FileManager.default.removeItem(at: ambientHome) }

        let appSettings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-codex-live-only")
        appSettings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: ambientHome.path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-live"))
        defer { appSettings._test_liveSystemCodexAccount = nil }
        let appStore = Self.makeUsageStore(settings: appSettings)

        try Self.withCLIKnownOwnerFixtures(
            ambientHome: ambientHome,
            managedAccounts: [])
        {
            let rawCLIOwners = try Self.codexCLIKnownOwners()
            let cliOwners = try #require(rawCLIOwners)
            let appOwners = appStore.codexDashboardKnownOwnerCandidates()

            #expect(Self.knownOwnerMultiset(appOwners) == Self.knownOwnerMultiset(cliOwners))
        }
    }

    @Test
    func `codex known owners match between app and CLI when managed and live identities are the same`() throws {
        let ambientHome = Self.makeTempCodexHome(
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-shared")
        let managedHome = Self.makeTempCodexHome(
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-shared")
        defer {
            try? FileManager.default.removeItem(at: ambientHome)
            try? FileManager.default.removeItem(at: managedHome)
        }

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "shared@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let appSettings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-codex-same-identity")
        appSettings._test_activeManagedCodexAccount = managedAccount
        appSettings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "shared@example.com",
            codexHomePath: ambientHome.path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-shared"))
        defer {
            appSettings._test_activeManagedCodexAccount = nil
            appSettings._test_liveSystemCodexAccount = nil
        }
        let appStore = Self.makeUsageStore(settings: appSettings)

        try Self.withCLIKnownOwnerFixtures(
            ambientHome: ambientHome,
            managedAccounts: [managedAccount])
        {
            let rawCLIOwners = try Self.codexCLIKnownOwners()
            let cliOwners = try #require(rawCLIOwners)
            let appOwners = appStore.codexDashboardKnownOwnerCandidates()

            #expect(Self.knownOwnerMultiset(appOwners) == Self.knownOwnerMultiset(cliOwners))
        }
    }

    @Test
    func `codex known owners match between app and CLI when managed and live identities differ`() throws {
        let ambientHome = Self.makeTempCodexHome(
            email: "live@example.com",
            plan: "pro",
            accountId: "acct-live")
        let managedHome = Self.makeTempCodexHome(
            email: "managed@example.com",
            plan: "pro",
            accountId: "acct-managed")
        defer {
            try? FileManager.default.removeItem(at: ambientHome)
            try? FileManager.default.removeItem(at: managedHome)
        }

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let appSettings = Self
            .makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-codex-different-identities")
        appSettings._test_activeManagedCodexAccount = managedAccount
        appSettings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: ambientHome.path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-live"))
        defer {
            appSettings._test_activeManagedCodexAccount = nil
            appSettings._test_liveSystemCodexAccount = nil
        }
        let appStore = Self.makeUsageStore(settings: appSettings)

        try Self.withCLIKnownOwnerFixtures(
            ambientHome: ambientHome,
            managedAccounts: [managedAccount])
        {
            let rawCLIOwners = try Self.codexCLIKnownOwners()
            let cliOwners = try #require(rawCLIOwners)
            let appOwners = appStore.codexDashboardKnownOwnerCandidates()

            #expect(Self.knownOwnerMultiset(appOwners) == Self.knownOwnerMultiset(cliOwners))
        }
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
            settings: settings)
    }

    private static func codexCLIKnownOwners() throws -> [CodexDashboardKnownOwnerCandidate]? {
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex)]),
            verbose: false)
        return context.settingsSnapshot(for: .codex, account: nil)?.codex?.dashboardAuthorityKnownOwners
    }

    private static func knownOwnerMultiset(
        _ owners: [CodexDashboardKnownOwnerCandidate]) -> [CodexDashboardKnownOwnerCandidate: Int]
    {
        owners.reduce(into: [:]) { counts, owner in
            counts[owner, default: 0] += 1
        }
    }

    private static func makeTempCodexHome(email: String, plan: String, accountId: String) -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-known-owner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: self.fakeJWT(email: email, plan: plan, accountId: accountId),
            accountId: accountId,
            lastRefresh: Date())
        try? CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": home.path])
        return home
    }

    private static func fakeJWT(email: String, plan: String, accountId: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": plan,
                "chatgpt_account_id": accountId,
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

    private static func withCLIKnownOwnerFixtures<T>(
        ambientHome: URL,
        managedAccounts: [ManagedCodexAccount],
        operation: () throws -> T) throws -> T
    {
        let managedStoreURL = FileManagedCodexAccountStore.defaultURL()
        let fileManager = FileManager.default
        let originalManagedStoreData = try? Data(contentsOf: managedStoreURL)
        let hadOriginalManagedStore = fileManager.fileExists(atPath: managedStoreURL.path)
        let originalCodexHome = getenv("CODEX_HOME").map { String(cString: $0) }

        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: managedAccounts))
        setenv("CODEX_HOME", ambientHome.path, 1)

        defer {
            if let originalCodexHome {
                setenv("CODEX_HOME", originalCodexHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }

            if hadOriginalManagedStore, let originalManagedStoreData {
                try? fileManager.createDirectory(
                    at: managedStoreURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? originalManagedStoreData.write(to: managedStoreURL, options: [.atomic])
            } else {
                try? fileManager.removeItem(at: managedStoreURL)
            }
        }

        return try operation()
    }

    private static func makeSnapshotWithAllFields(provider: UsageProvider) -> UsageSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = Date(timeIntervalSince1970: 1_700_003_600)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 6,
            usage: 200,
            currentValue: 40,
            remaining: 160,
            percentage: 20,
            usageDetails: [ZaiUsageDetail(modelCode: "glm-4", usage: 40)],
            nextResetTime: reset)
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: nil,
            accountOrganization: "Org",
            loginMethod: "Pro")

        return UsageSnapshot(
            primary: RateWindow(usedPercent: 21, windowMinutes: 60, resetsAt: reset, resetDescription: "primary"),
            secondary: RateWindow(usedPercent: 42, windowMinutes: 1440, resetsAt: nil, resetDescription: "secondary"),
            tertiary: RateWindow(usedPercent: 7, windowMinutes: nil, resetsAt: nil, resetDescription: "tertiary"),
            providerCost: ProviderCostSnapshot(
                used: 12.5,
                limit: 25,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: reset,
                updatedAt: now),
            zaiUsage: ZaiUsageSnapshot(
                tokenLimit: tokenLimit,
                timeLimit: nil,
                planName: "Z.ai Pro",
                updatedAt: now),
            minimaxUsage: MiniMaxUsageSnapshot(
                planName: "MiniMax",
                availablePrompts: 500,
                currentPrompts: 120,
                remainingPrompts: 380,
                windowMinutes: 1440,
                usedPercent: 24,
                resetsAt: reset,
                updatedAt: now),
            openRouterUsage: OpenRouterUsageSnapshot(
                totalCredits: 50,
                totalUsage: 10,
                balance: 40,
                usedPercent: 20,
                rateLimit: nil,
                updatedAt: now),
            cursorRequests: CursorRequestUsage(used: 7, limit: 70),
            updatedAt: now,
            identity: identity)
    }

    private static func expectSnapshotFieldsPreserved(before: UsageSnapshot, after: UsageSnapshot) {
        #expect(after.primary?.usedPercent == before.primary?.usedPercent)
        #expect(after.secondary?.usedPercent == before.secondary?.usedPercent)
        #expect(after.tertiary?.usedPercent == before.tertiary?.usedPercent)
        #expect(after.providerCost?.used == before.providerCost?.used)
        #expect(after.providerCost?.limit == before.providerCost?.limit)
        #expect(after.providerCost?.currencyCode == before.providerCost?.currencyCode)
        #expect(after.zaiUsage?.planName == before.zaiUsage?.planName)
        #expect(after.zaiUsage?.tokenLimit?.usage == before.zaiUsage?.tokenLimit?.usage)
        #expect(after.minimaxUsage?.planName == before.minimaxUsage?.planName)
        #expect(after.minimaxUsage?.availablePrompts == before.minimaxUsage?.availablePrompts)
        #expect(after.openRouterUsage?.balance == before.openRouterUsage?.balance)
        #expect(after.openRouterUsage?.rateLimit?.requests == before.openRouterUsage?.rateLimit?.requests)
        #expect(after.cursorRequests?.used == before.cursorRequests?.used)
        #expect(after.cursorRequests?.limit == before.cursorRequests?.limit)
        #expect(after.updatedAt == before.updatedAt)
    }
}
