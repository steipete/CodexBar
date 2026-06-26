import CodexBarCore
import Commander
import Testing
@testable import CodexBarCLI

struct CLIConfigCommandTests {
    @Test
    func `config set api key parses provider stdin and no enable flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configSetAPIKeySignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "elevenlabs",
            "--stdin",
            "--no-enable",
            "--json",
        ])

        #expect(parsed.options["provider"] == ["elevenlabs"])
        #expect(parsed.flags.contains("stdin"))
        #expect(parsed.flags.contains("noEnable"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `config set api key parses zai team account options`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configSetAPIKeySignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "zai",
            "--stdin",
            "--label", "Team",
            "--usage-scope", "team",
            "--organization-id", "org-team",
            "--workspace-id", "proj-team",
        ])

        #expect(parsed.options["provider"] == ["zai"])
        #expect(parsed.options["label"] == ["Team"])
        #expect(parsed.options["usageScope"] == ["team"])
        #expect(parsed.options["organizationId"] == ["org-team"])
        #expect(parsed.options["workspaceId"] == ["proj-team"])
    }

    @Test
    func `config set api key stores key and enables provider`() {
        let config = CodexBarConfig.makeDefault()
        let updated = CodexBarCLI.configSettingAPIKey(
            config,
            provider: .elevenlabs,
            apiKey: "xi-test-token",
            enableProvider: true)
        let provider = updated.providerConfig(for: .elevenlabs)

        #expect(provider?.sanitizedAPIKey == "xi-test-token")
        #expect(provider?.enabled == true)
    }

    @Test
    func `config set api key stores zai team token account`() throws {
        let config = CodexBarConfig.makeDefault()
        let options = try CodexBarCLI.resolveConfigAPIKeyAccountOptions(
            provider: .zai,
            label: "Team",
            usageScope: "team",
            organizationID: " org-team ",
            workspaceID: " proj-team ")
        let updated = CodexBarCLI.configSettingAPIKey(
            config,
            provider: .zai,
            apiKey: "z-token",
            enableProvider: true,
            accountOptions: options)
        let provider = try #require(updated.providerConfig(for: .zai))
        let account = try #require(provider.tokenAccounts?.accounts.first)

        #expect(provider.enabled == true)
        #expect(provider.apiKey == nil)
        #expect(provider.tokenAccounts?.activeIndex == 0)
        #expect(account.label == "Team")
        #expect(account.token == "z-token")
        #expect(account.usageScope == "team")
        #expect(account.organizationID == "org-team")
        #expect(account.workspaceID == "proj-team")
    }

    @Test
    func `config set api key rejects incomplete zai team account options`() {
        #expect(throws: CLIArgumentError.self) {
            _ = try CodexBarCLI.resolveConfigAPIKeyAccountOptions(
                provider: .zai,
                label: "Team",
                usageScope: "team",
                organizationID: "org-team",
                workspaceID: nil)
        }
    }

    @Test
    func `config provider toggle parses provider and json flags`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configProviderToggleSignatureForTesting())
        let parsed = try parser.parse(arguments: [
            "--provider", "grok",
            "--json",
            "--pretty",
        ])

        #expect(parsed.options["provider"] == ["grok"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
        #expect(parsed.flags.contains("pretty"))
    }

    @Test
    func `config provider toggle enables and disables provider`() {
        let config = CodexBarConfig.makeDefault()
        let enabled = CodexBarCLI.configSettingProviderEnabled(config, provider: .grok, enabled: true)
        let disabled = CodexBarCLI.configSettingProviderEnabled(enabled, provider: .grok, enabled: false)

        #expect(enabled.providerConfig(for: .grok)?.enabled == true)
        #expect(disabled.providerConfig(for: .grok)?.enabled == false)
    }

    @Test
    func `config provider status includes effective default`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .grok, enabled: true),
            ProviderConfig(id: .cursor, enabled: false),
        ])
        let statuses = CodexBarCLI.configProviderStatuses(config)
        let grok = try #require(statuses.first { $0.provider == "grok" })
        let cursor = try #require(statuses.first { $0.provider == "cursor" })

        #expect(grok.enabled)
        #expect(!cursor.enabled)
        #expect(statuses.count == UsageProvider.allCases.count)
    }

    @Test
    func `config set api key only accepts consumed config keys`() {
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .elevenlabs))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .groq))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .llmproxy))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .openai))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .amp))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .kimi))
        #expect(!ProviderConfigEnvironment.supportsAPIKeyOverride(for: .bedrock))
        #expect(!ProviderConfigEnvironment.supportsAPIKeyOverride(for: .deepseek))
        #expect(!ProviderConfigEnvironment.supportsAPIKeyOverride(for: .cursor))
    }

    @Test
    func `config set api key preserves disabled provider when requested`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .elevenlabs, enabled: false))

        let updated = CodexBarCLI.configSettingAPIKey(
            config,
            provider: .elevenlabs,
            apiKey: "xi-test-token",
            enableProvider: false)
        let provider = updated.providerConfig(for: .elevenlabs)

        #expect(provider?.sanitizedAPIKey == "xi-test-token")
        #expect(provider?.enabled == false)
    }

    @Test
    func `config set api key rejects ambiguous input`() {
        #expect(throws: CLIArgumentError.self) {
            try CodexBarCLI.resolveConfigAPIKeyInput(apiKey: "xi-test-token", readFromStdin: true)
        }
    }

    @Test
    func `config help documents set api key`() {
        let help = CodexBarCLI.configHelp(version: "0.0.0")

        #expect(help.contains("config set-api-key --provider <name>"))
        #expect(help.contains("config providers"))
        #expect(help.contains("config enable --provider <name>"))
        #expect(help.contains("config disable --provider <name>"))
        #expect(help.contains("--stdin"))
        #expect(help.contains("--usage-scope team"))
        #expect(help.contains("enables that provider by default"))
    }
}
