import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    /// Default poll period. Deliberately far longer than `serve --refresh-interval`
    /// (a cache TTL that only bounds staleness when someone asks): `watch`
    /// originates traffic against every enabled provider on every tick.
    static let hooksWatchDefaultInterval: TimeInterval = 300
    /// Floor for `--interval`. Rejected rather than clamped, so a mistyped value
    /// cannot silently turn `watch` into an unattended API hammer.
    static let hooksWatchMinimumInterval: TimeInterval = 60

    static func runHooksWatch(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)

        // Command-only arguments are validated before the config file is read.
        // `loadConfig` exits on a malformed config, so decoding after it would let a
        // broken config mask the documented argument errors. These two decoders take
        // no config for exactly that reason.
        let interval: TimeInterval
        switch Self.decodeHooksWatchInterval(from: values) {
        case let .success(value):
            interval = value
        case let .failure(error):
            Self.exit(code: .failure, message: error.message, output: output, kind: .args)
        }

        let explicitProviders: [UsageProvider]?
        switch Self.decodeHooksWatchProviderNames(from: values) {
        case let .success(value):
            explicitProviders = value
        case let .failure(error):
            Self.exit(code: .failure, message: error.message, output: output, kind: .args)
        }

        let config = Self.loadConfig(output: output)
        let hooks = config.hooks ?? HooksConfig()

        let providers: [UsageProvider]
        switch Self.hooksWatchProviders(explicit: explicitProviders, config: config) {
        case let .success(value):
            providers = value
        case let .failure(error):
            Self.exit(code: .failure, message: error.message, output: output, kind: .args)
        }

        guard hooks.enabled else {
            Self.exit(
                code: .failure,
                message: "Hooks are disabled. Run `codexbar hooks enable` first.",
                output: output,
                kind: .config)
        }
        guard !hooks.events.isEmpty else {
            Self.exit(
                code: .failure,
                message: "No hook rules configured. See `codexbar hooks list`.",
                output: output,
                kind: .config)
        }

        let verbose = values.flags.contains("verbose")
        let webTimeout = Self.decodeHooksWatchWebTimeout(from: values)

        let detector = HookTransitionDetector()
        let rateLimiter = HookRateLimiter()
        let stop = HooksWatchStopSignal()
        let monitor = CLITerminationSignalMonitor { _ in
            stop.request()
        }
        defer { monitor.cancel() }

        if !output.usesJSONOutput {
            let names = providers.map(\.rawValue).joined(separator: ", ")
            print("Watching \(providers.count) provider(s) every \(Int(interval))s: \(names)")
            print("Press Ctrl-C to stop.")
        }

        while !stop.isRequested {
            for provider in providers where !stop.isRequested {
                let observation = await Self.hooksWatchObservation(
                    provider: provider,
                    config: config,
                    verbose: verbose,
                    webTimeout: webTimeout)

                let dispatches = detector.evaluate(observation: observation, config: hooks)
                for dispatch in dispatches {
                    Self.reportHookEvent(dispatch.event, output: output)
                    // `rules` narrows dispatch to the specific rule(s) whose edge this
                    // poll observed (currently only set for quota_low); nil means every
                    // enabled rule for the event, matched the normal way.
                    let dispatchConfig = dispatch.rules.map { HooksConfig(enabled: true, events: $0) } ?? hooks
                    await HookRunner.dispatch(
                        event: dispatch.event,
                        config: dispatchConfig,
                        rateLimiter: rateLimiter)
                }
            }

            guard !stop.isRequested else { break }
            await Self.sleepInterruptibly(interval: interval, stop: stop)
        }

        Self.exit(code: .success, output: output, kind: .runtime)
    }

    // MARK: - Observation

    /// Fetches one provider and maps the result onto the detector's input shape.
    ///
    /// A fetch failure becomes a coarse `refreshFailureStatus`; the raw error is
    /// never forwarded, because provider errors can embed response-body previews.
    static func hooksWatchObservation(
        provider: UsageProvider,
        config: CodexBarConfig,
        verbose: Bool,
        webTimeout: TimeInterval) async -> HookProviderObservation
    {
        let statusPayload = await Self.fetchStatus(for: provider)
        let status = Self.hookProviderStatus(statusPayload?.indicator)

        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: config,
                verbose: verbose)
        } catch {
            return HookProviderObservation(
                provider: provider.rawValue,
                status: status,
                refreshFailureStatus: "auth_required")
        }

        let account: ProviderTokenAccount?
        do {
            account = try tokenContext.resolvedAccounts(for: provider).first
        } catch {
            return HookProviderObservation(
                provider: provider.rawValue,
                status: status,
                refreshFailureStatus: "auth_required")
        }

        let browserDetection = BrowserDetection()
        let fetcher = UsageFetcher()
        let claudeFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)
        let env = tokenContext.environment(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            account: account)
        let settings = tokenContext.settingsSnapshot(for: provider, account: account)
        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: tokenContext.preferredSourceMode(for: provider),
            provider: provider,
            account: account)

        let fetchContext = ProviderFetchContext(
            runtime: .cli,
            sourceMode: effectiveSourceMode,
            includeCredits: false,
            webTimeout: webTimeout,
            webDebugDumpHTML: false,
            verbose: verbose,
            env: env,
            settings: settings,
            fetcher: tokenContext.fetcher(base: fetcher, provider: provider, env: env),
            claudeFetcher: claudeFetcher,
            browserDetection: browserDetection,
            // Watch is read-only, like `guard`: no updater callbacks, so refresh-dependent
            // credentials report unavailable instead of prompting.
            selectedTokenAccountID: account?.id)

        let outcome = await ProviderInteractionContext.$current.withValue(.background) {
            await Self.fetchProviderUsage(provider: provider, context: fetchContext)
        }

        switch outcome.result {
        case let .success(result):
            let usage = result.usage.scoped(to: provider)
            return HookProviderObservation(
                provider: provider.rawValue,
                lanes: Self.hooksWatchLanes(provider: provider, usage: usage, config: config),
                status: status,
                accountDisplayName: usage.accountEmail(for: provider))
        case let .failure(error):
            return HookProviderObservation(
                provider: provider.rawValue,
                status: status,
                refreshFailureStatus: Self.hookRefreshFailureStatus(error))
        }
    }

    static func hooksWatchLanes(
        provider: UsageProvider,
        usage: UsageSnapshot,
        config: CodexBarConfig) -> [HookQuotaLaneObservation]
    {
        let account = usage.accountEmail(for: provider)
        let warnings = config.providerConfig(for: provider.instanceID)?.quotaWarnings
        let lanes: [(QuotaWarningWindow, RateWindow?)] = [
            (.session, usage.primary),
            (.weekly, usage.secondary),
        ]

        return lanes.compactMap { window, rateWindow in
            guard let rateWindow else { return nil }
            let thresholds = warnings?
                .thresholds(for: window, global: QuotaWarningThresholds.defaults)
                ?? QuotaWarningThresholds.defaults
            return HookQuotaLaneObservation(
                key: HookQuotaLaneKey(
                    provider: provider.rawValue,
                    window: window,
                    accountDiscriminator: account),
                label: window.displayName,
                rateWindow: rateWindow,
                // Stored thresholds are *remaining* percentages; the crossing math
                // works on used fractions, matching the app's conversion.
                fallbackThresholds: thresholds.map { (100.0 - Double($0)) / 100.0 },
                accountDisplayName: account)
        }
    }

    static func hookProviderStatus(
        _ indicator: ProviderStatusPayload.ProviderStatusIndicator?) -> HookProviderStatus
    {
        guard let indicator else { return .unknown }
        return HookProviderStatus(rawValue: indicator.rawValue) ?? .unknown
    }

    /// Coarse, non-secret category for a refresh failure, mirroring the app's
    /// classification. Never forwards the raw error description.
    static func hookRefreshFailureStatus(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return "error" }
        switch nsError.code {
        case NSURLErrorCancelled:
            return "cancelled"
        case NSURLErrorTimedOut:
            return "timeout"
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return "offline"
        default:
            return "network_error"
        }
    }

    // MARK: - Sleep

    /// Poll-period tick used by `sleepInterruptibly` to bound how late a termination
    /// signal is noticed.
    static let hooksWatchSleepTickNanoseconds: UInt64 = 200_000_000

    /// Sleeps up to `interval`, checking `stop` every tick instead of once at the
    /// end. `CLITerminationSignalMonitor` only flips a flag — it does not cancel the
    /// running task — so a single long `Task.sleep` would leave `hooks watch`
    /// appearing hung on SIGINT/SIGTERM/SIGHUP until the full interval elapsed.
    static func sleepInterruptibly(interval: TimeInterval, stop: HooksWatchStopSignal) async {
        var remainingNanoseconds = UInt64((max(0, interval) * 1_000_000_000).rounded())
        while remainingNanoseconds > 0, !stop.isRequested {
            let sleepNanoseconds = min(remainingNanoseconds, Self.hooksWatchSleepTickNanoseconds)
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            remainingNanoseconds -= sleepNanoseconds
        }
    }

    // MARK: - Reporting

    static func reportHookEvent(_ event: HookEvent, output: CLIOutputPreferences) {
        if output.usesJSONOutput {
            printJSON(event, pretty: output.pretty)
            return
        }
        var line = "\(event.event.rawValue) \(event.provider)"
        if let window = event.window { line += " window=\(window)" }
        if let usage = event.usagePercent {
            line += String(format: " usage=%.0f%%", usage * 100)
        }
        if let status = event.status { line += " status=\(status)" }
        print(line)
    }

    // MARK: - Argument decoding

    static func decodeHooksWatchInterval(from values: ParsedValues) -> Result<TimeInterval, CLIArgumentError> {
        guard let raw = values.options["interval"]?.last else {
            return .success(self.hooksWatchDefaultInterval)
        }
        guard let parsed = Double(raw), parsed.isFinite else {
            return .failure(CLIArgumentError("Invalid --interval value: \(raw)"))
        }
        guard parsed >= Self.hooksWatchMinimumInterval else {
            return .failure(CLIArgumentError(
                "--interval must be at least \(Int(Self.hooksWatchMinimumInterval)) seconds."))
        }
        return .success(parsed)
    }

    /// Per-fetch web timeout, mirroring `guard`'s default when unset.
    static func decodeHooksWatchWebTimeout(from values: ParsedValues) -> TimeInterval {
        guard let raw = values.options["webTimeout"]?.last,
              let parsed = Double(raw),
              parsed.isFinite,
              parsed > 0
        else { return 60 }
        return parsed
    }

    /// Validates explicit `--provider` names without consulting the config.
    ///
    /// Returns nil when no `--provider` was given, meaning the caller should fall
    /// back to the configured enabled providers. Kept config-free so argument errors
    /// can be reported before the config file is ever read.
    static func decodeHooksWatchProviderNames(
        from values: ParsedValues) -> Result<[UsageProvider]?, CLIArgumentError>
    {
        guard let raw = values.options["provider"], !raw.isEmpty else {
            return .success(nil)
        }

        var selected: [UsageProvider] = []
        for name in raw {
            guard let provider = ProviderDescriptorRegistry.cliNameMap[name.lowercased()] else {
                return .failure(CLIArgumentError("Unknown provider: \(name)"))
            }
            if !selected.contains(provider) {
                selected.append(provider)
            }
        }
        return .success(selected)
    }

    /// Resolves the providers to poll, defaulting to everything enabled in config.
    static func hooksWatchProviders(
        explicit: [UsageProvider]?,
        config: CodexBarConfig) -> Result<[UsageProvider], CLIArgumentError>
    {
        if let explicit { return .success(explicit) }
        let enabled = config.enabledProviders()
        guard !enabled.isEmpty else {
            return .failure(CLIArgumentError("No providers are enabled."))
        }
        return .success(enabled.compactMap(\.firstPartyProvider))
    }
}

/// Thread-safe stop flag flipped by the termination signal handler.
final class HooksWatchStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        self.lock.lock()
        self.requested = true
        self.lock.unlock()
    }

    var isRequested: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requested
    }
}

struct HooksWatchOptions: CommanderParsable {
    @Option(name: .long("interval"), help: "Poll period in seconds (default 300, minimum 60)")
    var interval: String?

    @Option(name: .long("provider"), help: ProviderHelp.optionHelp)
    var provider: String?

    @Flag(name: .long("verbose"), help: "Print fetch diagnostics")
    var verbose: Bool = false

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "Emit JSON")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false
}
