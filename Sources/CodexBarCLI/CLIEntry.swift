import CodexBarCore
import Commander
#if os(Linux)
import CoreFoundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
enum CodexBarCLI {
    static func main() async {
        self.configureLinuxTimeZoneIfNeeded()

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
            Self.bootstrapLogging(path: invocation.path, values: invocation.parsedValues)
            switch invocation.path {
            case ["cards"], ["usage"]:
                await self.runUsageDisplay(path: invocation.path, values: invocation.parsedValues)
            case ["cost"]:
                await self.runCost(invocation.parsedValues)
            case ["sessions", "list"]:
                await self.runSessions(invocation.parsedValues)
            case ["sessions", "focus"]:
                await self.runSessionsFocus(invocation.parsedValues)
            case ["serve"]:
                await self.runServe(invocation.parsedValues)
            case let path where path.first == "config":
                self.runConfig(path: path, values: invocation.parsedValues)
            case let path where path.first == "hooks":
                await self.runHooks(path: path, values: invocation.parsedValues)
            case ["cache", "clear"]:
                self.runCacheClear(invocation.parsedValues)
            case ["cookie", "refresh"]:
                await self.runCookieRefreshWithTermination(invocation.parsedValues)
            case ["diagnose"]:
                let signalMonitor = CLITerminationSignalMonitor { signalNumber in
                    CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signalNumber)
                }
                defer { signalMonitor.cancel() }
                await self.runDiagnose(invocation.parsedValues)
            case ["guard"]:
                await self.runGuard(invocation.parsedValues)
            default:
                Self.exit(
                    code: .failure,
                    message: "Unknown command",
                    output: outputPreferences,
                    kind: .args)
            }
        } catch let error as CommanderProgramError {
            let exitCode: ExitCode = argv.first == "guard" ? .usage : .failure
            Self.exit(code: exitCode, message: error.description, output: outputPreferences, kind: .args)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: outputPreferences, kind: .runtime)
        }
    }

    private static func runUsageDisplay(path: [String], values: ParsedValues) async {
        let signalMonitor = CLITerminationSignalMonitor { signalNumber in
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signalNumber)
        }
        defer { signalMonitor.cancel() }
        switch path {
        case ["cards"]:
            await self.runCards(values)
        default:
            await self.runUsage(values)
        }
    }

    private static func runCookieRefreshWithTermination(_ values: ParsedValues) async {
        let signalMonitor = CLITerminationSignalMonitor { signalNumber in
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signalNumber)
        }
        defer { signalMonitor.cancel() }
        await self.runCookieRefresh(values)
    }

    private static func commandDescriptors() -> [CommandDescriptor] {
        let cardsSignature = CommandSignature.describe(CardsOptions())
        let usageSignature = CommandSignature.describe(UsageOptions())
        let costSignature = CommandSignature.describe(CostOptions())
        let sessionsSignature = CommandSignature.describe(SessionsOptions())
        let sessionsFocusSignature = CommandSignature.describe(SessionsFocusOptions())
        let serveSignature = CommandSignature.describe(ServeOptions())
        let configSignature = CommandSignature.describe(ConfigOptions())
        let configProviderToggleSignature = CommandSignature.describe(ConfigProviderToggleOptions())
        let configSetAPIKeySignature = CommandSignature.describe(ConfigSetAPIKeyOptions())
        let cacheSignature = CommandSignature.describe(CacheOptions())
        let diagnoseSignature = CommandSignature.describe(DiagnoseOptions())
        let hooksSignature = CommandSignature.describe(HooksOptions())
        let hooksTestSignature = CommandSignature.describe(HooksTestOptions())
        let guardSignature = CommandSignature.describe(GuardOptions())

        return [
            CommandDescriptor(
                name: "cards",
                abstract: "Print usage as a terminal card grid",
                discussion: nil,
                signature: cardsSignature),
            CommandDescriptor(
                name: "usage",
                abstract: "Print usage as text or JSON",
                discussion: nil,
                signature: usageSignature),
            CommandDescriptor(
                name: "guard",
                abstract: "Exit non-zero when a provider lacks quota headroom (for gating scripts)",
                discussion: nil,
                signature: guardSignature),
            CommandDescriptor(
                name: "cost",
                abstract: "Print local cost usage as text or JSON",
                discussion: nil,
                signature: costSignature),
            CommandDescriptor(
                name: "sessions",
                abstract: "List live Codex and Claude Code sessions",
                discussion: nil,
                signature: CommandSignature(),
                subcommands: [
                    CommandDescriptor(
                        name: "list",
                        abstract: "List live Codex and Claude Code sessions",
                        discussion: nil,
                        signature: sessionsSignature),
                    CommandDescriptor(
                        name: "focus",
                        abstract: "Focus the window for a session",
                        discussion: nil,
                        signature: sessionsFocusSignature),
                ],
                defaultSubcommandName: "list"),
            CommandDescriptor(
                name: "serve",
                abstract: "Serve usage, cost, and dashboard JSON over HTTP",
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
                        name: "providers",
                        abstract: "List provider enablement",
                        discussion: nil,
                        signature: configSignature),
                    CommandDescriptor(
                        name: "enable",
                        abstract: "Enable a provider",
                        discussion: nil,
                        signature: configProviderToggleSignature),
                    CommandDescriptor(
                        name: "disable",
                        abstract: "Disable a provider",
                        discussion: nil,
                        signature: configProviderToggleSignature),
                    CommandDescriptor(
                        name: "set-api-key",
                        abstract: "Store a provider API key",
                        discussion: nil,
                        signature: configSetAPIKeySignature),
                ],
                defaultSubcommandName: "validate"),
            CommandDescriptor(
                name: "hooks",
                abstract: "Run external commands on quota/provider events",
                discussion: nil,
                signature: CommandSignature(),
                subcommands: [
                    CommandDescriptor(
                        name: "list",
                        abstract: "List configured hooks",
                        discussion: nil,
                        signature: hooksSignature),
                    CommandDescriptor(
                        name: "enable",
                        abstract: "Enable hooks",
                        discussion: nil,
                        signature: hooksSignature),
                    CommandDescriptor(
                        name: "disable",
                        abstract: "Disable hooks",
                        discussion: nil,
                        signature: hooksSignature),
                    CommandDescriptor(
                        name: "test",
                        abstract: "Fire matching hooks for an event",
                        discussion: nil,
                        signature: hooksTestSignature),
                ],
                defaultSubcommandName: "list"),
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
            Self.cookieCommandDescriptor(),
            CommandDescriptor(
                name: "diagnose",
                abstract: "Run provider diagnostic and emit safe JSON export",
                discussion: nil,
                signature: diagnoseSignature),
        ]
    }

    private static func cookieCommandDescriptor() -> CommandDescriptor {
        CommandDescriptor(
            name: "cookie",
            abstract: "Cookie management",
            discussion: nil,
            signature: CommandSignature(),
            subcommands: [
                CommandDescriptor(
                    name: "refresh",
                    abstract: "Re-import browser cookie for a provider",
                    discussion: "Clears the provider cookie cache and re-imports through its browser-backed " +
                        "web strategy. Prompt-capable browsers require --allow-keychain-prompt.",
                    signature: CommandSignature.describe(CookieOptions())),
            ],
            defaultSubcommandName: "refresh")
    }

    // MARK: - Helpers

    static func linuxTimeZoneBootstrapIdentifier(
        currentValue: String?,
        localTimeReadable: Bool,
        resolvedLocalTimePath: String?) -> String?
    {
        guard currentValue == nil, localTimeReadable else { return nil }
        return self.linuxTimeZoneIdentifier(from: resolvedLocalTimePath)
    }

    static func linuxTimeZoneIdentifier(from resolvedLocalTimePath: String?) -> String? {
        guard let resolvedLocalTimePath,
              let marker = resolvedLocalTimePath.range(of: "/zoneinfo/")
        else { return nil }

        var identifier = String(resolvedLocalTimePath[marker.upperBound...])
        for prefix in ["posix/", "right/"] where identifier.hasPrefix(prefix) {
            identifier.removeFirst(prefix.count)
        }

        let components = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return identifier
    }

    private static func configureLinuxTimeZoneIfNeeded() {
        #if os(Linux)
        let currentValue = getenv("TZ").map { String(cString: $0) }
        let localTimeReadable = access("/etc/localtime", R_OK) == 0
        let resolvedLocalTimePath = self.resolvedLinuxLocalTimePath()
        guard let identifier = self.linuxTimeZoneBootstrapIdentifier(
            currentValue: currentValue,
            localTimeReadable: localTimeReadable,
            resolvedLocalTimePath: resolvedLocalTimePath)
        else { return }

        guard self.primeCoreFoundationTimeZone(identifier: identifier, filePath: "/etc/localtime") else { return }

        // FoundationEssentials reads the IANA identifier while legacy formatters use the
        // CoreFoundation cache primed above when /usr/share/zoneinfo is unavailable.
        setenv("TZ", identifier, 0)
        #endif
    }

    static func primeCoreFoundationTimeZone(identifier: String, filePath: String) -> Bool {
        #if os(Linux)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)), !data.isEmpty else { return false }
        guard let name = identifier.withCString({
            CFStringCreateWithCString(nil, $0, CFStringBuiltInEncodings.UTF8.rawValue)
        }) else { return false }
        guard let timeZoneData = data.withUnsafeBytes({ rawBuffer -> CFData? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return CFDataCreate(nil, bytes.baseAddress, bytes.count)
        }) else { return false }
        return CFTimeZoneCreate(nil, name, timeZoneData) != nil
        #else
        return false
        #endif
    }

    private static func resolvedLinuxLocalTimePath() -> String? {
        #if os(Linux)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath("/etc/localtime", &buffer) != nil else { return nil }
        return buffer.withUnsafeBufferPointer { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
        #else
        return nil
        #endif
    }

    private static func bootstrapLogging(path: [String], values: ParsedValues) {
        CodexBarLog.bootstrapIfNeeded(self.loggingConfiguration(path: path, values: values))
    }

    static func loggingConfiguration(path: [String], values: ParsedValues) -> CodexBarLog.Configuration {
        let isJSON = values.flags.contains("jsonOutput") || values.flags.contains("jsonOnly")
        let verbose = values.flags.contains("verbose")
        let rawLevel = values.options["logLevel"]?.last
        let level = Self.resolvedLogLevel(verbose: verbose, rawLevel: rawLevel)
        let destination: CodexBarLog.Destination = path == ["diagnose"] ? .discard : .stderr
        return .init(destination: destination, level: level, json: isJSON)
    }

    static func resolvedLogLevel(verbose: Bool, rawLevel: String?) -> CodexBarLog.Level {
        CodexBarLog.parseLevel(rawLevel) ?? (verbose ? .debug : .error)
    }

    static func effectiveArgv(_ argv: [String]) -> [String] {
        guard let first = argv.first else { return ["usage"] }
        if first.hasPrefix("-") {
            return ["usage"] + argv
        }
        return argv
    }
}
