import CodexBarCore
import Commander
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
enum CodexBarCLI {
    static func main() async {
        let rawArgv = Array(CommandLine.arguments.dropFirst())
        let argv = Self.effectiveArgv(rawArgv)
        let outputPreferences = CLIOutputPreferences.from(argv: argv)

        // Fast path: global help/version before building descriptors.
        if let helpIndex = argv.firstIndex(where: { $0 == "-h" || $0 == "--help" }) {
            let command = helpIndex == 0 ? argv.dropFirst().first : argv.first
            Self.printHelp(for: command)
        }
        if argv.contains("-V") || argv.contains("--version") {
            Self.printVersion()
        }

        let program = Program(descriptors: Self.commandDescriptors())

        do {
            let invocation = try program.resolve(argv: argv)
            Self.bootstrapLogging(values: invocation.parsedValues)
            switch invocation.path {
            case ["usage"]:
                await self.runUsage(invocation.parsedValues)
            case ["cost"]:
                await self.runCost(invocation.parsedValues)
            case ["serve"]:
                await self.runServe(invocation.parsedValues)
            case ["config", "validate"]:
                self.runConfigValidate(invocation.parsedValues)
            case ["config", "dump"]:
                self.runConfigDump(invocation.parsedValues)
            case ["config", "set-api-key"]:
                self.runConfigSetAPIKey(invocation.parsedValues)
            case ["cache", "clear"]:
                self.runCacheClear(invocation.parsedValues)
            default:
                Self.exit(
                    code: .failure,
                    message: "Unknown command",
                    output: outputPreferences,
                    kind: .args)
            }
        } catch let error as CommanderProgramError {
            Self.exit(code: .failure, message: error.description, output: outputPreferences, kind: .args)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: outputPreferences, kind: .runtime)
        }
    }

    private static func commandDescriptors() -> [CommandDescriptor] {
        let usageSignature = CommandSignature.describe(UsageOptions())
        let costSignature = CommandSignature.describe(CostOptions())
        let serveSignature = CommandSignature.describe(ServeOptions())
        let configSignature = CommandSignature.describe(ConfigOptions())
        let configSetAPIKeySignature = CommandSignature.describe(ConfigSetAPIKeyOptions())
        let cacheSignature = CommandSignature.describe(CacheOptions())

        return [
            CommandDescriptor(
                name: "usage",
                abstract: "Print usage as text or JSON",
                discussion: nil,
                signature: usageSignature),
            CommandDescriptor(
                name: "cost",
                abstract: "Print local cost usage as text or JSON",
                discussion: nil,
                signature: costSignature),
            CommandDescriptor(
                name: "serve",
                abstract: "Serve usage and cost JSON over localhost HTTP",
                discussion: nil,
                signature: serveSignature),
            CommandDescriptor(
                name: "config",
                abstract: "Config utilities",
                discussion: nil,
                signature: CommandSignature(),
                subcommands: [
                    CommandDescriptor(
                        name: "validate",
                        abstract: "Validate config file",
                        discussion: nil,
                        signature: configSignature),
                    CommandDescriptor(
                        name: "dump",
                        abstract: "Print normalized config JSON",
                        discussion: nil,
                        signature: configSignature),
                    CommandDescriptor(
                        name: "set-api-key",
                        abstract: "Store a provider API key",
                        discussion: nil,
                        signature: configSetAPIKeySignature),
                ],
                defaultSubcommandName: "validate"),
            CommandDescriptor(
                name: "cache",
                abstract: "Cache management",
                discussion: nil,
                signature: CommandSignature(),
                subcommands: [
                    CommandDescriptor(
                        name: "clear",
                        abstract: "Clear cached data (cookies, cost, or all)",
                        discussion: nil,
                        signature: cacheSignature),
                ],
                defaultSubcommandName: "clear"),
        ]
    }

    // MARK: - Helpers

    private static func bootstrapLogging(values: ParsedValues) {
        let isJSON = values.flags.contains("jsonOutput") || values.flags.contains("jsonOnly")
        let verbose = values.flags.contains("verbose")
        let rawLevel = values.options["logLevel"]?.last
        let level = Self.resolvedLogLevel(verbose: verbose, rawLevel: rawLevel)
        CodexBarLog.bootstrapIfNeeded(.init(destination: .stderr, level: level, json: isJSON))
    }

    static func resolvedLogLevel(verbose: Bool, rawLevel: String?) -> CodexBarLog.Level {
        CodexBarLog.parseLevel(rawLevel) ?? (verbose ? .debug : .error)
    }

    static func effectiveArgv(_ argv: [String]) -> [String] {
        guard let first = argv.first else { return ["usage"] }
        if first.hasPrefix("-") { return ["usage"] + argv }
        return argv
    }
}
