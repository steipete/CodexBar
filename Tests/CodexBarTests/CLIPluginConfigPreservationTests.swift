import CodexBarCore
import Foundation
import Testing

struct CLIPluginConfigPreservationTests {
    @Test(arguments: ["enable", "disable", "set-api-key"], ["missing", "invalid", "loaded"])
    func `config writes preserve unavailable plugins`(_ command: String, discovery: String) async throws {
        let fixture = try Fixture(discoveryFails: discovery == "invalid")
        defer { fixture.remove() }
        if discovery == "loaded" { try fixture.installPlugin() }
        let arguments = ["config", command, "--provider", command == "set-api-key" ? "groq" : "grok", "--json"]
            + (command == "set-api-key" ? ["--api-key", "fixture-api-key"] : [])
        _ = try await fixture.run(arguments)
        try CodexBarConfigUnknownProviderTests.expectRetainedRecords(in: Data(contentsOf: fixture.configURL))
    }

    @Test
    func `config commands discover installed plugins at startup`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installPlugin()
        var input = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.configURL)) as? [String: Any])
        var records = try #require(input["providers"] as? [[String: Any]])
        records[0].removeValue(forKey: "future")
        input["providers"] = records
        try JSONSerialization.data(withJSONObject: input).write(to: fixture.configURL)
        let statuses = try await fixture.run(["config", "providers", "--json"])
        let rows = try #require(JSONSerialization.jsonObject(with: statuses) as? [[String: Any]])
        #expect(rows.first?["provider"] as? String == "fixture-unavailable")
        #expect(rows.first?["displayName"] as? String == "Fixture Meter")
        let dump = try await fixture.run(["config", "dump", "--json"])
        let root = try #require(JSONSerialization.jsonObject(with: dump) as? [String: Any])
        let providers = try #require(root["providers"] as? [[String: Any]])
        #expect(providers.first?["pluginSettings"] as? [String: String] == ["scope": "fixture"])
        #expect(providers.first?["pluginSecrets"] as? [String: String] == ["TOKEN": "[REDACTED]"])
    }

    @Test
    func `config providers lists unavailable plugins and dump redacts them`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let statuses = try await fixture.run(["config", "providers", "--json"])
        let rows = try #require(JSONSerialization.jsonObject(with: statuses) as? [[String: Any]])
        #expect(rows.first?["provider"] as? String == "fixture-unavailable")
        #expect(rows.first?["displayName"] as? String == "plugin (not loaded)")
        let dump = try await fixture.run(["config", "dump", "--json"])
        let text = try #require(String(data: dump, encoding: .utf8))
        #expect(text.contains("fixture-unavailable"))
        #expect(text.contains("[REDACTED]"))
        #expect(!text.contains("fixture-secret"))
        #expect(!text.contains("fixture-other"))
        let raw = try await fixture.run(["config", "dump", "--json", "--show-secrets"])
        try CodexBarConfigUnknownProviderTests.expectRetainedRecords(in: raw)
    }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var configURL: URL {
            self.directory.appendingPathComponent("config.json")
        }

        var providersDirectory: URL {
            self.directory.appendingPathComponent(".config/codexbar/providers")
        }

        init(discoveryFails: Bool = false) throws {
            try FileManager.default.createDirectory(at: self.providersDirectory, withIntermediateDirectories: true)
            if discoveryFails {
                try Data("invalid plugin source".utf8)
                    .write(to: self.providersDirectory.appendingPathComponent("bad.js"))
            }
            try CodexBarConfigUnknownProviderTests.fixture.write(to: self.configURL)
        }

        func remove() { try? FileManager.default.removeItem(at: self.directory) }

        func installPlugin() throws {
            let source = #"""
            defineProvider({
              id: "fixture-unavailable", name: "Fixture Meter", endpoints: ["https://fixture.example"],
              settings: [{ key: "scope", title: "Scope", type: "plain" }],
              fetchUsage() { return { primary: { usedPercent: 1 } }; }
            });
            """#
            try Data(source.utf8).write(to: self.providersDirectory.appendingPathComponent("fixture.js"))
        }

        func run(_ arguments: [String]) async throws -> Data {
            let result = try await SubprocessRunner.run(
                binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
                arguments: arguments,
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": self.directory.path,
                    "CFFIXED_USER_HOME": self.directory.path,
                    "CODEX_HOME": self.directory.appendingPathComponent(".codex").path,
                    "CODEXBAR_CONFIG": self.configURL.path,
                    "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
                ],
                timeout: 30,
                label: "isolated plugin config")
            return Data(result.stdout.utf8)
        }
    }
}
