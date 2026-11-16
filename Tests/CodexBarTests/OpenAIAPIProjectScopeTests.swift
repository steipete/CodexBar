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
        settings[providerConfig: .openai, field: .apiKey] = "config-token"
        settings[providerConfig: .openai, field: .secretWorkspace(logField: "projectID")] = "proj_config"
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

    @Test(arguments: [ProviderSourceMode.auto, .api, .web])
    func `CLI web source and explicit account selection retain distinct authority`(
        source: ProviderSourceMode) throws
    {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Work",
            token: "sk-admin-work",
            addedAt: 0,
            lastUsed: nil)
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: .openai,
            source: source,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
        for selection in [
            TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            TokenAccountCLISelection(label: "Work", index: nil, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: 0, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
        ] {
            let context = try TokenAccountCLIContext(
                selection: selection,
                config: config,
                verbose: false,
                baseEnvironment: [:])
            let configured = try context.resolvedAccounts(for: .openai)
            #expect(configured.isEmpty == (source == .web && !selection.usesOverride))
            let web = try context.resolvedAccounts(for: .openai, sourceMode: .web)
            let selected = web.first
            #expect(selected?.id == (selection.usesOverride ? account.id : nil))
            #expect(context.effectiveSourceMode(base: .web, provider: .openai, account: selected)
                == (selection.usesOverride ? .api : .web))
            let env = context.environment(base: [:], provider: .openai, account: selected)
            #expect(env[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey]
                == (selection.usesOverride ? account.token : nil))
        }
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
