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

    @Test
    func `network proxy config encodes and decodes`() throws {
        let config = CodexBarConfig(
            providers: [],
            networkProxy: NetworkProxyConfiguration(
                enabled: true,
                scheme: .http,
                host: "proxy.example.com",
                port: "8080",
                username: "codex"))

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(decoded.networkProxy?.enabled == true)
        #expect(decoded.networkProxy?.scheme == .http)
        #expect(decoded.networkProxy?.host == "proxy.example.com")
        #expect(decoded.networkProxy?.port == "8080")
        #expect(decoded.networkProxy?.username == "codex")
    }

    @Test
    func `config store round trips network proxy`() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CodexBarConfigStore(fileURL: tempDirectory.appendingPathComponent("config.json"))
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let config = CodexBarConfig(
            providers: [],
            networkProxy: NetworkProxyConfiguration(
                enabled: true,
                scheme: .socks5,
                host: "127.0.0.1",
                port: "1080",
                username: "codex"))

        try store.save(config)
        let loaded = try store.load()

        #expect(loaded?.networkProxy?.enabled == true)
        #expect(loaded?.networkProxy?.scheme == .socks5)
        #expect(loaded?.networkProxy?.host == "127.0.0.1")
        #expect(loaded?.networkProxy?.port == "1080")
        #expect(loaded?.networkProxy?.username == "codex")
    }

    @Test
    func `network proxy validation reports missing host and invalid port`() {
        let config = CodexBarConfig(
            providers: [],
            networkProxy: NetworkProxyConfiguration(
                enabled: true,
                scheme: .http,
                host: "   ",
                port: "not-a-port",
                username: "codex"))

        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.field == "networkProxy.host" && $0.code == "proxy_host_missing" }))
        #expect(issues.contains(where: { $0.field == "networkProxy.port" && $0.code == "proxy_port_invalid" }))
    }
}
