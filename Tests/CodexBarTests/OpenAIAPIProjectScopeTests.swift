import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct OpenAIAPIProjectScopeTests {
    @Test
    @MainActor
    func `token account strips configured project in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "OpenAIAPIProjectScopeTests-app")
        settings.openAIAPIKey = "config-token"
        settings.openAIAPIProjectID = "proj_config"
        settings.addTokenAccount(provider: .openai, label: "Configured account", token: "first-account-token")
        settings.addTokenAccount(provider: .openai, label: "Selected account", token: "selected-account-token")
        let selectedAccount = settings.tokenAccounts(for: .openai)[1]

        let env = ProviderRegistry.makeEnvironment(
            base: [OpenAIAPISettingsReader.projectIDEnvironmentKey: "proj_env"],
            provider: .openai,
            settings: settings,
            tokenOverride: TokenAccountOverride(provider: .openai, account: selectedAccount))

        #expect(env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] == "selected-account-token")
        #expect(env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] != "config-token")
        #expect(env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] != "first-account-token")
        #expect(env[OpenAIAPISettingsReader.projectIDEnvironmentKey] == nil)
    }

    @Test
    func `token account strips configured project in CLI environment builder`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Project account",
            token: "account-token",
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)
        let accounts = ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0)
        let config = CodexBarConfig(
            providers: [
                ProviderConfig(
                    id: .openai,
                    apiKey: "config-token",
                    workspaceID: "proj_config",
                    tokenAccounts: accounts),
            ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)

        let env = tokenContext.environment(
            base: [OpenAIAPISettingsReader.projectIDEnvironmentKey: "proj_env"],
            provider: .openai,
            account: account)

        #expect(env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] == "account-token")
        #expect(env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] != "config-token")
        #expect(env[OpenAIAPISettingsReader.projectIDEnvironmentKey] == nil)
    }

    @Test
    @MainActor
    func `configured app project scopes admin usage strategy`() async throws {
        let settings = Self.makeSettingsStore(suite: "OpenAIAPIProjectScopeTests-configured-project")
        settings.openAIAPIKey = "config-token"
        settings.openAIAPIProjectID = "proj_config"
        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .openai,
            settings: settings,
            tokenOverride: nil)
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, historyDays in
                #expect(credential.apiKey == "config-token")
                #expect(credential.projectID == "proj_config")
                #expect(historyDays == 30)
                return OpenAIAPIUsageSnapshot(
                    daily: [],
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    projectID: credential.projectID)
            },
            balanceFetcher: { _ in
                Issue.record("Configured project usage should not fetch legacy organization balance.")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(Self.makeContext(env: env))

        #expect(result.sourceLabel == "admin-api:project")
        #expect(result.usage.identity?.loginMethod == "Admin API: proj_config")
        #expect(result.usage.identity?.accountOrganization == "Project: proj_config")
    }

    @Test
    func `legacy API key environment can scope admin usage by project`() async throws {
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, historyDays in
                #expect(credential.apiKey == "sk-admin-legacy")
                #expect(credential.projectID == "proj_legacy")
                #expect(historyDays == 30)
                return OpenAIAPIUsageSnapshot(
                    daily: [],
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    projectID: credential.projectID)
            },
            balanceFetcher: { _ in
                Issue.record("Legacy OPENAI_API_KEY project usage should not fetch unscoped balance.")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(Self.makeContext(
            env: [
                OpenAIAPISettingsReader.apiKeyEnvironmentKey: "sk-admin-legacy",
                OpenAIAPISettingsReader.projectIDEnvironmentKey: "proj_legacy",
            ]))

        #expect(result.sourceLabel == "admin-api:project")
        #expect(result.usage.identity?.loginMethod == "Admin API: proj_legacy")
        #expect(result.usage.identity?.accountOrganization == "Project: proj_legacy")
    }

    @Test
    func `project filtered admin usage does not fall back on service failure`() async {
        let usageFailure = OpenAIAPIUsageError.apiError(endpoint: "costs", statusCode: 500)
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, historyDays in
                #expect(credential.apiKey == "sk-test")
                #expect(credential.projectID == "proj_abc")
                #expect(historyDays == 30)
                throw usageFailure
            },
            balanceFetcher: { _ in
                Issue.record("Project-filtered usage must not fall back to organization balance.")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        do {
            _ = try await strategy.fetch(Self.makeContext(
                env: [
                    OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-test",
                    OpenAIAPISettingsReader.projectIDEnvironmentKey: "proj_abc",
                ]))
            Issue.record("Expected project-filtered admin usage failure.")
        } catch let error as OpenAIAPIUsageError {
            #expect(error == usageFailure)
        } catch {
            Issue.record("Expected OpenAIAPIUsageError, got \(error)")
        }
    }

    @Test
    func `project filtered admin usage does not fall back on credential rejection`() async {
        let usageFailure = OpenAIAPIUsageError.apiError(endpoint: "costs", statusCode: 403)
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, historyDays in
                #expect(credential.apiKey == "sk-test")
                #expect(credential.projectID == "proj_abc")
                #expect(historyDays == 30)
                throw usageFailure
            },
            balanceFetcher: { _ in
                Issue.record("Project-filtered usage must fail closed instead of showing unscoped balance.")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        do {
            _ = try await strategy.fetch(Self.makeContext(
                env: [
                    OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-test",
                    OpenAIAPISettingsReader.projectIDEnvironmentKey: "proj_abc",
                ]))
            Issue.record("Expected project-filtered admin credential failure.")
        } catch let error as OpenAIAPIUsageError {
            #expect(error == usageFailure)
        } catch {
            Issue.record("Expected OpenAIAPIUsageError, got \(error)")
        }
    }

    @Test
    func `project filtered admin usage reports project source label`() async throws {
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, _ in
                #expect(credential.apiKey == "sk-test")
                #expect(credential.projectID == "proj_abc")
                return OpenAIAPIUsageSnapshot(
                    daily: [],
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    projectID: credential.projectID)
            },
            balanceFetcher: { _ in
                Issue.record("Project-filtered usage should not fetch legacy balance after admin usage succeeds.")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(Self.makeContext(
            env: [
                OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-test",
                OpenAIAPISettingsReader.projectIDEnvironmentKey: "proj_abc",
            ]))

        #expect(result.sourceLabel == "admin-api:project")
        #expect(result.usage.identity?.loginMethod == "Admin API: proj_abc")
        #expect(result.usage.identity?.accountOrganization == "Project: proj_abc")
    }

    @Test
    func `project scope follows final environment even when selected account flag is present`() async throws {
        let accountID = UUID()
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { credential, historyDays in
                #expect(credential.apiKey == "sk-test")
                #expect(credential.projectID == "proj_env")
                #expect(historyDays == 30)
                return OpenAIAPIUsageSnapshot(
                    daily: [],
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    projectID: credential.projectID)
            },
            balanceFetcher: { _ in
                Issue.record("Final project-scoped environments should not fetch legacy balance.")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(Self.makeContext(
            env: [
                OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-test",
                OpenAIAPISettingsReader.projectIDEnvironmentKey: "proj_env",
            ],
            selectedTokenAccountID: accountID))

        #expect(result.sourceLabel == "admin-api:project")
        #expect(result.usage.identity?.loginMethod == "Admin API: proj_env")
        #expect(result.usage.identity?.accountOrganization == "Project: proj_env")
    }

    private static func makeContext(
        env: [String: String],
        selectedTokenAccountID: UUID? = nil,
        historyDays: Int = 30) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: selectedTokenAccountID,
            costUsageHistoryDays: historyDays)
    }

    @MainActor
    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
