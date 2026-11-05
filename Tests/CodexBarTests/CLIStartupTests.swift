import Commander
import Testing
@testable import CodexBarCLI

struct CLIStartupTests {
    @Test
    func `startup constructs only the selected command family`() {
        for command in CodexBarCLI.commandDescriptors() {
            let selected = CodexBarCLI.commandDescriptors(for: command.name)
            #expect(selected.map(\.name) == [command.name])
        }
    }

    @Test
    func `selected commands preserve nested parsing and defaults`() throws {
        let complete = Program(descriptors: CodexBarCLI.commandDescriptors())
        let arguments = [
            ["usage", "--provider", "codex", "--json"],
            ["config", "providers", "--json"],
            ["config", "--json"],
            ["config", "preferences", "export", "--json"],
            ["sessions"],
            ["hooks"],
            ["plugins", "fetch", "fixture-meter", "--json"],
        ]
        for argv in arguments {
            let expected = try complete.resolve(arguments: argv)
            let selected = Program(descriptors: CodexBarCLI.commandDescriptors(for: argv.first))
            let actual = try selected.resolve(arguments: argv)
            #expect(actual.path == expected.path)
            #expect(actual.parsedValues.positional == expected.parsedValues.positional)
            #expect(actual.parsedValues.options == expected.parsedValues.options)
            #expect(actual.parsedValues.flags == expected.parsedValues.flags)
        }
    }

    @Test
    func `unknown commands preserve the router diagnostic`() {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors(for: "missing-command"))
        #expect(throws: CommanderProgramError.unknownCommand("missing-command")) {
            try program.resolve(arguments: ["missing-command"])
        }
    }
}
