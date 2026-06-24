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
    func `allows LiteLLM endpoint`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(
            id: .litellm,
            apiKey: "sk-test",
            enterpriseHost: "https://litellm.example.com"))
        let issues = CodexBarConfigValidator.validate(config)

        #expect(!issues.contains(where: { $0.provider == .litellm && $0.code == "enterprise_host_unused" }))
    }

    @Test
    func `allows OpenAI API project workspace ID`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .openai, workspaceID: "proj_abc"))
        let issues = CodexBarConfigValidator.validate(config)

        #expect(!issues.contains(where: { $0.provider == .openai && $0.code == "workspace_unused" }))
    }

    @Test
    func `warns when zai team token account is missing BigModel context`() {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Team",
                    token: "token",
                    addedAt: 0,
                    lastUsed: nil,
                    usageScope: "team",
                    organizationID: "org_abc"),
            ],
            activeIndex: 0)
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .zai, tokenAccounts: accounts))
        let issues = CodexBarConfigValidator.validate(config)

        #expect(issues.contains(where: { $0.provider == .zai && $0.code == "zai_team_context_missing" }))
    }

    @Test
    func `warns on unsupported workspace ID`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .gemini, workspaceID: "workspace-123"))
        let issues = CodexBarConfigValidator.validate(config)
        #expect(issues.contains(where: { $0.provider == .gemini && $0.code == "workspace_unused" }))
        #expect(issues.contains(where: { issue in
            issue.provider == .gemini &&
                issue.code == "workspace_unused" &&
                issue.message.contains("openai")
        }))
    }

    @Test
    func `config store default url honors environment override`() {
        let url = CodexBarConfigStore.defaultURL(environment: [
            CodexBarConfigStore.pathEnvironmentKey: "~/tmp/codexbar-test-config.json",
        ])

        #expect(url.path.hasSuffix("/tmp/codexbar-test-config.json"))
    }

    @Test
    func `config store default url honors xdg config home`() throws {
        let fileManager = FileManager.default
        let home = try Self.makeTemporaryHome()
        defer { try? fileManager.removeItem(at: home) }
        let xdgHome = home.appendingPathComponent("custom-config", isDirectory: true)

        let url = CodexBarConfigStore.defaultURL(
            home: home,
            environment: [
                CodexBarConfigStore.xdgConfigHomeEnvironmentKey: xdgHome.path,
            ],
            fileManager: fileManager)

        #expect(url == Self.configURL(in: xdgHome))
    }

    @Test
    func `config store default url ignores relative xdg config home`() throws {
        let fileManager = FileManager.default
        let home = try Self.makeTemporaryHome()
        defer { try? fileManager.removeItem(at: home) }
        let legacy = Self.legacyConfigURL(in: home)
        try Self.touch(legacy, fileManager: fileManager)

        let url = CodexBarConfigStore.defaultURL(
            home: home,
            environment: [
                CodexBarConfigStore.xdgConfigHomeEnvironmentKey: "relative-config",
            ],
            fileManager: fileManager)

        #expect(url == legacy)
    }

    @Test
    func `config store default url creates in xdg default for new installs`() throws {
        let fileManager = FileManager.default
        let home = try Self.makeTemporaryHome()
        defer { try? fileManager.removeItem(at: home) }

        let url = CodexBarConfigStore.defaultURL(home: home, environment: [:], fileManager: fileManager)

        #expect(url == Self.configURL(in: home.appendingPathComponent(".config", isDirectory: true)))
    }

    @Test
    func `config store default url keeps existing legacy config`() throws {
        let fileManager = FileManager.default
        let home = try Self.makeTemporaryHome()
        defer { try? fileManager.removeItem(at: home) }
        let legacy = Self.legacyConfigURL(in: home)
        try Self.touch(legacy, fileManager: fileManager)

        let url = CodexBarConfigStore.defaultURL(home: home, environment: [:], fileManager: fileManager)

        #expect(url == legacy)
    }

    @Test
    func `config store default url prefers existing xdg default over legacy config`() throws {
        let fileManager = FileManager.default
        let home = try Self.makeTemporaryHome()
        defer { try? fileManager.removeItem(at: home) }
        let xdgDefault = Self.configURL(in: home.appendingPathComponent(".config", isDirectory: true))
        let legacy = Self.legacyConfigURL(in: home)
        try Self.touch(legacy, fileManager: fileManager)
        try Self.touch(xdgDefault, fileManager: fileManager)

        let url = CodexBarConfigStore.defaultURL(home: home, environment: [:], fileManager: fileManager)

        #expect(url == xdgDefault)
    }

    private static func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func touch(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private static func configURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent("codexbar", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static func legacyConfigURL(in home: URL) -> URL {
        home
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}
