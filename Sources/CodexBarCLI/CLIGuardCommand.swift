import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    /// Window selected by the `guard` command: `session` maps to the primary
    /// rate window, `weekly` maps to the secondary rate window.
    enum GuardWindow: String {
        case session
        case weekly

        var payloadValue: String { self.rawValue }
    }

    /// Pure gating outcome. Kept free of I/O so it is unit-testable off-network.
    enum GuardDecision: String {
        case ok
        case blocked
        case unknown
    }

    /// Pure decision core for `codexbar guard`.
    ///
    /// - `remainingPercent == nil` → `.unknown` (exit `0` when `failOpen`, else `2`).
    /// - `remainingPercent >= needPercent` → `.ok` (exit `0`).
    /// - otherwise → `.blocked` (exit `1`).
    static func evaluateGuard(
        remainingPercent: Double?,
        needPercent: Double,
        failOpen: Bool) -> (decision: GuardDecision, exitCode: Int32)
    {
        guard let remainingPercent else {
            return (.unknown, failOpen ? 0 : 2)
        }
        if remainingPercent >= needPercent {
            return (.ok, 0)
        }
        return (.blocked, 1)
    }

    static func runGuard(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        let json = values.flags.contains("json")
        let failOpen = values.flags.contains("failOpen")
        let verbose = values.flags.contains("verbose")

        guard let window = Self.decodeGuardWindow(from: values) else {
            Self.writeStderr("Error: --window must be session|weekly.\n")
            Self.platformExit(2)
        }

        let needPercent: Double
        switch Self.decodeGuardNeed(from: values) {
        case let .success(value):
            needPercent = value
        case .failure:
            Self.writeStderr("Error: --need must be a finite percent between 0 and 100.\n")
            Self.platformExit(2)
        }

        let providerList = Self.decodeProvider(from: values, config: config).asList
        guard providerList.count == 1, let provider = providerList.first else {
            Self.writeStderr("Error: guard requires exactly one --provider.\n")
            Self.platformExit(2)
        }

        let remaining = await Self.guardRemainingPercent(
            provider: provider,
            window: window,
            config: config,
            verbose: verbose)

        let evaluation = Self.evaluateGuard(
            remainingPercent: remaining,
            needPercent: needPercent,
            failOpen: failOpen)

        Self.emitGuardResult(
            provider: provider,
            window: window,
            remainingPercent: remaining,
            needPercent: needPercent,
            evaluation: evaluation,
            json: json,
            pretty: output.pretty)
        Self.platformExit(evaluation.exitCode)
    }

    // MARK: - Argument decoding

    static func decodeGuardWindow(from values: ParsedValues) -> GuardWindow? {
        guard let raw = values.options["window"]?.last else { return .session }
        return GuardWindow(rawValue: raw.lowercased())
    }

    static func decodeGuardNeed(from values: ParsedValues) -> Result<Double, CLIArgumentError> {
        guard let raw = values.options["need"]?.last else { return .success(10) }
        guard let value = Double(raw), value.isFinite, value >= 0, value <= 100 else {
            return .failure(CLIArgumentError("--need must be a finite percent between 0 and 100."))
        }
        return .success(value)
    }

    // MARK: - Fetch

    private static func guardRemainingPercent(
        provider: UsageProvider,
        window: GuardWindow,
        config: CodexBarConfig,
        verbose: Bool) async -> Double?
    {
        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: config,
                verbose: verbose)
        } catch {
            return nil
        }

        let browserDetection = BrowserDetection()
        let fetcher = UsageFetcher()
        let claudeFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)

        let env = tokenContext.environment(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            account: nil)
        let settings = tokenContext.settingsSnapshot(for: provider, account: nil)
        let baseSource = tokenContext.preferredSourceMode(for: provider)
        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: baseSource,
            provider: provider,
            account: nil)

        let fetchContext = ProviderFetchContext(
            runtime: .cli,
            sourceMode: effectiveSourceMode,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: verbose,
            env: env,
            settings: settings,
            fetcher: tokenContext.fetcher(base: fetcher, provider: provider, env: env),
            claudeFetcher: claudeFetcher,
            browserDetection: browserDetection,
            selectedTokenAccountID: nil,
            tokenAccountTokenUpdater: tokenContext.tokenUpdater(for: nil),
            providerManualTokenUpdater: tokenContext.manualTokenUpdater())

        let outcome = await ProviderInteractionContext.$current.withValue(.background) {
            await Self.fetchProviderUsage(provider: provider, context: fetchContext)
        }

        switch outcome.result {
        case let .success(result):
            let usage = result.usage.scoped(to: provider)
            let rateWindow: RateWindow? = window == .session ? usage.primary : usage.secondary
            guard let rateWindow else { return nil }
            return 100 - rateWindow.usedPercent
        case .failure:
            return nil
        }
    }

    // MARK: - Output

    private struct GuardResultPayload: Encodable {
        let provider: String
        let window: String
        let remainingPercent: Double?
        let needPercent: Double
        let decision: String
        let exitCode: Int32
    }

    private static func emitGuardResult(
        provider: UsageProvider,
        window: GuardWindow,
        remainingPercent: Double?,
        needPercent: Double,
        evaluation: (decision: GuardDecision, exitCode: Int32),
        json: Bool,
        pretty: Bool)
    {
        if json {
            let payload = GuardResultPayload(
                provider: provider.rawValue,
                window: window.payloadValue,
                remainingPercent: remainingPercent,
                needPercent: needPercent,
                decision: evaluation.decision.rawValue,
                exitCode: evaluation.exitCode)
            Self.printJSON(payload, pretty: pretty)
            return
        }
        print(Self.guardHumanLine(
            provider: provider,
            window: window,
            remainingPercent: remainingPercent,
            needPercent: needPercent,
            decision: evaluation.decision))
    }

    static func guardHumanLine(
        provider: UsageProvider,
        window: GuardWindow,
        remainingPercent: Double?,
        needPercent: Double,
        decision: GuardDecision) -> String
    {
        let remainingText = remainingPercent
            .map { "\(Self.guardPercentString($0)) remaining" } ?? "unknown"
        let verdict: String = switch decision {
        case .ok: "OK"
        case .blocked: "BLOCKED"
        case .unknown: "UNKNOWN"
        }
        return "\(provider.rawValue) \(window.payloadValue): \(remainingText) — "
            + "\(verdict) (need \(Self.guardPercentString(needPercent)))"
    }

    private static func guardPercentString(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded))%"
        }
        return String(format: "%.1f%%", value)
    }
}
