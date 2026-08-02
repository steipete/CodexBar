import CodexBarCore
import Commander
import Foundation
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
    func `config set api key for codex provider hints openai provider`() {
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .codex) == false)
        let codexMsg = CodexBarCLI.unsupportedAPIKeyErrorMessage(for: .codex, rawProvider: "codex")
        #expect(codexMsg ==
            "codex does not support config API keys. For OpenAI Platform API keys, use '--provider openai'.")

        let claudeMsg = CodexBarCLI.unsupportedAPIKeyErrorMessage(for: .claude, rawProvider: "claude")
        #expect(claudeMsg == "claude does not support config API keys.")
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
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .factory))
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
        #expect(help.contains("--show-secrets"))
    }

    @Test
    func `config dump parses show-secrets flag`() throws {
        let parser = CommandParser(signature: CodexBarCLI._configDumpSignatureForTesting())
        let parsed = try parser.parse(arguments: ["--show-secrets", "--pretty"])

        #expect(parsed.flags.contains("showSecrets"))
        #expect(parsed.flags.contains("pretty"))
    }

    @Test
    func `config dump redacts credentials by default`() {
        let rawAccount = ProviderTokenAccount(
            id: UUID(),
            label: "Team",
            token: "cb_test_token_123",
            addedAt: 1000,
            lastUsed: nil,
            usageScope: "team",
            organizationID: "org-1",
            workspaceID: "proj-1")
        let provider = ProviderConfig(
            id: .zai,
            apiKey: "cb_test_api_key_456",
            secretKey: "cb_test_secret_key_789",
            cookieHeader: "cb_test_cookie_abc",
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [rawAccount], activeIndex: 0))
        let config = CodexBarConfig(providers: [provider])

        let redacted = config.sanitizedForDump(showSecrets: false)
        let redactedProvider = redacted.providerConfig(for: .zai)

        #expect(redactedProvider?.apiKey == "[REDACTED]")
        #expect(redactedProvider?.secretKey == "[REDACTED]")
        #expect(redactedProvider?.cookieHeader == "[REDACTED]")
        #expect(redactedProvider?.tokenAccounts?.accounts.first?.token == "[REDACTED]")
    }

    @Test
    func `config dump reveals credentials when show-secrets is true`() {
        let rawAccount = ProviderTokenAccount(
            id: UUID(),
            label: "Team",
            token: "cb_test_token_123",
            addedAt: 1000,
            lastUsed: nil,
            usageScope: "team",
            organizationID: "org-1",
            workspaceID: "proj-1")
        let provider = ProviderConfig(
            id: .zai,
            apiKey: "cb_test_api_key_456",
            secretKey: "cb_test_secret_key_789",
            cookieHeader: "cb_test_cookie_abc",
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [rawAccount], activeIndex: 0))
        let config = CodexBarConfig(providers: [provider])

        let unredacted = config.sanitizedForDump(showSecrets: true)
        let unredactedProvider = unredacted.providerConfig(for: .zai)

        #expect(unredactedProvider?.apiKey == "cb_test_api_key_456")
        #expect(unredactedProvider?.secretKey == "cb_test_secret_key_789")
        #expect(unredactedProvider?.cookieHeader == "cb_test_cookie_abc")
        #expect(unredactedProvider?.tokenAccounts?.accounts.first?.token == "cb_test_token_123")
    }

    @Test
    func `config dump command redacts fixture secrets unless explicitly requested`() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-config-dump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let secrets = [
            "fixture-api-key-value",
            "fixture-secret-key-value",
            "fixture-cookie-value",
            "fixture-token-account-value",
        ]
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Fixture account",
            token: secrets[3],
            addedAt: 1000,
            lastUsed: nil,
            usageScope: "team",
            organizationID: "fixture-org",
            workspaceID: "fixture-workspace")
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: .zai,
            enabled: true,
            apiKey: secrets[0],
            secretKey: secrets[1],
            cookieHeader: secrets[2],
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
        let configURL = fixtureDirectory.appendingPathComponent("config.json")
        try CodexBarConfigStore(fileURL: configURL).save(config)

        let redactedData = try Self.runConfigDump(configURL: configURL, showSecrets: false)
        let redactedJSON = try JSONSerialization.jsonObject(with: redactedData)
        let redactedOutput = try #require(String(data: redactedData, encoding: .utf8))
        #expect(redactedJSON is [String: Any])
        #expect(redactedOutput.contains("[REDACTED]"))
        for secret in secrets {
            #expect(!redactedOutput.contains(secret))
        }

        let rawData = try Self.runConfigDump(configURL: configURL, showSecrets: true)
        let rawJSON = try JSONSerialization.jsonObject(with: rawData)
        let rawOutput = try #require(String(data: rawData, encoding: .utf8))
        #expect(rawJSON is [String: Any])
        for secret in secrets {
            #expect(rawOutput.contains(secret))
        }
    }

    private static func runConfigDump(configURL: URL, showSecrets: Bool) throws -> Data {
        let process = Process()
        process.executableURL = Self.cliExecutableURL
        process.arguments = ["config", "dump"] + (showSecrets ? ["--show-secrets"] : [])
        process.environment = ProcessInfo.processInfo.environment.merging([
            CodexBarConfigStore.pathEnvironmentKey: configURL.path,
        ]) { _, fixturePath in fixturePath }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8) ?? "CodexBarCLI exited without an error message"
            throw NSError(domain: "CLIConfigCommandTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        return output
    }

    private static var cliExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CodexBarCLI")
    }
}
