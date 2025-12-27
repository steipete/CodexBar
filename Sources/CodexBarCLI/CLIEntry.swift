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
            .withStandardRuntimeFlags()

        let descriptors: [CommandDescriptor] = [
            CommandDescriptor(
                name: "usage",
                abstract: "Print usage as text or JSON",
                discussion: nil,
                signature: usageSignature),
        ]

        let program = Program(descriptors: descriptors)

        do {
            let invocation = try program.resolve(argv: argv)
            Self.bootstrapLogging(values: invocation.parsedValues)
            switch invocation.descriptor.name {
            case "usage":
                await self.runUsage(invocation.parsedValues)
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
        #if os(macOS)
        let sourceMode = parsedSourceMode ?? .auto
        #else
        let sourceMode = parsedSourceMode ?? .cli
        #endif
        let antigravityPlanDebug = values.flags.contains("antigravityPlanDebug")
        let webDebugDumpHTML = values.flags.contains("webDebugDumpHtml")
        let webTimeout = Self.decodeWebTimeout(from: values) ?? 60
        let verbose = values.flags.contains("verbose")
        let useColor = Self.shouldUseColor()
        let fetcher = UsageFetcher()
        #if os(macOS)
        let claudeSource: ClaudeUsageDataSource = switch sourceMode {
        case .oauth: .oauth
        case .cli: .cli
        case .web, .auto: .cli
        }
        #else
        // On Linux, prefer OAuth (reads ~/.claude/.credentials.json) since PTY-based CLI capture
        // has reliability issues on Linux terminals.
        let claudeSource: ClaudeUsageDataSource = switch sourceMode {
        case .oauth: .oauth
        case .cli, .web, .auto: .oauth
        }
        #endif
        let claudeFetcher = ClaudeUsageFetcher(dataSource: claudeSource)

        #if !os(macOS)
        if sourceMode.usesWeb {
            Self.exit(code: .failure, message: "Error: --source web/auto is only supported on macOS.")
        }
        #endif

        var sections: [String] = []
        var payload: [ProviderPayload] = []
        var exitCode: ExitCode = .success

        let fetchContext = ProviderFetchContext(
            includeCredits: includeCredits,
            sourceMode: sourceMode,
            webTimeout: webTimeout,
            webDebugDumpHTML: webDebugDumpHTML,
            verbose: verbose,
            fetcher: fetcher,
            claudeFetcher: claudeFetcher)

        for p in provider.asList {
            let status = includeStatus ? await Self.fetchStatus(for: p) : nil
            var antigravityPlanInfo: AntigravityPlanInfoSummary?
            var dashboard: OpenAIDashboardSnapshot?
            var sourceOverride: String?
            var fetchResult: Result<(usage: UsageSnapshot, credits: CreditsSnapshot?), Error>

            let outcome = await Self.fetchProviderUsage(
                provider: p,
                context: fetchContext)
            fetchResult = outcome.result
            dashboard = outcome.dashboard
            sourceOverride = outcome.sourceOverride

            switch fetchResult {
            case let .success(result):
                if antigravityPlanDebug, p == .antigravity {
                    antigravityPlanInfo = try? await AntigravityStatusProbe().fetchPlanInfoSummary()
                    if format == .text, let info = antigravityPlanInfo {
                        Self.printAntigravityPlanInfo(info)
                    }
                }

                if dashboard == nil, format == .json, p == .codex {
                    dashboard = Self.loadOpenAIDashboardIfAvailable(usage: result.usage, fetcher: fetcher)
                }

                let shouldDetectVersion = sourceOverride == nil
                let versionInfo = Self.formatVersion(
                    provider: p,
                    raw: shouldDetectVersion ? Self.detectVersion(for: p) : nil)
                let source = sourceOverride ?? versionInfo.source
                let header = Self.makeHeader(provider: p, version: versionInfo.version, source: source)

                switch format {
                case .text:
                    var text = CLIRenderer.renderText(
                        provider: p,
                        snapshot: result.usage,
                        credits: result.credits,
                        context: RenderContext(header: header, status: status, useColor: useColor))
                    if let dashboard, p == .codex, sourceMode.usesWeb {
                        text += "\n" + Self.renderOpenAIWebDashboardText(dashboard)
                    }
                    sections.append(text)
                case .json:
                    payload.append(ProviderPayload(
                        provider: p,
                        version: versionInfo.version,
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
        let level = CodexBarLog.parseLevel(rawLevel) ?? (verbose ? .debug : .info)
        CodexBarLog.bootstrapIfNeeded(.init(destination: .stderr, level: level, json: isJSON))
    }

    static func effectiveArgv(_ argv: [String]) -> [String] {
        guard let first = argv.first else { return ["usage"] }
        if first.hasPrefix("-") { return ["usage"] + argv }
        return argv
    }

    fileprivate static func decodeProvider(from values: ParsedValues) -> ProviderSelection {
        let rawOverride = values.options["provider"]?.last
        return Self.providerSelection(rawOverride: rawOverride, enabled: Self.enabledProvidersFromDefaults())
    }

    static func providerSelection(rawOverride: String?, enabled: [UsageProvider]) -> ProviderSelection {
        if let rawOverride, let parsed = ProviderSelection(argument: rawOverride) {
            return parsed
        }
        if enabled.count >= 3 { return .all }
        if enabled.count == 2 {
            let hasCodex = enabled.contains(.codex)
            let hasClaude = enabled.contains(.claude)
            if hasCodex, hasClaude { return .both }
            return .custom(enabled)
        }
        if let first = enabled.first { return ProviderSelection(provider: first) }
        return .codex
    }

    private static func decodeFormat(from values: ParsedValues) -> OutputFormat {
        if let raw = values.options["format"]?.last, let parsed = OutputFormat(argument: raw) {
            return parsed
        }
        if values.flags.contains("json") { return .json }
        return .text
    }

    private static func shouldUseColor() -> Bool {
        isatty(STDOUT_FILENO) == 1
    }

    private static func detectVersion(for provider: UsageProvider) -> String? {
        switch provider {
        case .codex:
            VersionDetector.codexVersion()
        case .claude:
            ClaudeUsageFetcher().detectVersion()
        case .zai:
            nil
        case .gemini:
            VersionDetector.geminiVersion()
        case .antigravity:
            nil
        case .cursor:
            nil
        case .factory:
            nil
        }
    }

    private static func formatVersion(provider: UsageProvider, raw: String?) -> (version: String?, source: String) {
        let source = switch provider {
        case .codex: "codex-cli"
        case .claude: "claude"
        case .zai: "zai"
        case .gemini: "gemini-cli"
        case .antigravity: "antigravity"
        case .cursor: "cursor"
        case .factory: "factory"
        }
        guard let raw, !raw.isEmpty else { return (nil, source) }
        if let match = raw.range(of: #"(\d+(?:\.\d+)+)"#, options: .regularExpression) {
            let version = String(raw[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (version, source)
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), source)
    }

    private static func makeHeader(provider: UsageProvider, version: String?, source: String) -> String {
        let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
        if let version, !version.isEmpty {
            return "\(name) \(version) (\(source))"
        }
        return "\(name) (\(source))"
    }

    private static func fetchStatus(for provider: UsageProvider) async -> ProviderStatusPayload? {
        guard let urlString = ProviderDefaults.metadata[provider]?.statusPageURL,
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

        return ProviderDefaults.metadata.compactMap { provider, meta in
            let isOn = toggles[meta.cliName] ?? meta.defaultEnabled
            return isOn ? provider : nil
        }.sorted { $0.rawValue < $1.rawValue }
    }

    private static func fetchProviderUsage(
        provider: UsageProvider,
        context: ProviderFetchContext) async -> ProviderFetchOutcome
    {
        if provider == .codex, context.sourceMode == .oauth {
            return ProviderFetchOutcome(
                result: .failure(SourceSelectionError.unsupported(provider: "codex", source: context.sourceMode)),
                dashboard: nil,
                sourceOverride: nil)
        }

        if provider == .codex, context.sourceMode.usesWeb {
            let options = OpenAIWebOptions(
                timeout: context.webTimeout,
                debugDumpHTML: context.webDebugDumpHTML,
                verbose: context.verbose)
            let webLogger = await MainActor.run { WebLogBuffer(verbose: context.verbose) }
            let log: @MainActor (String) -> Void = { line in
                webLogger.append(line)
            }
            do {
                let webResult = try await Self.fetchOpenAIWebCodex(
                    fetcher: context.fetcher,
                    options: options,
                    logger: log)
                return ProviderFetchOutcome(
                    result: .success((usage: webResult.usage, credits: webResult.credits)),
                    dashboard: webResult.dashboard,
                    sourceOverride: "openai-web")
            } catch {
                let webLogs = await webLogger.snapshot()
                if context.sourceMode == .auto, Self.shouldFallbackToCodexCLI(for: error) {
                    Self.writeStderr(
                        "Warning: OpenAI web cookies unavailable (\(error.localizedDescription)). " +
                            "Falling back to Codex CLI.\n")
                    if !webLogs.isEmpty {
                        Self.writeStderr(webLogs.joined(separator: "\n") + "\n")
                    }
                    let result = await Self.fetch(
                        provider: provider,
                        includeCredits: context.includeCredits,
                        fetcher: context.fetcher,
                        claudeFetcher: context.claudeFetcher)
                    return ProviderFetchOutcome(result: result, dashboard: nil, sourceOverride: nil)
                }
                if !webLogs.isEmpty {
                    Self.writeStderr(webLogs.joined(separator: "\n") + "\n")
                }
                return ProviderFetchOutcome(result: .failure(error), dashboard: nil, sourceOverride: nil)
            }
        }

        if provider == .zai {
            guard let apiKey = ZaiSettingsReader.apiToken() else {
                return ProviderFetchOutcome(
                    result: .failure(ZaiSettingsError.missingToken),
                    dashboard: nil,
                    sourceOverride: nil)
            }
            do {
                let zaiUsage = try await ZaiUsageFetcher.fetchUsage(apiKey: apiKey)
                let snapshot = zaiUsage.toUsageSnapshot()
                return ProviderFetchOutcome(
                    result: .success((usage: snapshot, credits: nil)),
                    dashboard: nil,
                    sourceOverride: "zai")
            } catch {
                return ProviderFetchOutcome(result: .failure(error), dashboard: nil, sourceOverride: nil)
            }
        }

        if provider == .claude, context.sourceMode.usesWeb {
            do {
                let webUsage = try await ClaudeUsageFetcher(dataSource: .web).loadLatestUsage(model: "sonnet")
                let snapshot = UsageSnapshot(
                    primary: webUsage.primary,
                    secondary: webUsage.secondary,
                    tertiary: webUsage.opus,
                    updatedAt: webUsage.updatedAt,
                    accountEmail: webUsage.accountEmail,
                    accountOrganization: webUsage.accountOrganization,
                    loginMethod: webUsage.loginMethod)
                return ProviderFetchOutcome(
                    result: .success((usage: snapshot, credits: nil)),
                    dashboard: nil,
                    sourceOverride: nil)
            } catch {
                if context.sourceMode == .auto, self.shouldFallbackToClaudeCLI(for: error) {
                    self.writeStderr(
                        "Warning: Claude web cookies unavailable (\(error.localizedDescription)). " +
                            "Falling back to Claude CLI.\n")
                    let result = await Self.fetch(
                        provider: provider,
                        includeCredits: context.includeCredits,
                        fetcher: context.fetcher,
                        claudeFetcher: context.claudeFetcher)
                    return ProviderFetchOutcome(result: result, dashboard: nil, sourceOverride: nil)
                }
                return ProviderFetchOutcome(result: .failure(error), dashboard: nil, sourceOverride: nil)
            }
        }

        if provider == .factory {
            do {
                let probe = FactoryStatusProbe()
                let logger: ((String) -> Void)? = context.verbose ? { line in
                    Self.writeStderr(line + "\n")
                } : nil
                let snap = try await probe.fetch(logger: logger)
                return ProviderFetchOutcome(
                    result: .success((usage: snap.toUsageSnapshot(), credits: nil)),
                    dashboard: nil,
                    sourceOverride: nil)
            } catch {
                return ProviderFetchOutcome(result: .failure(error), dashboard: nil, sourceOverride: nil)
            }
        }

        if provider == .cursor {
            do {
                let probe = CursorStatusProbe()
                let logger: ((String) -> Void)? = context.verbose ? { line in
                    Self.writeStderr(line + "\n")
                } : nil
                let snap = try await probe.fetch(logger: logger)
                return ProviderFetchOutcome(
                    result: .success((usage: snap.toUsageSnapshot(), credits: nil)),
                    dashboard: nil,
                    sourceOverride: nil)
            } catch {
                return ProviderFetchOutcome(result: .failure(error), dashboard: nil, sourceOverride: nil)
            }
        }

        let result = await Self.fetch(
            provider: provider,
            includeCredits: context.includeCredits,
            fetcher: context.fetcher,
            claudeFetcher: context.claudeFetcher)
        return ProviderFetchOutcome(result: result, dashboard: nil, sourceOverride: nil)
    }

    private enum SourceSelectionError: LocalizedError {
        case unsupported(provider: String, source: SourceMode)

        var errorDescription: String? {
            switch self {
            case let .unsupported(provider, source):
                "Source '\(source.rawValue)' is not supported for \(provider)."
            }
        }
    }

    private static func fetch(
        provider: UsageProvider,
        includeCredits: Bool,
        fetcher: UsageFetcher,
        claudeFetcher: ClaudeUsageFetcher) async -> Result<(usage: UsageSnapshot, credits: CreditsSnapshot?), Error>
    {
        do {
            switch provider {
            case .codex:
                let usage = try await fetcher.loadLatestUsage()
                let credits = includeCredits ? try? await fetcher.loadLatestCredits() : nil
                return .success((usage, credits))
            case .claude:
                let usage = try await claudeFetcher.loadLatestUsage(model: "sonnet")
                return .success((
                    usage: UsageSnapshot(
                        primary: usage.primary,
                        secondary: usage.secondary,
                        tertiary: usage.opus,
                        providerCost: usage.providerCost,
                        updatedAt: usage.updatedAt,
                        accountEmail: usage.accountEmail,
                        accountOrganization: usage.accountOrganization,
                        loginMethod: usage.loginMethod),
                    credits: nil))
            case .zai:
                let apiKey = ZaiSettingsReader.apiToken()
                guard let apiKey else { return .failure(ZaiSettingsError.missingToken) }
                let usage = try await ZaiUsageFetcher.fetchUsage(apiKey: apiKey)
                return .success((usage: usage.toUsageSnapshot(), credits: nil))
            case .gemini:
                let probe = GeminiStatusProbe()
                let snap = try await probe.fetch()
                return .success((usage: snap.toUsageSnapshot(), credits: nil))
            case .antigravity:
                let probe = AntigravityStatusProbe()
                let snap = try await probe.fetch()
                return try .success((usage: snap.toUsageSnapshot(), credits: nil))
            case .cursor:
                let probe = CursorStatusProbe()
                let snap = try await probe.fetch()
                return .success((usage: snap.toUsageSnapshot(), credits: nil))
            case .factory:
                let probe = FactoryStatusProbe()
                let snap = try await probe.fetch()
                return .success((usage: snap.toUsageSnapshot(), credits: nil))
            }
        } catch {
            return .failure(error)
        }
    }

    private static func loadOpenAIDashboardIfAvailable(
        usage: UsageSnapshot,
        fetcher: UsageFetcher) -> OpenAIDashboardSnapshot?
    {
        guard let cache = OpenAIDashboardCacheStore.load() else { return nil }
        let codexEmail = (usage.accountEmail ?? fetcher.loadAccountInfo().email)?
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

    private static func decodeSourceMode(from values: ParsedValues) -> SourceMode? {
        guard let raw = values.options["source"]?.last else { return nil }
        return SourceMode(argument: raw)
    }

    private struct ProviderFetchOutcome: Sendable {
        let result: Result<(usage: UsageSnapshot, credits: CreditsSnapshot?), Error>
        let dashboard: OpenAIDashboardSnapshot?
        let sourceOverride: String?
    }

    private struct ProviderFetchContext: Sendable {
        let includeCredits: Bool
        let sourceMode: SourceMode
        let webTimeout: TimeInterval
        let webDebugDumpHTML: Bool
        let verbose: Bool
        let fetcher: UsageFetcher
        let claudeFetcher: ClaudeUsageFetcher
    }

    private enum SourceMode: String, CaseIterable, Sendable {
        case auto
        case web
        case cli
        case oauth

        var usesWeb: Bool {
            self == .auto || self == .web
        }

        init?(argument: String) {
            switch argument.lowercased() {
            case "auto": self = .auto
            case "web": self = .web
            case "cli": self = .cli
            case "oauth": self = .oauth
            default: return nil
            }
        }
    }

    private struct OpenAIWebOptions: Sendable {
        let timeout: TimeInterval
        let debugDumpHTML: Bool
        let verbose: Bool
    }

    @MainActor
    private final class WebLogBuffer {
        private var lines: [String] = []
        private let maxCount: Int
        private let verbose: Bool

        init(maxCount: Int = 300, verbose: Bool) {
            self.maxCount = maxCount
            self.verbose = verbose
        }

        func append(_ line: String) {
            self.lines.append(line)
            if self.lines.count > self.maxCount {
                self.lines.removeFirst(self.lines.count - self.maxCount)
            }
            if self.verbose {
                Self.writeToStderr("\(line)\n")
            }
        }

        private static func writeToStderr(_ string: String) {
            guard let data = string.data(using: .utf8) else { return }
            FileHandle.standardError.write(data)
        }

        func snapshot() -> [String] {
            self.lines
        }
    }

    private struct OpenAIWebCodexResult: Sendable {
        let usage: UsageSnapshot
        let credits: CreditsSnapshot?
        let dashboard: OpenAIDashboardSnapshot
    }

    private enum OpenAIWebCodexError: LocalizedError {
        case missingUsage

        var errorDescription: String? {
            switch self {
            case .missingUsage:
                "OpenAI web dashboard did not include usage limits."
            }
        }
    }

    @MainActor
    private static func fetchOpenAIWebCodex(
        fetcher: UsageFetcher,
        options: OpenAIWebOptions,
        logger: @MainActor @escaping (String) -> Void) async throws -> OpenAIWebCodexResult
    {
        let accountEmail = fetcher.loadAccountInfo().email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dashboard = try await Self.fetchOpenAIWebDashboard(
            accountEmail: accountEmail,
            fetcher: fetcher,
            options: options,
            logger: logger)
        guard let usage = dashboard.toUsageSnapshot(accountEmail: accountEmail) else {
            throw OpenAIWebCodexError.missingUsage
        }
        let credits = dashboard.toCreditsSnapshot()
        return OpenAIWebCodexResult(usage: usage, credits: credits, dashboard: dashboard)
    }

    @MainActor
    private static func fetchOpenAIWebDashboard(
        accountEmail: String?,
        fetcher: UsageFetcher,
        options: OpenAIWebOptions,
        logger: @MainActor @escaping (String) -> Void) async throws -> OpenAIDashboardSnapshot
    {
        #if os(macOS)
        // Ensure AppKit is initialized before using WebKit in a CLI.
        _ = NSApplication.shared

        let trimmed = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fetcher.loadAccountInfo().email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexEmail = trimmed?.isEmpty == false ? trimmed : (fallback?.isEmpty == false ? fallback : nil)
        let allowAnyAccount = codexEmail == nil

        let importResult = try await OpenAIDashboardBrowserCookieImporter()
            .importBestCookies(intoAccountEmail: codexEmail, allowAnyAccount: allowAnyAccount, logger: logger)
        let effectiveEmail = codexEmail ?? importResult.signedInEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
            accountEmail: effectiveEmail,
            logger: logger,
            debugDumpHTML: options.debugDumpHTML,
            timeout: options.timeout)
        let cacheEmail = effectiveEmail ?? dash.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cacheEmail, !cacheEmail.isEmpty {
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(accountEmail: cacheEmail, snapshot: dash))
        }
        return dash
        #else
        _ = accountEmail
        _ = fetcher
        _ = options
        _ = logger
        throw OpenAIDashboardFetcher.FetchError.noDashboardData(
            body: "OpenAI web dashboard fetch is only supported on macOS.")
        #endif
    }

    static func shouldFallbackToCodexCLI(for error: Error) -> Bool {
        if let importError = error as? OpenAIDashboardBrowserCookieImporter.ImportError {
            switch importError {
            case .noCookiesFound,
                 .browserAccessDenied,
                 .dashboardStillRequiresLogin,
                 .noMatchingAccount:
                return true
            }
        }

        if let fetchError = error as? OpenAIDashboardFetcher.FetchError {
            if case .loginRequired = fetchError { return true }
        }

        return false
    }

    static func shouldFallbackToClaudeCLI(for error: Error) -> Bool {
        if let fetchError = error as? ClaudeWebAPIFetcher.FetchError {
            if case .noSessionKeyFound = fetchError { return true }
        }
        return false
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

    private static func mapError(_ error: Error) -> ExitCode {
        switch error {
        case TTYCommandRunner.Error.binaryNotFound,
             CodexStatusProbeError.codexNotInstalled,
             ClaudeUsageError.claudeNotInstalled,
             GeminiStatusProbeError.geminiNotInstalled:
            ExitCode(2)
        case CodexStatusProbeError.timedOut,
             TTYCommandRunner.Error.timedOut,
             GeminiStatusProbeError.timedOut:
            ExitCode(4)
        case ClaudeUsageError.parseFailed,
             ClaudeUsageError.oauthFailed,
             UsageError.decodeFailed,
             UsageError.noRateLimitsFound,
             GeminiStatusProbeError.parseFailed:
            ExitCode(3)
        default:
            .failure
        }
    }

    private static func printError(_ error: Error) {
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

    private static func exit(code: ExitCode, message: String? = nil) -> Never {
        if let message {
            self.writeStderr("\(message)\n")
        }
        Self.platformExit(code.rawValue)
    }

    private static func writeStderr(_ string: String) {
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
          codexbar usage [--format text|json] [--provider codex|claude|zai|gemini|antigravity|both|all]
                       [--no-credits] [--pretty] [--status] [--source <auto|web|cli|oauth>]
                       [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug]

        Description:
          Print usage from enabled providers as text (default) or JSON. Honors your in-app toggles.
          When --source is auto/web (macOS only), CodexBar uses browser cookies to fetch web-backed data:
          - Codex: OpenAI web dashboard (usage limits, credits remaining, code review remaining, usage breakdown).
            Auto falls back to Codex CLI only when cookies are missing.
          - Claude: claude.ai API.
            Auto falls back to Claude CLI only when cookies are missing.

        Examples:
          codexbar usage
          codexbar usage --provider claude
          codexbar usage --provider gemini
          codexbar usage --format json --provider all --pretty
          codexbar usage --status
          codexbar usage --provider codex --source web --format json --pretty
        """
    }

    static func rootHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar [--format text|json] [--provider codex|claude|zai|gemini|antigravity|both|all]
                  [--no-credits] [--pretty] [--status] [--source <auto|web|cli|oauth>]
                  [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug]

        Global flags:
          -h, --help      Show help
          -V, --version   Show version
          -v, --verbose   Enable verbose logging
          --log-level <trace|verbose|debug|info|warning|error|critical>
          --json-output   Emit machine-readable logs

        Examples:
          codexbar
          codexbar --format json --provider all --pretty
          codexbar --provider gemini
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

    @Option(name: .long("provider"), help: "Provider to query: codex | claude | gemini | antigravity | both | all")
    var provider: ProviderSelection?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("no-credits"), help: "Skip Codex credits line")
    var noCredits: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long("status"), help: "Fetch and include provider status")
    var status: Bool = false

    @Option(name: .long("source"), help: Self.sourceHelp)
    var source: String?

    @Option(name: .long("web-timeout"), help: "Web fetch timeout (seconds) (Codex only; source=auto|web)")
    var webTimeout: Double?

    @Flag(name: .long("web-debug-dump-html"), help: "Dump HTML snapshots to /tmp when Codex dashboard data is missing")
    var webDebugDumpHtml: Bool = false

    @Flag(name: .long("antigravity-plan-debug"), help: "Emit Antigravity planInfo fields (debug)")
    var antigravityPlanDebug: Bool = false
}

enum ProviderSelection: Sendable, ExpressibleFromArgument {
    case codex
    case claude
    case zai
    case gemini
    case antigravity
    case cursor
    case factory
    case both
    case all
    case custom([UsageProvider])

    init?(argument: String) {
        switch argument.lowercased() {
        case "codex": self = .codex
        case "claude": self = .claude
        case "zai", "z.ai": self = .zai
        case "gemini": self = .gemini
        case "antigravity": self = .antigravity
        case "cursor": self = .cursor
        case "factory": self = .factory
        case "both": self = .both
        case "all": self = .all
        default: return nil
        }
    }

    init(provider: UsageProvider) {
        switch provider {
        case .codex: self = .codex
        case .claude: self = .claude
        case .zai: self = .zai
        case .gemini: self = .gemini
        case .antigravity: self = .antigravity
        case .cursor: self = .cursor
        case .factory: self = .factory
        }
    }

    var asList: [UsageProvider] {
        switch self {
        case .codex: [.codex]
        case .claude: [.claude]
        case .zai: [.zai]
        case .gemini: [.gemini]
        case .antigravity: [.antigravity]
        case .cursor: [.cursor]
        case .factory: [.factory]
        case .both: [.codex, .claude]
        case .all: [.codex, .claude, .zai, .cursor, .gemini, .antigravity, .factory]
        case let .custom(providers): providers
        }
    }
}

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

private enum VersionDetector {
    static func codexVersion() -> String? {
        guard let path = TTYCommandRunner.which("codex") else { return nil }
        let candidates = [
            ["--version"],
            ["version"],
            ["-v"],
        ]
        for args in candidates {
            if let version = Self.run(path: path, args: args) { return version }
        }
        return nil
    }

    static func geminiVersion() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = BinaryLocator.resolveGeminiBinary(env: env, loginPATH: nil)
            ?? TTYCommandRunner.which("gemini") else { return nil }
        let candidates = [
            ["--version"],
            ["-v"],
        ]
        for args in candidates {
            if let version = Self.run(path: path, args: args) { return version }
        }
        return nil
    }

    private static func run(path: String, args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning, Date() < deadline {
            usleep(50000)
        }
        if proc.isRunning {
            proc.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning, Date() < killDeadline {
                usleep(20000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .split(whereSeparator: \.isNewline).first
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
