import CodexBarCore
import Commander
import Testing
@testable import CodexBarCLI

@Suite
struct CLIArgumentParsingTests {
    @Test
    func jsonShortcutDoesNotEnableJsonLogs() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--json"])

        #expect(parsed.flags.contains("jsonShortcut"))
        #expect(!parsed.flags.contains("jsonOutput"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func jsonOutputFlagEnablesJsonLogs() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--json-output"])

        #expect(parsed.flags.contains("jsonOutput"))
        #expect(!parsed.flags.contains("jsonShortcut"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .text)
    }

    @Test
    func logLevelAndVerboseAreParsed() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--log-level", "info", "--verbose"])

        #expect(parsed.flags.contains("verbose"))
        #expect(parsed.options["logLevel"] == ["info"])
    }

    @Test
    func resolvedLogLevelDefaultsToError() {
        #expect(CodexBarCLI.resolvedLogLevel(verbose: false, rawLevel: nil) == .error)
        #expect(CodexBarCLI.resolvedLogLevel(verbose: true, rawLevel: nil) == .debug)
        #expect(CodexBarCLI.resolvedLogLevel(verbose: false, rawLevel: "info") == .info)
    }

    @Test
    func formatOptionOverridesJsonShortcut() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--json", "--format", "text"])

        #expect(parsed.flags.contains("jsonShortcut"))
        #expect(parsed.options["format"] == ["text"])
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .text)
    }

    @Test
    func jsonOnlyEnablesJsonFormat() throws {
        let signature = CodexBarCLI._usageSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--json-only"])

        #expect(parsed.flags.contains("jsonOnly"))
        #expect(!parsed.flags.contains("jsonOutput"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }
}
