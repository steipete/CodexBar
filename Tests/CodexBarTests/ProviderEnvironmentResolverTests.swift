import CodexBarCore
import Foundation
import Testing

struct ProviderEnvironmentResolverTests {
    @Test
    func `selected API account overrides saved and ambient credentials`() {
        let account = Self.account(token: "account-token")
        let environment = ProviderEnvironmentResolver.resolve(
            base: [ZaiSettingsReader.apiTokenKey: "ambient-token"],
            provider: .zai,
            config: ProviderConfig(id: .zai, apiKey: "saved-token"),
            selectedAccount: account)

        #expect(environment[ZaiSettingsReader.apiTokenKey] == "account-token")
    }

    @Test
    func `NeuralWatt selected API account overrides saved and ambient credentials`() {
        let account = Self.account(token: "sk-neuralwatt-account")
        let environment = ProviderEnvironmentResolver.resolve(
            base: [NeuralWattSettingsReader.apiKeyEnvironmentKey: "ambient-token"],
            provider: .neuralwatt,
            config: ProviderConfig(id: .neuralwatt, apiKey: "saved-token"),
            selectedAccount: account)

        #expect(environment[NeuralWattSettingsReader.apiKeyEnvironmentKey] == "sk-neuralwatt-account")
    }

    @Test
    func `OpenAI account removes project scoping from saved config`() {
        let account = Self.account(token: "sk-admin-account")
        let environment = ProviderEnvironmentResolver.resolve(
            base: [
                OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey: "ambient-token",
                OpenAIAPISettingsReader.projectIDEnvironmentKey: "ambient-project",
            ],
            provider: .openai,
            config: ProviderConfig(
                id: .openai,
                apiKey: "saved-token",
                workspaceID: "saved-project"),
            selectedAccount: account)

        #expect(environment[OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey] == "sk-admin-account")
        #expect(environment[OpenAIAPISettingsReader.projectIDEnvironmentKey] == nil)
    }

    @Test
    func `Claude session account removes API and OAuth credentials`() {
        let environment = ProviderEnvironmentResolver.resolve(
            base: [
                ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "ambient-admin",
                ClaudeOAuthCredentialsStore.environmentTokenKey: "ambient-oauth",
            ],
            provider: .claude,
            config: ProviderConfig(id: .claude, apiKey: "saved-admin"),
            selectedAccount: Self.account(token: "sk-ant-session-account"))

        for key in ClaudeAdminAPISettingsReader.apiKeyEnvironmentKeys {
            #expect(environment[key] == nil)
        }
        #expect(environment[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
    }

    @Test
    func `Claude OAuth account replaces incompatible credentials`() {
        let environment = ProviderEnvironmentResolver.resolve(
            base: [
                ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "ambient-admin",
                ClaudeOAuthCredentialsStore.environmentTokenKey: "ambient-oauth",
            ],
            provider: .claude,
            config: ProviderConfig(id: .claude, apiKey: "saved-admin"),
            selectedAccount: Self.account(token: "Bearer sk-ant-oat-account"))

        for key in ClaudeAdminAPISettingsReader.apiKeyEnvironmentKeys {
            #expect(environment[key] == nil)
        }
        #expect(environment[ClaudeOAuthCredentialsStore.environmentTokenKey] == "sk-ant-oat-account")
    }

    @Test
    func `cookie account leaves unrelated provider environment intact`() {
        let base = ["FOO": "bar"]
        let environment = ProviderEnvironmentResolver.resolve(
            base: base,
            provider: .cursor,
            config: ProviderConfig(id: .cursor),
            selectedAccount: Self.account(token: "session=account"))

        #expect(environment == base)
    }

    private static func account(token: String) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(),
            label: "Test",
            token: token,
            addedAt: 0,
            lastUsed: nil)
    }
}
