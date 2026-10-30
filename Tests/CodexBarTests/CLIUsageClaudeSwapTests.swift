import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIUsageClaudeSwapTests {
    @Test
    func `auto usage follows the active swap slot instead of the browser account`() async throws {
        let output = try await self.fetch()
        let payload = try #require(output.payload.first)
        #expect(output.payload.count == 1)
        #expect(output.exitCode == .success)
        #expect(payload.source == "claude-swap")
        #expect(payload.usage?.identity?.accountEmail == "active@example.com")
        #expect(payload.usage?.identity?.accountID == "claude-swap:3")
        #expect(payload.usage?.primary?.usedPercent == 50)
        #expect(payload.usage?.secondary?.usedPercent == 41)
    }

    @Test
    func `explicit source and token account selection bypass swap`() async throws {
        let explicit = try await self.fetch(arguments: ["--source", "web"], expectAdapter: false)
        #expect(explicit.payload.first?.source == "web")
        #expect(explicit.payload.first?.usage?.identity?.accountEmail == "browser@example.com")
        let selected = try await self.fetch(arguments: ["--account", "missing"], expectAdapter: false)
        #expect(selected.exitCode != .success)
        #expect(selected.payload.first?.error != nil)
    }

    @Test
    func `configured source and disabled integration preserve ordinary fetching`() async throws {
        let configured = try await self.fetch(configSource: .web, expectAdapter: false)
        #expect(configured.payload.first?.source == "web")
        let disabled = try await self.fetch(enabled: false, expectAdapter: false)
        #expect(disabled.payload.first?.source == "web")
    }

    @Test
    func `explicit auto still follows a single active slot`() async throws {
        let list = #"""
        {
          "schemaVersion": 1,
          "activeAccountNumber": 3,
          "accounts": [
            {
              "number": 3,
              "email": "single@example.com",
              "active": true,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": {
                  "pct": 50
                }
              }
            }
          ]
        }
        """#
        let output = try await self.fetch(arguments: ["--source", "auto"], list: list, configSource: .web)
        #expect(output.payload.count == 1)
        #expect(output.payload.first?.source == "claude-swap")
        #expect(output.payload.first?.usage?.identity?.accountEmail == "single@example.com")
    }

    @Test
    func `adapter failure labels the fallback source and keeps its own identity`() async throws {
        let output = try await self.fetch(list: "invalid json")
        #expect(output.exitCode == .success)
        #expect(output.payload.first?.source == "web (claude-swap fallback)")
        #expect(output.payload.first?.usage?.identity?.accountEmail == "browser@example.com")
        #expect(output.payload.first?.usage?.secondary?.usedPercent == 92)
    }

    @Test
    func `no active slot never borrows an inactive slots usage`() async throws {
        let list = #"""
        {
          "schemaVersion": 1,
          "activeAccountNumber": null,
          "accounts": [
            {
              "number": 3,
              "email": "inactive@example.com",
              "active": false,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": {
                  "pct": 50
                }
              }
            }
          ]
        }
        """#
        let output = try await self.fetch(list: list)
        #expect(output.payload.first?.source == "web (claude-swap fallback)")
        #expect(output.payload.first?.usage?.identity?.accountEmail == "browser@example.com")
    }

    @Test
    func `active slot without usage falls back visibly despite a healthy inactive slot`() async throws {
        let list = #"""
        {
          "schemaVersion": 1,
          "activeAccountNumber": 3,
          "accounts": [
            {
              "number": 1,
              "email": "inactive@example.com",
              "active": false,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": {
                  "pct": 80
                }
              }
            },
            {
              "number": 3,
              "email": "active@example.com",
              "active": true,
              "usageStatus": "token_expired"
            }
          ]
        }
        """#
        let output = try await self.fetch(list: list)
        #expect(output.payload.first?.source == "web (claude-swap fallback)")
        #expect(output.payload.first?.usage?.identity?.accountEmail == "browser@example.com")
    }

    @Test
    func `last good active slot retains its timestamp and diagnostic`() async throws {
        let list = #"""
        {
          "schemaVersion": 1,
          "activeAccountNumber": 3,
          "accounts": [
            {
              "number": 3,
              "email": "active@example.com",
              "active": true,
              "usageStatus": "token_expired",
              "lastGoodUsage": {
                "fiveHour": {
                  "pct": 50
                }
              },
              "lastGoodFetchedAt": "2026-10-18T12:00:00Z"
            }
          ]
        }
        """#
        let output = try await self.fetch(list: list)
        #expect(output.payload.first?.source == "claude-swap")
        #expect(output.payload.first?.usage?.identity?.accountEmail == "active@example.com")
        #expect(output.payload.first?.usage?.updatedAt == ISO8601DateParser.parse("2026-10-18T12:00:00Z"))
        #expect(output.payload.first?.diagnostic?.contains("Token expired") == true)
    }

    @Test
    func `text output identifies the active slot and adapter fallback`() async throws {
        let active = try await self.fetch(json: false)
        #expect(active.sections.joined().contains("claude-swap"))
        #expect(active.sections.joined().contains("active@example.com"))
        #expect(!active.sections.joined().contains("browser@example.com"))
        let fallback = try await self.fetch(list: "invalid json", json: false)
        #expect(fallback.sections.joined().contains("web (claude-swap fallback)"))
        #expect(fallback.sections.joined().contains("browser@example.com"))
    }

    @Test
    func `pooled tcr fallback reports the actual adapter`() async throws {
        let output = try await self.fetch(
            list: #"{"schemaVersion":1,"activeAccountNumber":null,"accounts":[]}"#,
            source: .tcr)
        #expect(output.payload.first?.source == "web (tcr fallback)")
        #expect(output.payload.first?.usage?.identity?.accountEmail == "browser@example.com")
    }

    private func fetch(
        arguments: [String] = [],
        list: String? = nil,
        enabled: Bool = true,
        source: ClaudeSwapAccountSource = .claudeSwap,
        configSource: ProviderSourceMode = .auto,
        json: Bool = true,
        expectAdapter: Bool = true) async throws -> UsageCommandOutput
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("cswap")
        let invocation = root.appendingPathComponent("invoked")
        let response = list ?? """
        {"schemaVersion":1,"activeAccountNumber":3,"accounts":[
          {"number":1,"email":"browser@example.com","active":false,"usageStatus":"ok",
           "usage":{"fiveHour":{"pct":0},"sevenDay":{"pct":92}}},
          {"number":3,"email":"active@example.com","active":true,"usageStatus":"ok",
           "usage":{"fiveHour":{"pct":50},"sevenDay":{"pct":41}}}
        ]}
        """
        try FakeExecutable.install("""
        #!/bin/sh
        [ "$#" -eq 2 ] && [ "$1" = "\(source.listArguments[0])" ] && [ "$2" = "--json" ] || exit 2
        [ ! -e '\(invocation.path)' ] || exit 2
        touch '\(invocation.path)'
        cat <<'JSON'
        \(response)
        JSON
        """, at: executable)
        var provider = ProviderConfig(id: .claude, enabled: true, source: configSource)
        provider.claudeSwapEnabled = enabled
        provider.claudeSwapSource = source.rawValue
        provider.claudeSwapExecutablePath = executable.path
        let values = try Program(descriptors: CodexBarCLI.commandDescriptors())
            .resolve(arguments: ["usage", "--provider", "claude", "--no-color"] + (json ? ["--json"] : []) + arguments)
            .parsedValues
        let setup = try CLIUsageFetchSetup(
            values: values, providers: [.claude], output: CLIOutputPreferences.from(values: values))
        let context = try TokenAccountCLIContext(
            selection: setup.tokenSelection,
            config: CodexBarConfig(providers: [provider]),
            verbose: false,
            baseEnvironment: [:])
        let loader: ClaudeWebFetchStrategy.UsageLoader = { _ in
            ClaudeUsageSnapshot(
                primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 92, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                opus: nil,
                updatedAt: Date(),
                accountEmail: "browser@example.com",
                accountOrganization: nil,
                loginMethod: nil,
                rawText: nil)
        }
        let output = await ClaudeWebFetchStrategy.$usageLoaderOverrideForTesting.withValue(loader) {
            await CodexBarCLI.fetchSingleProviderUsageOutput(
                provider: .claude,
                includeStatus: false,
                appAutoVerifier: false,
                tokenContext: context,
                command: setup.command)
        }
        #expect(FileManager.default.fileExists(atPath: invocation.path) == expectAdapter)
        return output
    }
}
