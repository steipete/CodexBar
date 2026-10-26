import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIConfigCookieCommandTests {
    @Test
    func `set cookie only accepts providers that read config cookies`() throws {
        #expect(try CodexBarCLI.configCookieProvider("CLAUDE") == .claude)
        #expect(CodexBarCLI.readsConfigCookieHeader(.claude))
        #expect(CodexBarCLI.readsConfigCookieHeader(.cursor))
        #expect(CodexBarCLI.readsConfigCookieHeader(.codex))
        #expect(CodexBarCLI.readsConfigCookieHeader(.deepseek))
        for provider in [UsageProvider.augment, .muse, .qoder, .devin, .windsurf] {
            #expect(CodexBarCLI.readsConfigCookieHeader(provider))
        }
        #expect(!CodexBarCLI.readsConfigCookieHeader(.langdock))
        #expect(!CodexBarCLI.readsConfigCookieHeader(.groq))
        #expect(!CodexBarCLI.readsConfigCookieHeader(.elevenlabs))
        #expect(!CodexBarCLI.readsConfigCookieHeader(.openrouter))
        for provider in [nil, "unknown", "elevenlabs"] {
            #expect(throws: CLIArgumentError.self) {
                _ = try CodexBarCLI.configCookieProvider(provider)
            }
        }
    }

    @Test
    func `set cookie support covers every registered alias consistently`() throws {
        for (alias, provider) in ProviderDescriptorRegistry.cliNameMap {
            if CodexBarCLI.readsConfigCookieHeader(provider) {
                #expect(try CodexBarCLI.configCookieProvider(alias) == provider)
            } else {
                #expect(throws: CLIArgumentError.self) {
                    _ = try CodexBarCLI.configCookieProvider(alias)
                }
            }
        }
    }

    @Test
    func `set cookie input rejects ambiguous empty and multi line values`() throws {
        #expect(try CodexBarCLI.resolveConfigCookieInput(cookie: "  a=1; b=2 \n", readFromStdin: false) == "a=1; b=2")
        for (cookie, stdin) in [("a=1", true), ("   ", false), ("a=1\nb=2", false)] as [(String?, Bool)] {
            #expect(throws: CLIArgumentError.self) {
                _ = try CodexBarCLI.resolveConfigCookieInput(cookie: cookie, readFromStdin: stdin)
            }
        }
        #expect(throws: CLIArgumentError.self) {
            _ = try CodexBarCLI.resolveConfigCookieInput(cookie: nil, readFromStdin: false)
        }
    }

    @Test
    func `set cookie stores manual source and preserves other fields`() throws {
        let raw = #"{"version":1,"providers":["# +
            #"{"id":"claude","enabled":false,"source":"web","apiKey":"fixture-api-key","cookieSource":"auto","# +
            #""futureField":{"keep":true}}]}"#
        let config = try CodexBarConfig.decode(from: Data(raw.utf8))

        let kept = CodexBarCLI.configSettingCookie(
            config, provider: .claude, cookieHeader: "sessionKey=fixture", enableProvider: false)
        let keptEntry = try #require(kept.providerConfig(for: .claude))
        #expect(keptEntry.cookieHeader == "sessionKey=fixture")
        #expect(keptEntry.cookieSource == .manual)
        #expect(keptEntry.enabled == false)
        #expect(keptEntry.source == .web)
        #expect(keptEntry.apiKey == "fixture-api-key")
        let object = try #require(JSONSerialization.jsonObject(with: kept.encodedData()) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        #expect(providers.first { $0["id"] as? String == "claude" }?["futureField"] as? [String: Bool]
            == ["keep": true])

        let enabled = CodexBarCLI.configSettingCookie(
            config, provider: .claude, cookieHeader: "sessionKey=fixture", enableProvider: true)
        #expect(enabled.providerConfig(for: .claude)?.enabled == true)
    }

    @Test
    func `set cookie parses shared options and is documented`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigSetCookieOptions()).flattened())
        let values = try parser.parse(arguments: ["--provider", "claude", "--stdin", "--no-enable", "--json"])
        #expect(values.options["provider"] == ["claude"])
        #expect(values.flags.contains("stdin"))
        #expect(values.flags.contains("noEnable"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: values) == .json)
        #expect(CodexBarCLI.configHelp(version: "fixture").contains("config set-cookie --provider <name>"))
    }

    @Test
    func `real CLI stores stdin cookie without echoing it`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-cookie-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let raw = #"{"version":1,"providers":[{"id":"claude","enabled":false,"apiKey":"fixture-api-key"},"# +
            #"{"id":"future-provider","opaque":"keep"}]}"#
        try Data(raw.utf8).write(to: url)

        let output = try await Self.run(
            root: root,
            arguments: ["--provider", "claude", "--stdin", "--no-enable", "--json"],
            stdin: "sessionKey=fixture-secret-cookie\n")
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["provider", "enabled", "configPath"])
        #expect(json["provider"] as? String == "claude")
        #expect(json["enabled"] as? Bool == false)
        #expect(json["configPath"] as? String == url.path)
        #expect(!output.contains("fixture-secret-cookie"))

        let store = CodexBarConfigStore(fileURL: url)
        let entry = try #require(try store.load()?.providerConfig(for: .claude))
        #expect(entry.cookieHeader == "sessionKey=fixture-secret-cookie")
        #expect(entry.cookieSource == .manual)
        #expect(entry.apiKey == "fixture-api-key")
        #expect(entry.enabled == false)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let savedProviders = try #require(saved["providers"] as? [[String: Any]])
        #expect(savedProviders.first { $0["id"] as? String == "future-provider" }?["opaque"] as? String == "keep")

        let text = try await Self.run(root: root, arguments: ["--provider", "claude", "--cookie", "sessionKey=next"])
        #expect(text == "Config: stored manual cookie for Claude and enabled\n")
        #expect(try store.load()?.providerConfig(for: .claude)?.enabled == true)
    }

    @Test
    func `real CLI rejects invalid cookie arguments without writing`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-cookie-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let before = Data(#"{ "version":1, "providers":[{"id":"claude","enabled":false}] }"#.utf8)
        try before.write(to: url)
        for (arguments, message) in [
            (["--cookie", "a=1"], "Unknown or missing provider"),
            (["--provider", "elevenlabs", "--cookie", "a=1"], "elevenlabs does not support config cookies"),
            (["--provider", "langdock", "--cookie", "a=1"], "langdock does not support config cookies"),
            (["--provider", "groq", "--cookie", "a=1"], "groq does not support config cookies"),
            (["--provider", "claude"], "Missing cookie"),
            (["--provider", "claude", "--cookie", "a=1", "--stdin"], "Use either --cookie or --stdin"),
        ] {
            do {
                _ = try await Self.run(root: root, arguments: arguments)
                Issue.record("Invalid arguments unexpectedly succeeded")
            } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
                #expect(code == 1)
                #expect(stderr.contains(message))
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test(arguments: [UsageProvider.augment, .muse])
    func `real CLI stores cookies for providers whose source picker omits web`(provider: UsageProvider) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-cookie-typed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try await Self.run(
            root: root,
            arguments: ["--provider", provider.rawValue, "--stdin", "--json"],
            stdin: "session=fixture-secret\n")
        #expect(!output.contains("fixture-secret"))
        let store = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        let entry = try #require(try store.load()?.providerConfig(for: provider.instanceID))
        let contribution = try #require(ProviderDescriptorRegistry.descriptor(for: provider).settingsSection
            .credentialContribution(context: .init(config: entry, account: nil)))
        let snapshot = ProviderSettingsSnapshot(contributions: [contribution])
        let cookies = try #require(ProviderDescriptorRegistry.descriptor(for: provider).settingsSection
            .cookieSettings(from: snapshot))
        #expect(cookies.cookieSource == .manual)
        #expect(cookies.manualCookieHeader == "session=fixture-secret")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func `Windsurf config cookies reach the CLI settings snapshot`() throws {
        let config = CodexBarCLI.configSettingCookie(
            CodexBarConfig(providers: []),
            provider: .windsurf,
            cookieHeader: "session=fixture-secret",
            enableProvider: true)
        let context = try TokenAccountCLIContext(
            selection: .init(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:])
        let settings = try #require(context.settingsSnapshot(for: .windsurf, account: nil)?.windsurf)
        #expect(settings.cookieSource == .manual)
        #expect(settings.manualCookieHeader == "session=fixture-secret")
    }

    private static func run(root: URL, arguments: [String], stdin: String = "") async throws -> String {
        let input = root.appendingPathComponent("stdin-\(UUID())")
        try Data(stdin.utf8).write(to: input)
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let environment = [
            "CODEXBAR_CONFIG": root.appendingPathComponent("config.json").path,
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex").path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]
        let result = try await SubprocessRunner.run(
            binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
            arguments: ["config", "set-cookie"] + arguments,
            environment: environment,
            timeout: 15,
            standardInput: handle,
            label: "synthetic config set cookie")
        return result.stdout
    }
}
