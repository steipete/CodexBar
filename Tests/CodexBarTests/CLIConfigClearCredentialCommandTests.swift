import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIConfigClearCredentialCommandTests {
    private static let fixture = #"{"version":1,"providers":["# +
        #"{"id":"claude","enabled":true,"source":"web","apiKey":"fixture-api-key","# +
        #""cookieHeader":"sessionKey=fixture","cookieSource":"manual","futureField":{"keep":true},"# +
        #""tokenAccounts":{"version":1,"activeIndex":0,"accounts":["# +
        #"{"id":"00000000-0000-0000-0000-000000000001","label":"fixture","# +
        #""token":"fixture-account-token","addedAt":1000}]}},"# +
        #"{"id":"future-provider","opaque":"keep"}]}"#

    @Test
    func `clear credential flags select fields and default to both`() {
        #expect(CodexBarCLI.configCredentialFields(apiKey: false, cookie: false) == [.apiKey, .cookieHeader])
        #expect(CodexBarCLI.configCredentialFields(apiKey: true, cookie: false) == [.apiKey])
        #expect(CodexBarCLI.configCredentialFields(apiKey: false, cookie: true) == [.cookieHeader])
        #expect(CodexBarCLI.configCredentialFields(apiKey: true, cookie: true) == [.apiKey, .cookieHeader])
    }

    @Test
    func `clear credential preserves Manual source while removing selected credentials`() throws {
        let config = try CodexBarConfig.decode(from: Data(Self.fixture.utf8))

        let (cookieOnly, cookieCleared) = CodexBarCLI.configClearingCredential(
            config, provider: .claude, fields: [.cookieHeader])
        #expect(cookieCleared == [.cookieHeader])
        let cookieEntry = try #require(cookieOnly.providerConfig(for: .claude))
        #expect(cookieEntry.cookieHeader == nil)
        #expect(cookieEntry.cookieSource == .manual)
        #expect(cookieEntry.apiKey == "fixture-api-key")

        let (both, bothCleared) = CodexBarCLI.configClearingCredential(
            config, provider: .claude, fields: [.apiKey, .cookieHeader])
        #expect(bothCleared == [.apiKey, .cookieHeader])
        let entry = try #require(both.providerConfig(for: .claude))
        #expect(entry.apiKey == nil)
        #expect(entry.cookieHeader == nil)
        #expect(entry.cookieSource == .manual)
        #expect(entry.enabled == true)
        #expect(entry.source == .web)
        #expect(entry.tokenAccounts?.accounts.first?.token == "fixture-account-token")
        let object = try #require(JSONSerialization.jsonObject(with: both.encodedData()) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        #expect(providers.first { $0["id"] as? String == "claude" }?["futureField"] as? [String: Bool]
            == ["keep": true])
        #expect(providers.first { $0["id"] as? String == "future-provider" }?["opaque"] as? String == "keep")

        let (_, nothing) = CodexBarCLI.configClearingCredential(both, provider: .claude, fields: [.apiKey])
        #expect(nothing.isEmpty)
    }

    @Test
    func `clear credential keeps non manual cookie sources`() {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .cursor, cookieHeader: "fixture=1", cookieSource: .off))
        let (updated, cleared) = CodexBarCLI.configClearingCredential(
            config,
            provider: .cursor,
            fields: [.cookieHeader])
        #expect(cleared == [.cookieHeader])
        #expect(updated.providerConfig(for: .cursor)?.cookieHeader == nil)
        #expect(updated.providerConfig(for: .cursor)?.cookieSource == .off)
    }

    @Test
    func `clear credential drops the Moonshot key region with the key`() {
        var config = CodexBarConfig.makeDefault()
        config = CodexBarCLI.configSettingAPIKey(config, provider: .moonshot, apiKey: "fixture", enableProvider: true)
        #expect(config.providerConfig(for: .moonshot)?.apiKeyRegion != nil)
        let (updated, _) = CodexBarCLI.configClearingCredential(config, provider: .moonshot, fields: [.apiKey])
        #expect(updated.providerConfig(for: .moonshot)?.apiKey == nil)
        #expect(updated.providerConfig(for: .moonshot)?.apiKeyRegion == nil)
    }

    @Test
    func `clear credential parses flags and is documented`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigClearCredentialOptions()).flattened())
        let values = try parser.parse(arguments: ["--provider", "claude", "--api-key", "--cookie", "--json"])
        #expect(values.options["provider"] == ["claude"])
        #expect(values.flags.contains("apiKey"))
        #expect(values.flags.contains("cookie"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: values) == .json)
        #expect(CodexBarCLI.configHelp(version: "fixture").contains("config clear-credential --provider <name>"))
    }

    @Test
    func `real CLI clears credentials and reports removed fields`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-clear-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try Data(Self.fixture.utf8).write(to: url)
        let store = CodexBarConfigStore(fileURL: url)

        let cookie = try await Self.run(root: root, arguments: ["--provider", "claude", "--cookie", "--json"])
        let json = try #require(JSONSerialization.jsonObject(with: Data(cookie.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["provider", "cleared", "configPath"])
        #expect(json["provider"] as? String == "claude")
        #expect(json["cleared"] as? [String] == ["cookieHeader"])
        #expect(json["configPath"] as? String == url.path)
        #expect(!cookie.contains("fixture"))
        #expect(try store.load()?.providerConfig(for: .claude)?.apiKey == "fixture-api-key")
        #expect(try store.load()?.providerConfig(for: .claude)?.cookieSource == .manual)

        let text = try await Self.run(root: root, arguments: ["--provider", "claude"])
        #expect(text == "Config: cleared API key for Claude\n")
        let entry = try #require(try store.load()?.providerConfig(for: .claude))
        #expect(entry.apiKey == nil)
        #expect(entry.cookieHeader == nil)
        #expect(entry.cookieSource == .manual)
        #expect(entry.tokenAccounts?.accounts.first?.token == "fixture-account-token")

        let before = try Data(contentsOf: url)
        let noop = try await Self.run(root: root, arguments: ["--provider", "claude"])
        #expect(noop == "Config: no stored API key or manual cookie for Claude\n")
        #expect(try Data(contentsOf: url) == before)
    }

    @Test
    func `real CLI clear never creates or rewrites config without a change`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-clear-noop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")

        let output = try await Self.run(root: root, arguments: ["--provider", "claude", "--json"])
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(json["cleared"] as? [String] == [])
        #expect(!FileManager.default.fileExists(atPath: url.path))

        do {
            _ = try await Self.run(root: root, arguments: ["--provider", "unknown"])
            Issue.record("Unknown provider unexpectedly succeeded")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            #expect(code == 1)
            #expect(stderr.contains("Unknown or missing provider"))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private static func run(root: URL, arguments: [String]) async throws -> String {
        let environment = [
            "CODEXBAR_CONFIG": root.appendingPathComponent("config.json").path,
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex").path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]
        let result = try await SubprocessRunner.run(
            binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
            arguments: ["config", "clear-credential"] + arguments,
            environment: environment,
            timeout: 15,
            label: "synthetic config clear credential")
        return result.stdout
    }
}
