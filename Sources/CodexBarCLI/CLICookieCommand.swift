import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runCookieRefresh(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let rawProvider = values.options["provider"]?.last
        let refreshAll = values.flags.contains("all")

        guard (rawProvider != nil) != refreshAll else {
            Self.exit(
                code: .failure,
                message: "Specify exactly one of --provider <name> or --all.",
                output: output,
                kind: .args)
        }

        #if os(macOS)
        let targets: [ProviderDescriptor]
        do {
            targets = try Self.cookieRefreshTargets(rawProvider: rawProvider, refreshAll: refreshAll)
        } catch {
            Self.exit(
                code: .failure,
                message: error.localizedDescription,
                output: output,
                kind: .args)
        }

        let config = Self.loadConfig(output: output)
        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: config,
                verbose: values.flags.contains("verbose"))
        } catch {
            Self.exit(
                code: .failure,
                message: "Could not prepare provider settings.",
                output: output,
                kind: .config)
        }

        let browserDetection = BrowserDetection()
        let allowKeychainPrompt = values.flags.contains("allowKeychainPrompt")
        let results = await Self.performCookieRefreshes(
            targets: targets,
            allowKeychainPrompt: allowKeychainPrompt,
            preflight: { descriptor in
                Self.cookieRefreshSkipResult(descriptor: descriptor, config: config)
            },
            operation: { descriptor in
                await Self.refreshCookie(
                    descriptor: descriptor,
                    config: config,
                    tokenContext: tokenContext,
                    browserDetection: browserDetection)
            })

        Self.printCookieRefreshResults(results, output: output)
        let hasErrors = results.contains(where: \.isFailure)
        Self.exit(code: hasErrors ? .failure : .success, output: output, kind: .runtime)
        #else
        Self.exit(
            code: .failure,
            message: "Cookie refresh is only supported on macOS.",
            output: output,
            kind: .args)
        #endif
    }

    #if os(macOS)
    static func cookieRefreshTargets(
        rawProvider: String?,
        refreshAll: Bool,
        descriptors: [ProviderDescriptor] = ProviderDescriptorRegistry.all) throws -> [ProviderDescriptor]
    {
        let supported = descriptors.filter { descriptor in
            descriptor.metadata.browserCookieOrder != nil && descriptor.fetchPlan.sourceModes.contains(.web)
        }
        if refreshAll {
            guard !supported.isEmpty else { throw CookieRefreshCommandError.noSupportedProviders }
            return supported
        }

        guard let rawProvider,
              let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()]
        else {
            throw CookieRefreshCommandError.unknownProvider(rawProvider ?? "")
        }
        guard let descriptor = supported.first(where: { $0.id == provider }) else {
            throw CookieRefreshCommandError.unsupportedProvider(rawProvider)
        }
        return [descriptor]
    }

    static func performCookieRefreshes(
        targets: [ProviderDescriptor],
        allowKeychainPrompt: Bool,
        preflight: (ProviderDescriptor) -> CookieRefreshResult? = { _ in nil },
        operation: (ProviderDescriptor) async -> CookieRefreshResult) async -> [CookieRefreshResult]
    {
        var results: [CookieRefreshResult] = []
        results.reserveCapacity(targets.count)
        for descriptor in targets {
            if let result = preflight(descriptor) {
                results.append(result)
                continue
            }

            let browsers = descriptor.metadata.browserCookieOrder ?? []
            let needsAcknowledgement = BrowserCookieAccessGate.requiresKeychainPromptAcknowledgement(for: browsers)
            guard !needsAcknowledgement || allowKeychainPrompt else {
                results.append(CookieRefreshResult(
                    provider: descriptor.cli.name,
                    status: .blocked,
                    message: Self.keychainPromptAcknowledgementHint))
                continue
            }

            let result: CookieRefreshResult = if allowKeychainPrompt {
                await BrowserCookieAccessGate.withExplicitRetry {
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await operation(descriptor)
                    }
                }
            } else {
                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await operation(descriptor)
                }
            }
            results.append(result)
        }
        return results
    }

    static func cookieRefreshFailure(provider: UsageProvider, error _: any Error) -> CookieRefreshResult {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let promptCapableBrowsers = (descriptor.metadata.browserCookieOrder ?? [])
            .filter { BrowserCookieAccessGate.requiresKeychainPromptAcknowledgement(for: [$0]) }
        if let browser = promptCapableBrowsers.first, KeychainAccessGate.isDisabled {
            return CookieRefreshResult(
                provider: descriptor.cli.name,
                status: .failed,
                message: "\(browser.displayName) cookie decryption is disabled in CodexBar; " +
                    "enable Keychain access and refresh.")
        }
        if let browser = promptCapableBrowsers.first(where: { BrowserCookieAccessGate.hasActiveDenial(for: $0) }) {
            return CookieRefreshResult(
                provider: descriptor.cli.name,
                status: .failed,
                message: "\(browser.displayName) cookie decryption was declined in Keychain; " +
                    "retry with --allow-keychain-prompt.")
        }
        return CookieRefreshResult(
            provider: descriptor.cli.name,
            status: .failed,
            message: self.browserCookieAccessFailureHint)
    }

    static func cookieRefreshText(_ results: [CookieRefreshResult]) -> String {
        results.map { result in
            let marker = switch result.status {
            case .refreshed: "✅"
            case .skipped: "↷"
            case .blocked: "⚠️"
            case .failed: "❌"
            }
            return "\(result.provider): \(marker) \(result.message)"
        }.joined(separator: "\n")
    }

    private static let keychainPromptAcknowledgementHint =
        "Browser cookie decryption may open a macOS Keychain prompt. " +
        "Retry interactively with --allow-keychain-prompt to acknowledge it."

    private static let browserCookieAccessFailureHint =
        "No browser session cookie was refreshed. Sign in in a configured browser and retry. " +
        "If Keychain access was declined, CodexBar keeps the six-hour denial cooldown; " +
        "use --allow-keychain-prompt only for an explicit interactive retry."

    private static func refreshCookie(
        descriptor: ProviderDescriptor,
        config: CodexBarConfig,
        tokenContext: TokenAccountCLIContext,
        browserDetection: BrowserDetection) async -> CookieRefreshResult
    {
        let provider = descriptor.id
        if let result = Self.cookieRefreshSkipResult(descriptor: descriptor, config: config) {
            return result
        }

        return await Self.withCookieRefreshCacheSuppressed(provider: provider, providerName: descriptor.cli.name) {
            let environment = tokenContext.environment(
                base: ProcessInfo.processInfo.environment,
                provider: provider,
                account: nil)
            let context = ProviderFetchContext(
                runtime: .cli,
                sourceMode: .web,
                includeCredits: false,
                includeOptionalUsage: false,
                webTimeout: 60,
                webDebugDumpHTML: false,
                verbose: false,
                env: environment,
                settings: tokenContext.settingsSnapshot(for: provider, account: nil),
                fetcher: tokenContext.fetcher(base: UsageFetcher(), provider: provider, env: environment),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
                browserDetection: browserDetection)
            let outcome = await descriptor.fetchOutcome(context: context)
            return switch outcome.result {
            case .success:
                CookieRefreshResult(
                    provider: descriptor.cli.name,
                    status: .refreshed,
                    message: "Browser cookie refreshed.")
            case let .failure(error):
                Self.cookieRefreshFailure(provider: provider, error: error)
            }
        }
    }

    static func withCookieRefreshCacheSuppressed(
        provider: UsageProvider,
        providerName: String,
        operation: () async -> CookieRefreshResult) async -> CookieRefreshResult
    {
        guard let gate = CookieHeaderCache.beginRefreshReadSuppression(provider: provider) else {
            return CookieRefreshResult(
                provider: providerName,
                status: .failed,
                message: "Cookie cache could not be read safely; no browser import was attempted.")
        }
        defer { CookieHeaderCache.endRefreshReadSuppression(gate) }
        let result = await operation()
        guard !result.isFailure else { return result }

        let commit = CookieHeaderCache.commitRefreshReadSuppression(gate)
        guard commit.stagedCount > 0,
              commit.committedCount == commit.stagedCount,
              commit.failedCount == 0
        else {
            return CookieRefreshResult(
                provider: providerName,
                status: .failed,
                message: "Browser cookie validation succeeded, but the refreshed session could not be saved.")
        }
        return result
    }

    private static func cookieRefreshSkipResult(
        descriptor: ProviderDescriptor,
        config: CodexBarConfig) -> CookieRefreshResult?
    {
        switch config.providerConfig(for: descriptor.id)?.cookieSource ?? .auto {
        case .manual:
            CookieRefreshResult(
                provider: descriptor.cli.name,
                status: .skipped,
                message: "Browser refresh skipped because this provider uses a manual cookie.")
        case .off:
            CookieRefreshResult(
                provider: descriptor.cli.name,
                status: .skipped,
                message: "Browser refresh skipped because browser cookies are disabled for this provider.")
        case .auto:
            nil
        }
    }

    private static func printCookieRefreshResults(
        _ results: [CookieRefreshResult],
        output: CLIOutputPreferences)
    {
        switch output.format {
        case .text:
            if !output.jsonOnly {
                print(self.cookieRefreshText(results))
            }
        case .json:
            printJSON(results, pretty: output.pretty)
        }
    }
    #endif
}

enum CookieRefreshStatus: String, Encodable {
    case refreshed
    case skipped
    case blocked
    case failed
}

struct CookieRefreshResult: Encodable {
    let provider: String
    let status: CookieRefreshStatus
    let message: String

    var isFailure: Bool {
        self.status == .blocked || self.status == .failed
    }
}

private enum CookieRefreshCommandError: LocalizedError {
    case noSupportedProviders
    case unknownProvider(String)
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .noSupportedProviders:
            "No providers support browser cookie refresh on this platform."
        case let .unknownProvider(provider):
            "Unknown provider: \(provider)"
        case let .unsupportedProvider(provider):
            "\(provider) does not support browser cookie refresh."
        }
    }
}

struct CookieOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Flag(name: .long("json"), help: "Output as JSON")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Output as JSON only (no text)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("all"), help: "Refresh every browser-cookie provider")
    var all: Bool = false

    @Option(name: .long("provider"), help: "Refresh a specific browser-cookie provider")
    var provider: String?

    @Flag(
        name: .long("allow-keychain-prompt"),
        help: "Acknowledge that Chromium cookie decryption may open a macOS Keychain prompt")
    var allowKeychainPrompt: Bool = false
}
