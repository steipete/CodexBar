import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    /// Window selected by the `guard` command: `session` maps to the primary
    /// rate window, `weekly` maps to the secondary rate window.
    enum GuardWindow: String {
        case session
        case weekly

        var payloadValue: String {
            self.rawValue
        }
    }

    /// Pure gating outcome. Kept free of I/O so it is unit-testable off-network.
    enum GuardDecision: String {
        case ok
        case blocked
        case unknown
    }

    enum GuardUnavailableReason: String, Sendable {
        case accountResolution = "account-resolution"
        case fetchFailed = "fetch-failed"
        case timeout
        case windowUnavailable = "window-unavailable"
    }

    enum GuardFetchOutcome: Sendable {
        case available(Double)
        case unavailable(GuardUnavailableReason)
    }

    struct GuardEvaluation: Sendable {
        let decision: GuardDecision
        let exitCode: Int32
        let remainingPercent: Double?
        let unavailableReason: GuardUnavailableReason?
    }

    /// Command-specific stable status codes. `69` is sysexits `EX_UNAVAILABLE`.
    private enum GuardExitCode: Int32 {
        case safe = 0
        case blocked = 1
        case unavailable = 69
    }

    /// Pure decision core for `codexbar guard`.
    ///
    /// - unavailable quota → `.unknown` (exit `0` when `failOpen`, else `69`).
    /// - remaining quota at or above the threshold → `.ok` (exit `0`).
    /// - otherwise → `.blocked` (exit `1`).
    static func evaluateGuard(
        outcome: GuardFetchOutcome,
        minimumRemainingPercent: Double,
        failOpen: Bool) -> GuardEvaluation
    {
        guard case let .available(remainingPercent) = outcome else {
            guard case let .unavailable(reason) = outcome else { preconditionFailure("Unhandled guard outcome") }
            return GuardEvaluation(
                decision: .unknown,
                exitCode: failOpen ? GuardExitCode.safe.rawValue : GuardExitCode.unavailable.rawValue,
                remainingPercent: nil,
                unavailableReason: reason)
        }
        if remainingPercent >= minimumRemainingPercent {
            return GuardEvaluation(
                decision: .ok,
                exitCode: GuardExitCode.safe.rawValue,
                remainingPercent: remainingPercent,
                unavailableReason: nil)
        }
        return GuardEvaluation(
            decision: .blocked,
            exitCode: GuardExitCode.blocked.rawValue,
            remainingPercent: remainingPercent,
            unavailableReason: nil)
    }

    /// Remaining headroom (`100 - usedPercent`) for a resolved rate window, or `nil` when the window
    /// is absent or a synthetic placeholder. A synthetic window is a lane the provider did not
    /// actually report (e.g. Claude with no live five-hour session), so it must not read as free
    /// headroom and let the gate pass on a phantom metric.
    static func guardRemainingHeadroom(for window: RateWindow?) -> Double? {
        guard let window, !window.isSyntheticPlaceholder else { return nil }
        return 100 - window.usedPercent
    }

    static func runGuard(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let json = values.flags.contains("json")
        let failOpen = values.flags.contains("failOpen")
        let verbose = values.flags.contains("verbose")

        guard let window = Self.decodeGuardWindow(from: values) else {
            Self.exitGuardArgumentError("--window must be session|weekly.", output: output)
        }

        let minimumRemainingPercent: Double
        switch Self.decodeGuardMinimumRemaining(from: values) {
        case let .success(value):
            minimumRemainingPercent = value
        case .failure:
            Self.exitGuardArgumentError(
                "--min-remaining must be a finite percent between 0 and 100.",
                output: output)
        }

        let timeout: TimeInterval
        switch Self.decodeGuardTimeout(from: values) {
        case let .success(value):
            timeout = value
        case .failure:
            Self.exitGuardArgumentError(
                "--timeout must be a finite number of seconds from 0 through 86400.",
                output: output)
        }

        let provider: UsageProvider
        switch Self.decodeGuardProvider(from: values) {
        case let .success(value):
            provider = value
        case let .failure(error):
            Self.exitGuardArgumentError(error.localizedDescription, output: output)
        }
        let config = Self.loadConfig(output: output)

        let outcome = await Self.runGuardFetch(timeout: timeout) {
            await ProviderInteractionContext.$current.withValue(.background) {
                await Self.guardFetchOutcome(
                    provider: provider,
                    window: window,
                    config: config,
                    verbose: verbose,
                    webTimeout: timeout > 0 ? timeout : 60)
            }
        }
        if case .unavailable(.timeout) = outcome {
            TTYCommandRunner.terminateActiveProcessesForAppShutdown()
        }

        let evaluation = Self.evaluateGuard(
            outcome: outcome,
            minimumRemainingPercent: minimumRemainingPercent,
            failOpen: failOpen)

        Self.emitGuardResult(
            provider: provider,
            window: window,
            minimumRemainingPercent: minimumRemainingPercent,
            evaluation: evaluation,
            json: json,
            pretty: output.pretty)
        Self.platformExit(evaluation.exitCode)
    }

    // MARK: - Argument decoding

    private static func exitGuardArgumentError(_ message: String, output: CLIOutputPreferences) -> Never {
        self.exit(code: .usage, message: "Error: \(message)", output: output, kind: .args)
    }

    static func decodeGuardWindow(from values: ParsedValues) -> GuardWindow? {
        guard let raw = values.options["window"]?.last else { return .session }
        return GuardWindow(rawValue: raw.lowercased())
    }

    static func guardProvider(rawOverride: String?) -> Result<UsageProvider, CLIArgumentError> {
        guard let rawOverride else {
            return .failure(CLIArgumentError("guard requires --provider <id>."))
        }
        guard let selection = ProviderSelection(argument: rawOverride) else {
            return .failure(CLIArgumentError("unknown provider '\(rawOverride)'."))
        }
        guard selection.asList.count == 1, let provider = selection.asList.first else {
            return .failure(CLIArgumentError("guard requires exactly one --provider."))
        }
        return .success(provider)
    }

    private static func decodeGuardProvider(from values: ParsedValues) -> Result<UsageProvider, CLIArgumentError> {
        self.guardProvider(rawOverride: values.options["provider"]?.last)
    }

    static func decodeGuardMinimumRemaining(from values: ParsedValues) -> Result<Double, CLIArgumentError> {
        guard let raw = values.options["minRemaining"]?.last else { return .success(10) }
        guard let value = Double(raw), value.isFinite, value >= 0, value <= 100 else {
            return .failure(CLIArgumentError("--min-remaining must be a finite percent between 0 and 100."))
        }
        return .success(value)
    }

    static func decodeGuardTimeout(from values: ParsedValues) -> Result<TimeInterval, CLIArgumentError> {
        self.guardTimeout(raw: values.options["timeout"]?.last)
    }

    static func guardTimeout(raw: String?) -> Result<TimeInterval, CLIArgumentError> {
        guard let raw else { return .success(60) }
        guard let value = TimeInterval(raw), value.isFinite, value >= 0, value <= 86400 else {
            return .failure(CLIArgumentError("--timeout must be a finite number of seconds from 0 through 86400."))
        }
        return .success(value)
    }

    // MARK: - Fetch

    static func runGuardFetch(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async -> GuardFetchOutcome) async -> GuardFetchOutcome
    {
        let sourceTask = Task<GuardFetchOutcome, Error> {
            await operation()
        }
        guard timeout > 0 else {
            return await (try? sourceTask.value) ?? .unavailable(.fetchFailed)
        }

        let join = BoundedTaskJoin(sourceTask: sourceTask)
        return switch await join.value(joinGrace: .seconds(timeout)) {
        case let .value(outcome): outcome
        case .failure: .unavailable(.fetchFailed)
        case .timedOut: .unavailable(.timeout)
        }
    }

    private static func guardFetchOutcome(
        provider: UsageProvider,
        window: GuardWindow,
        config: CodexBarConfig,
        verbose: Bool,
        webTimeout: TimeInterval) async -> GuardFetchOutcome
    {
        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: config,
                verbose: verbose)
        } catch {
            return .unavailable(.accountResolution)
        }

        // Resolve the configured token account the same way `usage` does, so token-only
        // providers (e.g. Claude, z.ai, OpenAI) fetch their quota instead of returning unknown.
        let account: ProviderTokenAccount?
        do {
            account = try tokenContext.resolvedAccounts(for: provider).first
        } catch {
            return .unavailable(.accountResolution)
        }

        let browserDetection = BrowserDetection()
        let fetcher = UsageFetcher()
        let claudeFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)

        let env = tokenContext.environment(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            account: account)
        let settings = tokenContext.settingsSnapshot(for: provider, account: account)
        let baseSource = tokenContext.preferredSourceMode(for: provider)
        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: baseSource,
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
            // Guard is read-only: omit updater callbacks so refresh-dependent credentials fail unavailable.
            selectedTokenAccountID: account?.id)

        let outcome = await Self.fetchProviderUsage(provider: provider, context: fetchContext)
        if verbose {
            Self.printFetchAttempts(provider: provider, attempts: outcome.attempts)
        }

        switch outcome.result {
        case let .success(result):
            let usage = result.usage.scoped(to: provider)
            let rateWindow = window == .session ? usage.primary : usage.secondary
            guard let remaining = Self.guardRemainingHeadroom(for: rateWindow) else {
                return .unavailable(.windowUnavailable)
            }
            return .available(remaining)
        case .failure:
            return .unavailable(.fetchFailed)
        }
    }

    // MARK: - Output

    private struct GuardResultPayload: Encodable {
        let provider: String
        let window: String
        let remainingPercent: Double?
        let minimumRemainingPercent: Double
        let decision: String
        let exitCode: Int32
        let unavailableReason: String?

        private enum CodingKeys: String, CodingKey {
            case provider
            case window
            case remainingPercent
            case minimumRemainingPercent
            case decision
            case exitCode
            case unavailableReason
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.provider, forKey: .provider)
            try container.encode(self.window, forKey: .window)
            try container.encode(self.minimumRemainingPercent, forKey: .minimumRemainingPercent)
            try container.encode(self.decision, forKey: .decision)
            try container.encode(self.exitCode, forKey: .exitCode)
            if let remainingPercent = self.remainingPercent {
                try container.encode(remainingPercent, forKey: .remainingPercent)
            } else {
                try container.encodeNil(forKey: .remainingPercent)
            }
            if let unavailableReason = self.unavailableReason {
                try container.encode(unavailableReason, forKey: .unavailableReason)
            } else {
                try container.encodeNil(forKey: .unavailableReason)
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func emitGuardResult(
        provider: UsageProvider,
        window: GuardWindow,
        minimumRemainingPercent: Double,
        evaluation: GuardEvaluation,
        json: Bool,
        pretty: Bool)
    {
        if json {
            let payload = GuardResultPayload(
                provider: provider.rawValue,
                window: window.payloadValue,
                remainingPercent: evaluation.remainingPercent,
                minimumRemainingPercent: minimumRemainingPercent,
                decision: evaluation.decision.rawValue,
                exitCode: evaluation.exitCode,
                unavailableReason: evaluation.unavailableReason?.rawValue)
            Self.printJSON(payload, pretty: pretty)
            return
        }
        print(self.guardHumanLine(
            provider: provider,
            window: window,
            remainingPercent: evaluation.remainingPercent,
            minimumRemainingPercent: minimumRemainingPercent,
            decision: evaluation.decision,
            unavailableReason: evaluation.unavailableReason))
    }

    static func guardHumanLine(
        provider: UsageProvider,
        window: GuardWindow,
        remainingPercent: Double?,
        minimumRemainingPercent: Double,
        decision: GuardDecision,
        unavailableReason: GuardUnavailableReason? = nil) -> String
    {
        let remainingText = remainingPercent
            .map { "\(Self.guardPercentString($0)) remaining" } ?? "unknown"
        let verdict = switch decision {
        case .ok: "OK"
        case .blocked: "BLOCKED"
        case .unknown: "UNKNOWN"
        }
        let reasonText = unavailableReason.map { "; \($0.rawValue)" } ?? ""
        return "\(provider.rawValue) \(window.payloadValue): \(remainingText) — "
            + "\(verdict) (minimum \(Self.guardPercentString(minimumRemainingPercent))\(reasonText))"
    }

    private static func guardPercentString(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded))%"
        }
        return String(format: "%.1f%%", value)
    }
}
