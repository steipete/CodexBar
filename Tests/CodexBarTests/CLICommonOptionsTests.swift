import Commander
import Testing
@testable import CodexBarCLI

struct CLICommonOptionsTests {
    private static let paths = [
        ["cache", "clear"], ["cost"], ["config", "validate"], ["config", "dump"],
        ["config", "providers"], ["config", "enable"], ["config", "disable"], ["config", "set-api-key"],
        ["config", "set-cookie"], ["config", "clear-credential"],
    ]

    @Test(arguments: Self.paths)
    func `common flags survive real command resolution`(path: [String]) throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let parsed = try program.resolve(arguments: path + [
            "-v", "--json-output", "--log-level", "debug", "--format", "json", "--json", "--json-only", "--pretty",
        ]).parsedValues
        #expect(parsed.flags == ["verbose", "jsonOutput", "jsonShortcut", "jsonOnly", "pretty"])
        #expect(parsed.options == ["logLevel": ["debug"], "format": ["json"]])
        #expect(CLIOutputPreferences.from(values: parsed).format == .json)
        #expect(CLIOutputPreferences.from(values: parsed).pretty)

        let defaults = try program.resolve(arguments: path).parsedValues
        #expect(defaults.flags.isEmpty)
        #expect(defaults.options.isEmpty)
        #expect(CLIOutputPreferences.from(values: defaults).format == .text)
        #expect(!CLIOutputPreferences.from(values: defaults).pretty)
        let logs = try program.resolve(arguments: path + ["--json-output", "--verbose"]).parsedValues
        #expect(logs.flags == ["jsonOutput", "verbose"])
        #expect(CLIOutputPreferences.from(values: logs).format == .text)
    }

    @Test
    func `common option names help and parsing remain stable`() {
        let signatures = [
            CodexBarCLI._cacheSignatureForTesting(), CodexBarCLI._costSignatureForTesting(),
            CodexBarCLI._configSetAPIKeySignatureForTesting(), CodexBarCLI._configDumpSignatureForTesting(),
            CodexBarCLI._configProviderToggleSignatureForTesting(),
        ]
        let flags: [FlagDefinition] = [
            .make(label: "verbose", names: [.short("v"), .long("verbose")], help: "Enable verbose logging"),
            .make(label: "jsonOutput", names: [.long("json-output")], help: "Emit machine-readable logs"),
            .make(label: "jsonShortcut", names: [.long("json")], help: ""),
            .make(label: "jsonOnly", names: [.long("json-only")], help: "Emit JSON only (suppress non-JSON output)"),
            .make(label: "pretty", names: [.long("pretty")], help: "Pretty-print JSON output"),
        ]
        let options: [OptionDefinition] = [
            .make(
                label: "logLevel",
                names: [.long("log-level")],
                help: "Set log level (trace|verbose|debug|info|warning|error|critical)"),
            .make(label: "format", names: [.long("format")], help: "Output format: text | json"),
        ]
        for signature in signatures {
            #expect(signature.optionGroups.isEmpty)
            for flag in flags {
                #expect(signature.flags.filter { $0.label == flag.label } == [flag])
            }
            for option in options {
                #expect(signature.options.filter { $0.label == option.label } == [option])
            }
        }
    }
}

extension CLICommonOptionsTests {
    @Test(arguments: ["usage", "cards"])
    func `shared fetch flags retain labels and command specific options`(command: String) throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let invocation = try program.resolve(arguments: [
            command, "--provider", "codex", "--account", "fixture", "--account-index", "2", "--all-accounts",
            "--source", "api", "--web-timeout", "12", "--no-credits", "--no-color", "--status", "--web",
            "--web-debug-dump-html", "--antigravity-plan-debug", "--augment-debug", "--log-level", "info", "-v",
        ])
        #expect(invocation.descriptor.signature.optionGroups.isEmpty)
        #expect(invocation.parsedValues.options == [
            "provider": ["codex"], "account": ["fixture"], "accountIndex": ["2"],
            "source": ["api"], "webTimeout": ["12"], "logLevel": ["info"],
        ])
        #expect(invocation.parsedValues.flags == [
            "allAccounts", "noCredits", "noColor", "status", "web", "webDebugDumpHtml",
            "antigravityPlanDebug", "augmentDebug", "verbose",
        ])
        let ownFlag = command == "usage" ? "--app-auto-verifier" : "--brief"
        let otherFlag = command == "usage" ? "--brief" : "--app-auto-verifier"
        #expect(try program.resolve(arguments: [command, ownFlag]).parsedValues.flags.count == 1)
        #expect(throws: CommanderProgramError.self) {
            try program.resolve(arguments: [command, otherFlag])
        }
    }

    @Test(arguments: [["hooks", "test", "quota_reached"], ["hooks", "watch"]])
    func `hooks output groups retain their own help and flags`(path: [String]) throws {
        let invocation = try Program(descriptors: CodexBarCLI.commandDescriptors()).resolve(arguments: path + [
            "--format", "json", "--json", "--json-only", "--pretty",
        ])
        #expect(invocation.parsedValues.options == ["format": ["json"]])
        #expect(invocation.parsedValues.flags == ["jsonShortcut", "jsonOnly", "pretty"])
        #expect(invocation.descriptor.signature.optionGroups.isEmpty)
        #expect(invocation.descriptor.signature.flags.first { $0.label == "jsonShortcut" }?.help == "Emit JSON")
        #expect(invocation.parsedValues.positional == (path[1] == "test" ? ["quota_reached"] : []))
    }
}
