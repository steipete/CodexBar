import CodexBarCore
import Commander
#if canImport(AppKit)
import AppKit
#endif
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

        // Fast path: global help/version before building descriptors.
        if let helpIndex = argv.firstIndex(where: { $0 == "-h" || $0 == "--help" }) {
            let command = helpIndex == 0 ? argv.dropFirst().first : argv.first
            Self.printHelp(for: command)
        }
        if argv.contains("-V") || argv.contains("--version") {
            Self.printVersion()
        }

        let usageSignature = CommandSignature
            .describe(UsageOptions())

        let costSignature = CommandSignature
            .describe(CostOptions())

        let descriptors: [CommandDescriptor] = [
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
        ]

        let program = Program(descriptors: descriptors)

        do {
            let invocation = try program.resolve(argv: argv)
            Self.bootstrapLogging(values: invocation.parsedValues)
            switch invocation.descriptor.name {
            case "usage":
                await self.runUsage(invocation.parsedValues)
            case "cost":
                await self.runCost(invocation.parsedValues)
            default:
                Self.exit(code: .failure, message: "Unknown command")
            }
        } catch let error as CommanderProgramError {
            Self.exit(code: .failure, message: error.description)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription)
        }
    }

    // MARK: - Commands

    private static func runUsage(_ values: ParsedValues) async {
        let provider = Self.decodeProvider(from: values)
        let format = Self.decodeFormat(from: values)
        let includeCredits = format == .json ? true : !values.flags.contains("noCredits")
        let includeStatus = values.flags.contains("status")
        let pretty = values.flags.contains("pretty")
        let sourceModeRaw = values.options["source"]?.last
        let parsedSourceMode = Self.decodeSourceMode(from: values)
        if sourceModeRaw != nil, parsedSourceMode == nil {
            Self.exit(code: .failure, message: "Error: --source must be auto|web|cli|oauth.")
        }
        let sourceMode = parsedSourceMode ?? .auto
        let antigravityPlanDebug = values.flags.contains("antigravityPlanDebug")
        let augmentDebug = values.flags.contains("augmentDebug")
        let webDebugDumpHTML = values.flags.contains("webDebugDumpHtml")
        let webTimeout = Self.decodeWebTimeout(from: values) ?? 60
        let verbose = values.flags.contains("verbose")
        let noColor = values.flags.contains("noColor")
        let useColor = Self.shouldUseColor(noColor: noColor, format: format)
        let resetStyle = Self.resetTimeDisplayStyleFromDefaults()
        let fetcher = UsageFetcher()
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let claudeFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)

        #if !os(macOS)
        if sourceMode.usesWeb {
            Self.exit(code: .failure, message: "Error: --source web/auto is only supported on macOS.")
        }
        #endif

        var sections: [String] = []
        var payload: [ProviderPayload] = []
        var exitCode: ExitCode = .success

        let fetchContext = ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: includeCredits,
            webTimeout: webTimeout,
            webDebugDumpHTML: webDebugDumpHTML,
            verbose: verbose,
            env: ProcessInfo.processInfo.environment,
            settings: nil,
            fetcher: fetcher,
            claudeFetcher: claudeFetcher,
            browserDetection: browserDetection)

        for p in provider.asList {
            let status = includeStatus ? await Self.fetchStatus(for: p) : nil
            var antigravityPlanInfo: AntigravityPlanInfoSummary?
            let outcome = await Self.fetchProviderUsage(
                provider: p,
                context: fetchContext)
            if verbose {
                Self.printFetchAttempts(provider: p, attempts: outcome.attempts)
            }

            switch outcome.result {
            case let .success(result):
                var dashboard = result.dashboard
                if antigravityPlanDebug, p == .antigravity {
                    antigravityPlanInfo = try? await AntigravityStatusProbe().fetchPlanInfoSummary()
                    if format == .text, let info = antigravityPlanInfo {
                        Self.printAntigravityPlanInfo(info)
                    }
                }

                if augmentDebug, p == .augment {
                    #if os(macOS)
                    let dump = await AugmentStatusProbe.latestDumps()
                    if format == .text, !dump.isEmpty {
                        Self.writeStderr("Augment API responses:\n\(dump)\n")
                    }
                    #endif
                }

                if dashboard == nil, format == .json, p == .codex {
                    dashboard = Self.loadOpenAIDashboardIfAvailable(usage: result.usage, fetcher: fetcher)
                }

                let descriptor = ProviderDescriptorRegistry.descriptor(for: p)
                let shouldDetectVersion = descriptor.cli.versionDetector != nil
                    && result.strategyKind != .webDashboard
                let version = Self.normalizeVersion(
                    raw: shouldDetectVersion ? Self.detectVersion(for: p, browserDetection: browserDetection) : nil)
                let source = result.sourceLabel
                let header = Self.makeHeader(provider: p, version: version, source: source)

                switch format {
                case .text:
                    var text = CLIRenderer.renderText(
                        provider: p,
                        snapshot: result.usage,
                        credits: result.credits,
                        context: RenderContext(
                            header: header,
                            status: status,
                            useColor: useColor,
                            resetStyle: resetStyle))
                    if let dashboard, p == .codex, sourceMode.usesWeb {
                        text += "\n" + Self.renderOpenAIWebDashboardText(dashboard)
                    }
                    sections.append(text)
                case .json:
                    payload.append(ProviderPayload(
                        provider: p,
                        version: version,
                        source: source,
                        status: status,
                        usage: result.usage,
                        credits: result.credits,
                        antigravityPlanInfo: antigravityPlanInfo,
                        openaiDashboard: dashboard))
                }
            case let .failure(error):
                exitCode = Self.mapError(error)
                Self.printError(error)
            }
        }

        switch format {
        case .text:
            if !sections.isEmpty {
                print(sections.joined(separator: "\n\n"))
            }
        case .json:
            if !payload.isEmpty {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
                if let data = try? encoder.encode(payload),
                   let output = String(data: data, encoding: .utf8)
                {
                    print(output)
                }
            }
        }

        Self.exit(code: exitCode)
    }

    // MARK: - Helpers

    private static func bootstrapLogging(values: ParsedValues) {
        let isJSON = values.flags.contains("jsonOutput")
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

    static func decodeProvider(from values: ParsedValues) -> ProviderSelection {
        let rawOverride = values.options["provider"]?.last
        return Self.providerSelection(rawOverride: rawOverride, enabled: Self.enabledProvidersFromDefaults())
    }

    static func providerSelection(rawOverride: String?, enabled: [UsageProvider]) -> ProviderSelection {
        if let rawOverride, let parsed = ProviderSelection(argument: rawOverride) {
            return parsed
        }
        if enabled.count >= 3 { return .all }
        if enabled.count == 2 {
            let enabledSet = Set(enabled)
            let primary = Set(ProviderDescriptorRegistry.all.filter(\.metadata.isPrimaryProvider).map(\.id))
            if !primary.isEmpty, enabledSet == primary {
                return .both
            }
            return .custom(enabled)
        }
        if let first = enabled.first { return ProviderSelection(provider: first) }
        return .single(.codex)
    }

    static func decodeFormat(from values: ParsedValues) -> OutputFormat {
        if let raw = values.options["format"]?.last, let parsed = OutputFormat(argument: raw) {
            return parsed
        }
        if values.flags.contains("jsonShortcut") || values.flags.contains("json") { return .json }
        return .text
    }

    static func shouldUseColor(noColor: Bool, format: OutputFormat) -> Bool {
        guard format == .text else { return false }
        if noColor { return false }
        let env = ProcessInfo.processInfo.environment
        if env["TERM"]?.lowercased() == "dumb" { return false }
        return isatty(STDOUT_FILENO) == 1
    }

    private static func detectVersion(for provider: UsageProvider, browserDetection: BrowserDetection) -> String? {
        ProviderDescriptorRegistry.descriptor(for: provider).cli.versionDetector?(browserDetection)
    }

    private static func normalizeVersion(raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let match = raw.range(of: #"(\d+(?:\.\d+)+)"#, options: .regularExpression) {
            return String(raw[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeHeader(provider: UsageProvider, version: String?, source: String) -> String {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        if let version, !version.isEmpty {
            return "\(name) \(version) (\(source))"
        }
        return "\(name) (\(source))"
    }

    private static func printFetchAttempts(provider: UsageProvider, attempts: [ProviderFetchAttempt]) {
        guard !attempts.isEmpty else { return }
        self.writeStderr("[\(provider.rawValue)] fetch strategies:\n")
        for attempt in attempts {
            let kindLabel = Self.fetchKindLabel(attempt.kind)
            var line = "  - \(attempt.strategyID) (\(kindLabel))"
            line += attempt.wasAvailable ? " available" : " unavailable"
            if let error = attempt.errorDescription, !error.isEmpty {
                line += " error=\(error)"
            }
            self.writeStderr("\(line)\n")
        }
    }

    private static func fetchKindLabel(_ kind: ProviderFetchKind) -> String {
        switch kind {
        case .cli: "cli"
        case .web: "web"
        case .oauth: "oauth"
        case .apiToken: "api"
        case .localProbe: "local"
        case .webDashboard: "web"
        }
    }

    private static func fetchStatus(for provider: UsageProvider) async -> ProviderStatusPayload? {
        let urlString = ProviderDescriptorRegistry.descriptor(for: provider).metadata.statusPageURL
        guard let urlString,
              let baseURL = URL(string: urlString) else { return nil }
        do {
            return try await StatusFetcher.fetch(from: baseURL)
        } catch {
            return ProviderStatusPayload(
                indicator: .unknown,
                description: error.localizedDescription,
                updatedAt: nil,
                url: urlString)
        }
    }

    private static func enabledProvidersFromDefaults() -> [UsageProvider] {
        // Prefer the app's defaults domain so CLI mirrors in-app toggles.
        let domains = [
            "com.steipete.codexbar",
            "com.steipete.codexbar.debug",
        ]

        var toggles: [String: Bool] = [:]
        for domain in domains {
            if let dict = UserDefaults(suiteName: domain)?.dictionary(forKey: "providerToggles") as? [String: Bool],
               !dict.isEmpty
            {
                toggles = dict
                break
            }
        }

        if toggles.isEmpty {
            toggles = UserDefaults.standard.dictionary(forKey: "providerToggles") as? [String: Bool] ?? [:]
        }

        return ProviderDescriptorRegistry.all.compactMap { descriptor in
            let meta = descriptor.metadata
            let isOn = toggles[meta.cliName] ?? meta.defaultEnabled
            return isOn ? descriptor.id : nil
        }
    }

    private static func resetTimeDisplayStyleFromDefaults() -> ResetTimeDisplayStyle {
        let domains = [
            "com.steipete.codexbar",
            "com.steipete.codexbar.debug",
        ]
        for domain in domains {
            if let value = UserDefaults(suiteName: domain)?.object(forKey: "resetTimesShowAbsolute") as? Bool {
                return value ? .absolute : .countdown
            }
        }
        let fallback = UserDefaults.standard.object(forKey: "resetTimesShowAbsolute") as? Bool ?? false
        return fallback ? .absolute : .countdown
    }

    private static func fetchProviderUsage(
        provider: UsageProvider,
        context: ProviderFetchContext) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        if !descriptor.fetchPlan.sourceModes.contains(context.sourceMode) {
            let error = SourceSelectionError.unsupported(
                provider: descriptor.cli.name,
                source: context.sourceMode)
            return ProviderFetchOutcome(result: .failure(error), attempts: [])
        }
        return await descriptor.fetchOutcome(context: context)
    }

    private enum SourceSelectionError: LocalizedError {
        case unsupported(provider: String, source: ProviderSourceMode)

        var errorDescription: String? {
            switch self {
            case let .unsupported(provider, source):
                "Source '\(source.rawValue)' is not supported for \(provider)."
            }
        }
    }

    private static func loadOpenAIDashboardIfAvailable(
        usage: UsageSnapshot,
        fetcher: UsageFetcher) -> OpenAIDashboardSnapshot?
    {
        guard let cache = OpenAIDashboardCacheStore.load() else { return nil }
        let codexEmail = (usage.accountEmail(for: .codex) ?? fetcher.loadAccountInfo().email)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let codexEmail, !codexEmail.isEmpty else { return nil }
        if cache.accountEmail.lowercased() != codexEmail.lowercased() { return nil }
        if cache.snapshot.dailyBreakdown.isEmpty, !cache.snapshot.creditEvents.isEmpty {
            return OpenAIDashboardSnapshot(
                signedInEmail: cache.snapshot.signedInEmail,
                codeReviewRemainingPercent: cache.snapshot.codeReviewRemainingPercent,
                creditEvents: cache.snapshot.creditEvents,
                dailyBreakdown: OpenAIDashboardSnapshot.makeDailyBreakdown(
                    from: cache.snapshot.creditEvents,
                    maxDays: 30),
                usageBreakdown: cache.snapshot.usageBreakdown,
                creditsPurchaseURL: cache.snapshot.creditsPurchaseURL,
                updatedAt: cache.snapshot.updatedAt)
        }
        return cache.snapshot
    }

    private static func decodeWebTimeout(from values: ParsedValues) -> TimeInterval? {
        if let raw = values.options["webTimeout"]?.last, let seconds = Double(raw) {
            return seconds
        }
        return nil
    }

    private static func decodeSourceMode(from values: ParsedValues) -> ProviderSourceMode? {
        if values.flags.contains("web") {
            return .web
        }
        guard let raw = values.options["source"]?.last?.lowercased() else { return nil }
        return ProviderSourceMode(rawValue: raw)
    }

    private static func renderOpenAIWebDashboardText(_ dash: OpenAIDashboardSnapshot) -> String {
        var lines: [String] = []
        if let email = dash.signedInEmail, !email.isEmpty {
            lines.append("Web session: \(email)")
        }
        if let remaining = dash.codeReviewRemainingPercent {
            let percent = Int(remaining.rounded())
            lines.append("Code review: \(percent)% remaining")
        }
        if let first = dash.creditEvents.first {
            let day = first.date.formatted(date: .abbreviated, time: .omitted)
            lines.append("Web history: \(dash.creditEvents.count) events (latest \(day))")
        } else {
            lines.append("Web history: none")
        }
        return lines.joined(separator: "\n")
    }

    static func mapError(_ error: Error) -> ExitCode {
        switch error {
        case TTYCommandRunner.Error.binaryNotFound,
             CodexStatusProbeError.codexNotInstalled,
             ClaudeUsageError.claudeNotInstalled,
             GeminiStatusProbeError.geminiNotInstalled:
            ExitCode(2)
        case CodexStatusProbeError.timedOut,
             TTYCommandRunner.Error.timedOut,
             GeminiStatusProbeError.timedOut,
             CostUsageError.timedOut:
            ExitCode(4)
        case ClaudeUsageError.parseFailed,
             ClaudeUsageError.oauthFailed,
             CostUsageError.unsupportedProvider,
             UsageError.decodeFailed,
             UsageError.noRateLimitsFound,
             GeminiStatusProbeError.parseFailed:
            ExitCode(3)
        default:
            .failure
        }
    }

    static func printError(_ error: Error) {
        self.writeStderr("Error: \(error.localizedDescription)\n")
    }

    private static func printAntigravityPlanInfo(_ info: AntigravityPlanInfoSummary) {
        let fields: [(String, String?)] = [
            ("planName", info.planName),
            ("planDisplayName", info.planDisplayName),
            ("displayName", info.displayName),
            ("productName", info.productName),
            ("planShortName", info.planShortName),
        ]
        self.writeStderr("Antigravity plan info:\n")
        for (label, value) in fields {
            guard let value, !value.isEmpty else { continue }
            self.writeStderr("  \(label): \(value)\n")
        }
    }

    static func exit(code: ExitCode, message: String? = nil) -> Never {
        if let message {
            self.writeStderr("\(message)\n")
        }
        Self.platformExit(code.rawValue)
    }

    static func writeStderr(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    static func printVersion() -> Never {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            print("CodexBar \(version)")
        } else {
            print("CodexBar")
        }
        Self.platformExit(0)
    }

    static func printHelp(for command: String?) -> Never {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        switch command {
        case "usage":
            print(Self.usageHelp(version: version))
        case "cost":
            print(Self.costHelp(version: version))
        default:
            print(Self.rootHelp(version: version))
        }
        Self.platformExit(0)
    }

    private static func platformExit(_ code: Int32) -> Never {
        #if canImport(Darwin)
        Darwin.exit(code)
        #else
        Glibc.exit(code)
        #endif
    }

    static func usageHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar usage [--format text|json]
                       [--json]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                       [--provider \(ProviderHelp.list)]
                       [--no-credits] [--no-color] [--pretty] [--status] [--source <auto|web|cli|oauth>]
                       [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug] [--augment-debug]

        Description:
          Print usage from enabled providers as text (default) or JSON. Honors your in-app toggles.
          Output format: use --json (or --format json) for JSON on stdout; use --json-output for JSON logs on stderr.
          When --source is auto/web (macOS only), CodexBar uses browser cookies to fetch web-backed data:
          - Codex: OpenAI web dashboard (usage limits, credits remaining, code review remaining, usage breakdown).
            Auto falls back to Codex CLI only when cookies are missing.
          - Claude: claude.ai API.
            Auto falls back to Claude CLI only when cookies are missing.

        Global flags:
          -h, --help      Show help
          -V, --version   Show version
          -v, --verbose   Enable verbose logging
          --no-color      Disable ANSI colors in text output
          --log-level <trace|verbose|debug|info|warning|error|critical>
          --json-output   Emit machine-readable logs (JSONL) to stderr

        Examples:
          codexbar usage
          codexbar usage --provider claude
          codexbar usage --provider gemini
          codexbar usage --format json --provider all --pretty
          codexbar usage --provider all --json
          codexbar usage --status
          codexbar usage --provider codex --source web --format json --pretty
        """
    }

    static func rootHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar [--format text|json]
                  [--json]
                  [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                  [--provider \(ProviderHelp.list)]
                  [--no-credits] [--no-color] [--pretty] [--status] [--source <auto|web|cli|oauth>]
                  [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug] [--augment-debug]
          codexbar cost [--format text|json]
                       [--json]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                       [--provider \(ProviderHelp.list)] [--no-color] [--pretty] [--refresh]

        Global flags:
          -h, --help      Show help
          -V, --version   Show version
          -v, --verbose   Enable verbose logging
          --no-color      Disable ANSI colors in text output
          --log-level <trace|verbose|debug|info|warning|error|critical>
          --json-output   Emit machine-readable logs (JSONL) to stderr

        Examples:
          codexbar
          codexbar --format json --provider all --pretty
          codexbar --provider all --json
          codexbar --provider gemini
          codexbar cost --provider claude --format json --pretty
        """
    }
}

// MARK: - Options & decoding helpers

private struct UsageOptions: CommanderParsable {
    private static let sourceHelp: String = {
        #if os(macOS)
        "Data source: auto | web | cli | oauth (auto uses web then falls back on missing cookies)"
        #else
        "Data source: auto | web | cli | oauth (web/auto are macOS only)"
        #endif
    }()

    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(
        name: .long("provider"),
        help: ProviderHelp.optionHelp)
    var provider: ProviderSelection?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("no-credits"), help: "Skip Codex credits line")
    var noCredits: Bool = false

    @Flag(name: .long("no-color"), help: "Disable ANSI colors in text output")
    var noColor: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long("status"), help: "Fetch and include provider status")
    var status: Bool = false

    @Flag(name: .long("web"), help: "Alias for --source web")
    var web: Bool = false

    @Option(name: .long("source"), help: Self.sourceHelp)
    var source: String?

    @Option(name: .long("web-timeout"), help: "Web fetch timeout (seconds) (Codex only; source=auto|web)")
    var webTimeout: Double?

    @Flag(name: .long("web-debug-dump-html"), help: "Dump HTML snapshots to /tmp when Codex dashboard data is missing")
    var webDebugDumpHtml: Bool = false

    @Flag(name: .long("antigravity-plan-debug"), help: "Emit Antigravity planInfo fields (debug)")
    var antigravityPlanDebug: Bool = false

    @Flag(name: .long("augment-debug"), help: "Emit Augment API responses (debug)")
    var augmentDebug: Bool = false
}

