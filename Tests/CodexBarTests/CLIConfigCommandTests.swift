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
    func `config set api key only accepts consumed config keys`() {
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .elevenlabs))
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .openai))
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
        #expect(help.contains("--stdin"))
        #expect(help.contains("enables that provider by default"))
    }
}
