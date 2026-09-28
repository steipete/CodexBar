import CodexBarCore
import Foundation
import Testing

struct CLIPluginConfigPreservationTests {
    @Test(arguments: [nil, "", " \t\r\n "] as [String?])
    func `missing and blank configs permit validation usage and settings writes`(_ contents: String?) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.installCodexStub()
        try FileManager.default.removeItem(at: fixture.configURL)
        if let contents { try Data(contents.utf8).write(to: fixture.configURL) }

        _ = try await fixture.run(["config", "validate", "--json"])
        let usage = try await fixture.run(["usage", "--provider", "codex", "--source", "cli", "--json", "--json-only"])
        let payloads = try #require(JSONSerialization.jsonObject(with: usage) as? [[String: Any]])
        let payload = try #require(payloads.first)
        #expect(payload["error"] == nil)
        let snapshot = try #require(payload["usage"] as? [String: Any])
        let primary = try #require(snapshot["primary"] as? [String: Any])
        #expect(primary["usedPercent"] as? Double == 1)
        #expect((try? Data(contentsOf: fixture.configURL)) == contents.map { Data($0.utf8) })

        _ = try await fixture.run(["config", "enable", "--provider", "grok", "--json"])
        let saved = try CodexBarConfigStore(fileURL: fixture.configURL).load()
        #expect(saved?.providerConfig(for: .grok)?.enabled == true)
    }

    @Test(arguments: ["{", " \n{\"providers\":"])
    func `malformed config reports an error and cannot be overwritten by config commands`(
        _ contents: String) async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(contents.utf8).write(to: fixture.configURL)
        for arguments in [
            ["config", "validate", "--json"],
            ["usage", "--provider", "grok", "--json", "--json-only"],
            ["config", "enable", "--provider", "grok", "--json"],
        ] {
            let output = try await fixture.run(arguments, acceptsNonZeroExit: true)
            let payloads = try #require(JSONSerialization.jsonObject(with: output) as? [[String: Any]])
            let error = try #require(payloads.first?["error"] as? [String: Any])
            #expect(error["kind"] as? String == "config")
            #expect((error["message"] as? String)?.hasPrefix("Failed to decode CodexBar config:") == true)
            #expect(try Data(contentsOf: fixture.configURL) == Data(contents.utf8))
        }
    }

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

        func installCodexStub() throws {
            let source = #"""
            #!/usr/bin/python3 -S
            import json, sys
            if "--version" in sys.argv:
                print("codex-cli 1.0.0")
                sys.exit(0)
            assert "app-server" in sys.argv
            for line in sys.stdin:
                request = json.loads(line)
                if "id" not in request:
                    continue
                result = {}
                if request.get("method") == "account/rateLimits/read":
                    result = {"rateLimits": {"planType": "plus", "primary": {
                        "usedPercent": 1, "windowDurationMins": 300}}}
                elif request.get("method") == "account/read":
                    result = {"account": {"type": "chatgpt", "email": "fixture@example.com",
                                          "planType": "plus"}, "requiresOpenaiAuth": False}
                print(json.dumps({"id": request["id"], "result": result}), flush=True)
            """#
            let url = self.directory.appendingPathComponent("codex")
            try Data(source.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

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

        func run(_ arguments: [String], acceptsNonZeroExit: Bool = false) async throws -> Data {
            let result = try await SubprocessRunner.run(
                binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
                arguments: arguments,
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": self.directory.path,
                    "CFFIXED_USER_HOME": self.directory.path,
                    "CODEX_HOME": self.directory.appendingPathComponent(".codex").path,
                    "CODEX_CLI_PATH": self.directory.appendingPathComponent("codex").path,
                    "SHELL": "/bin/sh",
                    "CODEXBAR_CONFIG": self.configURL.path,
                    "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
                ],
                timeout: 30,
                acceptsNonZeroExit: acceptsNonZeroExit,
                label: "isolated plugin config")
            return Data(result.stdout.utf8)
        }
    }
}