enum ProviderSelection: Sendable, ExpressibleFromArgument {
    case single(UsageProvider)
    case both
    case all
    case custom([UsageProvider])

    init?(argument: String) {
        let normalized = argument.lowercased()
        switch normalized {
        case "both":
            self = .both
        case "all":
            self = .all
        default:
            if let provider = ProviderDescriptorRegistry.cliNameMap[normalized] {
                self = .single(provider)
            } else {
                return nil
            }
        }
    }

    init(provider: UsageProvider) {
        self = .single(provider)
    }

    var asList: [UsageProvider] {
        switch self {
        case let .single(provider):
            return [provider]
        case .both:
            let primary = ProviderDescriptorRegistry.all.filter(\.metadata.isPrimaryProvider)
            if !primary.isEmpty {
                return primary.map(\.id)
            }
            return ProviderDescriptorRegistry.all.prefix(2).map(\.id)
        case .all:
            return ProviderDescriptorRegistry.all.map(\.id)
        case let .custom(providers):
            return providers
        }
    }
}

#if DEBUG
extension CodexBarCLI {
    static func _usageSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(UsageOptions())
    }

    static func _decodeFormatForTesting(from values: ParsedValues) -> OutputFormat {
        self.decodeFormat(from: values)
    }
}
#endif

enum OutputFormat: String, Sendable, ExpressibleFromArgument {
    case text
    case json

