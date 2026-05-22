import CodexBarCore
import Foundation
import Testing

struct ConfigValidationTests {
    @Test
    func `reports unsupported source`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .codex, source: .api))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.code == "unsupported_source" }))
    }

    @Test
    func `reports missing API key when source API`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .zai, source: .api, apiKey: nil))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.code == "api_key_missing" }))
    }

    @Test
    func `reports invalid region`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .minimax, region: "nowhere"))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.code == "invalid_region" }))
    }

    @Test
    func `warns on unsupported token accounts`() {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [ProviderTokenAccount(id: UUID(), label: "a", token: "t", addedAt: 0, lastUsed: nil)],
            activeIndex: 0)
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .gemini, tokenAccounts: accounts))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.code == "token_accounts_unused" }))
    }

    @Test
    func `allows ollama token accounts`() {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [ProviderTokenAccount(id: UUID(), label: "a", token: "t", addedAt: 0, lastUsed: nil)],
            activeIndex: 0)
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .ollama, tokenAccounts: accounts))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(!issues.contains(where: { $0.code == "token_accounts_unused" && $0.provider == .ollama }))
    }

    @Test
    func `accepts kilo extras config field`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .kilo, extrasEnabled: true))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(!issues.contains(where: { $0.provider == .kilo && $0.field == "extrasEnabled" }))
    }

    @Test
    func `allows deepgram project workspace ID`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .deepgram, workspaceID: "project-123"))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(!issues.contains(where: { $0.provider == .deepgram && $0.code == "workspace_unused" }))
    }

    @Test
    func `allows Azure OpenAI endpoint and deployment fields`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(
            id: .azureopenai,
            workspaceID: "chat-prod",
            enterpriseHost: "https://example-resource.openai.azure.com"))
        let issues = CodexBarConfigValidator.validate(config)

        #expect(!issues.contains(where: { $0.provider == .azureopenai && $0.code == "workspace_unused" }))
        #expect(!issues.contains(where: { $0.provider == .azureopenai && $0.code == "enterprise_host_unused" }))
    }

    @Test
    func `warns on unsupported workspace ID`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .gemini, workspaceID: "workspace-123"))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.provider == .gemini && $0.code == "workspace_unused" }))
    }

    @Test
    func `config store default url honors environment override`() {
        let url = CodexBarConfigStore.defaultURL(environment: [
            CodexBarConfigStore.pathEnvironmentKey: "~/tmp/codexbar-test-config.json",
        ])

        #expect(url.path.hasSuffix("/tmp/codexbar-test-config.json"))
    }
}
