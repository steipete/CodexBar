import CodexBarCore
import Commander
import Testing
@testable import CodexBarCLI

struct CLIUsageFetchSetupTests {
    @Test(arguments: ["usage", "cards"])
    func `shared fetch defaults and explicit options survive decoding`(name: String) throws {
        let defaults = try Self.decode(name, arguments: [])
        #expect(defaults.command.format == .text)
        #expect(defaults.command.includeCredits)
        #expect(defaults.command.webTimeout == 60)
        #expect(defaults.command.sourceModeOverride == nil)
        #expect(!defaults.includeStatus)
        #expect(!defaults.tokenSelection.usesOverride)
        #expect(defaults.command.cardsLayout == (name == "cards"))
        #expect(defaults.command.providerRuntime == .cli)

        let explicit = try Self.decode(
            name,
            arguments: [
                "--source", "API", "--web-timeout", "0", "--no-credits", "--no-color", "--status", "--verbose",
                "--web-debug-dump-html", "--antigravity-plan-debug", "--augment-debug", "--account-index", "2",
            ],
            providers: [.claude])
        #expect(explicit.command.sourceModeOverride == .api)
        #expect(explicit.command.webTimeout == 0)
        #expect(!explicit.command.includeCredits)
        #expect(!explicit.command.useColor)
        #expect(explicit.includeStatus)
        #expect(explicit.command.verbose)
        #expect(explicit.command.webDebugDumpHTML)
        #expect(explicit.command.antigravityPlanDebug)
        #expect(explicit.command.augmentDebug)
        #expect(explicit.tokenSelection.index == 1)
        let web = try Self.decode(name, arguments: ["--source", "invalid", "--web"])
        #expect(web.command.sourceModeOverride == .web)
    }

    @Test(arguments: ["usage", "cards"])
    func `shared validation keeps error precedence`(name: String) throws {
        let cases: [([String], String)] = [
            (["--source", "invalid", "--web-timeout", "invalid"], "--source must be auto|web|cli|oauth|api."),
            (
                ["--web-timeout", "nan", "--account-index", "0"],
                "--web-timeout must be a finite, nonnegative number within the supported range."),
            (["--account-index", "0", "--all-accounts"], "--account-index must be a positive integer."),
            (
                ["--account", "fixture", "--all-accounts"],
                "--all-accounts cannot be combined with --account or --account-index."),
        ]
        for (arguments, expected) in cases {
            do {
                _ = try Self.decode(name, arguments: arguments)
                Issue.record("Expected argument failure")
            } catch let error as CLIArgumentError {
                #expect(error.message == expected)
            }
        }
        #expect(throws: CLIArgumentError.self) {
            try Self.decode(name, arguments: ["--all-accounts"], providers: [.codex, .claude])
        }
        let all = try Self.decode(name, arguments: ["--all-accounts"])
        #expect(all.command.includeAllCodexAccounts)
    }

    @Test
    func `usage retains JSON credits and verifier policy`() throws {
        let json = try Self.decode("usage", arguments: ["--json", "--no-credits", "--json-only"])
        #expect(json.command.format == .json)
        #expect(json.command.includeCredits)
        #expect(json.command.jsonOnly)
        #expect(!json.command.useColor)
        let verifier = try Self.decode(
            "usage", arguments: ["--app-auto-verifier", "--source", "auto"], providers: [.claude])
        #expect(verifier.command.providerRuntime == .app)
        #expect(throws: CLIArgumentError.self) {
            try Self.decode("usage", arguments: ["--app-auto-verifier", "--source", "auto"])
        }
        #expect(throws: CLIArgumentError.self) {
            try Self.decode("usage", arguments: ["--app-auto-verifier", "--account", "fixture"], providers: [.claude])
        }
    }

    private static func decode(
        _ name: String,
        arguments: [String],
        providers: [UsageProvider] = [.codex]) throws -> CLIUsageFetchSetup
    {
        let values = try Program(descriptors: CodexBarCLI.commandDescriptors())
            .resolve(arguments: [name] + arguments).parsedValues
        return try CLIUsageFetchSetup(
            values: values,
            providers: providers,
            output: CLIOutputPreferences.from(values: values, allowsToon: name == "usage"),
            cardsLayout: name == "cards")
    }
}
