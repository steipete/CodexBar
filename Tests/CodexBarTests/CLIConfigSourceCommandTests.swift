import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIConfigSourceCommandTests {
    @Test
    func `set source validates aliases and provider capabilities`() throws {
        let selection = try CodexBarCLI.configSourceSelection(provider: "COMMAND-CODE", source: "WEB")
        #expect(selection.provider == .commandcode)
        #expect(selection.source == .web)
        for (provider, source) in [
            (nil, "web"),
            ("unknown", "auto"),
            ("claude", nil),
            ("claude", "unknown"),
            ("commandcode", "cli"),
        ] {
            #expect(throws: CLIArgumentError.self) {
                _ = try CodexBarCLI.configSourceSelection(provider: provider, source: source)
            }
        }
    }

    @Test
    func `set source preserves config fields and auto removes the override`() throws {
        let raw = #"{"version":1,"providers":["# +
            #"{"id":"claude","enabled":false,"source":"web","cookieHeader":"fixture-cookie","# +
            #""futureField":{"keep":true}},"# +
            #"{"id":"future-provider","enabled":true,"opaque":"keep"}]}"#
        let config = try CodexBarConfig.decode(from: Data(raw.utf8))
        let updated = CodexBarCLI.configSettingSource(config, provider: .claude, source: .cli)
        let entry = try #require(updated.providerConfig(for: .claude))
        #expect(entry.source == .cli)
        #expect(entry.enabled == false)
        #expect(entry.cookieHeader == "fixture-cookie")
        let data = try updated.encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        #expect(providers.first { $0["id"] as? String == "claude" }?["futureField"] as? [String: Bool]
            == ["keep": true])
        #expect(providers.first { $0["id"] as? String == "future-provider" }?["opaque"] as? String == "keep")
        let reset = CodexBarCLI.configSettingSource(updated, provider: .claude, source: .auto)
        #expect(reset.providerConfig(for: .claude)?.source == nil)
        #expect(reset.providerConfig(for: .claude)?.enabled == false)
    }

    @Test
    func `set source accepts shared JSON output options`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(ConfigSetSourceOptions()).flattened())
        let values = try parser.parse(arguments: ["--provider", "claude", "--source", "cli", "--json", "--pretty"])
        #expect(values.options["provider"] == ["claude"])
        #expect(values.options["source"] == ["cli"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: values) == .json)
        #expect(values.flags.contains("pretty"))
        #expect(CodexBarCLI.configHelp(version: "fixture").contains("config set-source"))
    }

    @Test
    func `real CLI persists source emits safe JSON and rejects invalid writes`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let store = CodexBarConfigStore(fileURL: url)
        try store.save(CodexBarConfig(providers: [ProviderConfig(
            id: .claude, enabled: false, source: .web, cookieHeader: "fixture-secret-cookie")]))
        let output = try await Self.run(root: root, arguments: ["--provider", "claude", "--source", "cli", "--json"])
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(json["provider"] as? String == "claude")
        #expect(json["source"] as? String == "cli")
        #expect(json["enabled"] as? Bool == false)
        #expect(json["configPath"] as? String == url.path)
        #expect(!output.contains("fixture-secret-cookie"))
        #expect(try store.load()?.providerConfig(for: .claude)?.source == .cli)
        let before = try Data(contentsOf: url)
        await #expect(throws: SubprocessRunnerError.self) {
            _ = try await Self.run(root: root, arguments: ["--provider", "commandcode", "--source", "cli"])
        }
        #expect(try Data(contentsOf: url) == before)
        _ = try await Self.run(
            root: root,
            arguments: ["--provider", "claude", "--source", "auto", "--pretty", "--json"])
        #expect(try store.load()?.providerConfig(for: .claude)?.source == nil)
        #expect(try store.load()?.providerConfig(for: .claude)?.cookieHeader == "fixture-secret-cookie")
    }

    private static func run(root: URL, arguments: [String]) async throws -> String {
        let environment = ProcessInfo.processInfo.environment.merging([
            "CODEXBAR_CONFIG": root.appendingPathComponent("config.json").path,
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex").path,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]) { _, fixture in fixture }
        let result = try await SubprocessRunner.run(
            binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
            arguments: ["config", "set-source"] + arguments,
            environment: environment,
            timeout: 15,
            label: "synthetic config set source")
        return result.stdout
    }
}