    init?(argument: String) {
        switch argument.lowercased() {
        case "text": self = .text
        case "json": self = .json
        default: return nil
        }
    }
}

enum ProviderHelp {
    static var list: String {
        let names = ProviderDescriptorRegistry.all.map(\.cli.name)
        return (names + ["both", "all"]).joined(separator: "|")
    }

    static var optionHelp: String {
        "Provider to query: \(self.list)"
    }
}

struct ProviderPayload: Encodable {
    let provider: String
    let version: String?
    let source: String
    let status: ProviderStatusPayload?
    let usage: UsageSnapshot
    let credits: CreditsSnapshot?
    let antigravityPlanInfo: AntigravityPlanInfoSummary?
    let openaiDashboard: OpenAIDashboardSnapshot?

    init(
        provider: UsageProvider,
        version: String?,
        source: String,
        status: ProviderStatusPayload?,
        usage: UsageSnapshot,
        credits: CreditsSnapshot?,
        antigravityPlanInfo: AntigravityPlanInfoSummary?,
        openaiDashboard: OpenAIDashboardSnapshot?)
    {
        self.provider = provider.rawValue
        self.version = version
        self.source = source
        self.status = status
        self.usage = usage
        self.credits = credits
        self.antigravityPlanInfo = antigravityPlanInfo
        self.openaiDashboard = openaiDashboard
    }
}

