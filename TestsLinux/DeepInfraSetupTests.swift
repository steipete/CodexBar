import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct DeepInfraSetupTests {
    @Test
    func `inventory declares static DeepInfra setup without exposing a saved key`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .deepinfra, apiKey: "deepinfra-fixture-secret"),
        ])
        let row = try #require(CodexBarCLI.configProviderStatuses(config).first { $0.provider == "deepinfra" })
        let encoded = try JSONEncoder().encode(row)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let expected: [String: Any] = [
            "status": "declared",
            "routes": [[
                "id": "api-key",
                "method": "apiKey",
                "platforms": ["macOS", "linux"],
                "requiredInputs": [[
                    "id": "api-key",
                    "configFields": ["apiKey", "tokenAccounts.accounts[].token"],
                    "environmentVariables": ["DEEPINFRA_API_KEY", "DEEPINFRA_TOKEN"],
                ]],
                "command": "codexbar config set-api-key --provider deepinfra --stdin",
                "hint": UsageFormatter.localized(
                    "The command reads a piped API key and saves it as a standalone key. " +
                        "A selected API token account overrides the standalone key."),
            ]],
            "optionalCapabilities": [],
        ]
        #expect(try #require(json["setup"] as? NSDictionary) == expected as NSDictionary)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("deepinfra-fixture-secret"))
        let empty = try #require(CodexBarCLI.configProviderStatuses(.init(providers: []))
            .first { $0.provider == "deepinfra" })
        #expect(row.setup == empty.setup)
    }

    @Test
    func `advertised command resolves to the existing stdin setter`() throws {
        let route = try #require(DeepInfraProviderDescriptor.descriptor.setup.routes.first)
        let command = try #require(route.command)
        let arguments = command.split(separator: " ").map(String.init)
        #expect(arguments.first == "codexbar")
        let program = Program(descriptors: CodexBarCLI.commandDescriptors(for: "config"))
        let invocation = try program.resolve(arguments: Array(arguments.dropFirst()))
        #expect(invocation.path == ["config", "set-api-key"])
        #expect(invocation.parsedValues.options["provider"] == ["deepinfra"])
        #expect(invocation.parsedValues.flags.contains("stdin"))
        #expect(invocation.parsedValues.options["apiKey"] == nil)
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .deepinfra))
    }
}
