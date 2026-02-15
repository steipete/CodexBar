import CodexBarCore
import Foundation
import Testing

@Suite
struct ConfigValidationTests {
    @Test
    func reportsUnsupportedSource() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .codex, source: .api))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.code == "unsupported_source" }))
    }

    @Test
    func reportsMissingAPIKeyWhenSourceAPI() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .zai, source: .api, apiKey: nil))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.code == "api_key_missing" }))
    }

    @Test
    func reportsInvalidRegion() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .minimax, region: "nowhere"))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.code == "invalid_region" }))
    }

    @Test
    func warnsOnUnsupportedTokenAccounts() {
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
    func allowsOllamaTokenAccounts() {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [ProviderTokenAccount(id: UUID(), label: "a", token: "t", addedAt: 0, lastUsed: nil)],
            activeIndex: 0)
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .ollama, tokenAccounts: accounts))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(!issues.contains(where: { $0.code == "token_accounts_unused" && $0.provider == .ollama }))
    }
}