struct ProviderStatusPayload: Encodable {
    let indicator: ProviderStatusIndicator
    let description: String?
    let updatedAt: Date?
    let url: String

    enum ProviderStatusIndicator: String, Encodable {
        case none
        case minor
        case major
        case critical
        case maintenance
        case unknown

        var label: String {
            switch self {
            case .none: "Operational"
            case .minor: "Partial outage"
            case .major: "Major outage"
            case .critical: "Critical issue"
            case .maintenance: "Maintenance"
            case .unknown: "Status unknown"
            }
        }
    }

    var descriptionSuffix: String {
        guard let description, !description.isEmpty else { return "" }
        return " – \(description)"
    }
}

private enum StatusFetcher {
    static func fetch(from baseURL: URL) async throws -> ProviderStatusPayload {
        let apiURL = baseURL.appendingPathComponent("api/v2/status.json")
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)

        struct Response: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String?
            }

            struct Page: Decodable {
                let updatedAt: Date?

                private enum CodingKeys: String, CodingKey {
                    case updatedAt = "updated_at"
                }
            }

            let page: Page?
            let status: Status
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }

        let response = try decoder.decode(Response.self, from: data)
        let indicator = ProviderStatusPayload.ProviderStatusIndicator(rawValue: response.status.indicator) ?? .unknown
        return ProviderStatusPayload(
            indicator: indicator,
            description: response.status.description,
            updatedAt: response.page?.updatedAt,
            url: baseURL.absoluteString)
    }
}
