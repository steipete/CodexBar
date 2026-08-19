import CodexBarCore
import Commander
import Foundation

struct UsageCommandContext {
    let format: OutputFormat
    let includeCredits: Bool
    var sourceModeOverride: ProviderSourceMode?
    let antigravityPlanDebug: Bool
    let augmentDebug: Bool
    let webDebugDumpHTML: Bool
    let webTimeout: TimeInterval
    let verbose: Bool
    let useColor: Bool
    let resetStyle: ResetTimeDisplayStyle
    let weeklyWorkDays: Int?
    let jsonOnly: Bool
    let includeAllCodexAccounts: Bool
    let fetcher: UsageFetcher
    let claudeFetcher: ClaudeUsageFetcher
    let browserDetection: BrowserDetection
    /// A verifier-only route that invokes the same app provider pipeline while retaining CLI JSON output.
    var providerRuntime: ProviderRuntime = .cli
    /// True for long-lived hosts (`codexbar serve`) that keep warm provider
    /// helper sessions (such as the managed Antigravity `agy` process) alive
    /// between fetches instead of resetting after each one-shot fetch.
    var persistCLISessions: Bool = false
    var persistentCLISessionIdleWindow: TimeInterval?
    var cardsLayout: Bool = false
}

struct UsageCommandOutput {
    var sections: [String] = []
    var payload: [ProviderPayload] = []
    var cards: [CLICardModel] = []
    var cardFailures: [CLICardFailure] = []
    var exitCode: ExitCode = .success
}

private struct UsageSuccessRenderInput {
    let provider: UsageProvider
    let accountLabel: String?
    let cacheAccountKey: String?
    let version: String?
    let source: String
    let status: ProviderStatusPayload?
    let usage: UsageSnapshot
    let credits: CreditsSnapshot?
    let antigravityPlanInfo: AntigravityPlanInfoSummary?
    let dashboard: OpenAIDashboardSnapshot?
    let effectiveSourceMode: ProviderSourceMode
    let command: UsageCommandContext
    let diagnostic: String?
    let notes: [String]
}

extension UsageCommandOutput {
    mutating func merge(_ other: UsageCommandOutput) {
        self.sections.append(contentsOf: other.sections)
        self.payload.append(contentsOf: other.payload)
        self.cards.append(contentsOf: other.cards)
        self.cardFailures.append(contentsOf: other.cardFailures)
        if other.exitCode != .success {
            self.exitCode = other.exitCode
        }
    }
}

extension CodexBarCLI {
    static func runUsage(_ values: ParsedValues) async {
        let output = Self.resolveUsageOutputPreferences(from: values)
        let config = Self.loadConfig(output: output)
        let provider = Self.decodeProvider(from: values, config: config)
        let format = output.format
        let includeCredits = format == .json ? true : !values.flags.contains("noCredits")
        let includeStatus = values.flags.contains("status")
        let sourceModeRaw = values.options["source"]?.last
        let parsedSourceMode = Self.decodeSourceMode(from: values)
        if sourceModeRaw != nil, parsedSourceMode == nil {
            Self.exit(
                code: .failure,
                message: "Error: --source must be auto|web|cli|oauth|api.",
                output: output,
                kind: .args)
        }
        let antigravityPlanDebug = values.flags.contains("antigravityPlanDebug"),
            augmentDebug = values.flags.contains("augmentDebug")
        let appAutoVerifier = values.flags.contains("appAutoVerifier")
        let webDebugDumpHTML = values.flags.contains("webDebugDumpHtml")
        let webTimeout: TimeInterval
        do {
            webTimeout = try Self.decodeWebTimeout(from: values) ?? 60
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .args)
        }
        let verbose = values.flags.contains("verbose"), noColor = values.flags.contains("noColor")
        let useColor = Self.shouldUseColor(noColor: noColor, format: format)
        let resetStyle = Self.resetTimeDisplayStyleFromDefaults()
        let weeklyWorkDays = Self.weeklyProgressWorkDaysFromDefaults()
        let providerList = provider.asList

        let tokenSelection: TokenAccountCLISelection
        do {
            tokenSelection = try Self.decodeTokenAccountSelection(from: values)
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .args)
        }

        if tokenSelection.allAccounts, tokenSelection.label != nil || tokenSelection.index != nil {
            Self.exit(
                code: .failure,
                message: "Error: --all-accounts cannot be combined with --account or --account-index.",
                output: output,
                kind: .args)
        }

        if let message = Self.appAutoVerifierArgumentError(
            enabled: appAutoVerifier,
            providers: providerList,
            sourceMode: parsedSourceMode,
            tokenSelection: tokenSelection)
        {
            Self.exit(
                code: .failure,
                message: "Error: \(message)",
                output: output,
                kind: .args)
        }

        if tokenSelection.usesOverride {
            guard providerList.count == 1 else {
                Self.exit(
                    code: .failure,
                    message: "Error: account selection requires a single provider.",
                    output: output,
                    kind: .args)
            }
            // Provider-specific by design: Codex exposes reconciled accounts beyond config token accounts.
            let supportsAllCodexAccounts = providerList[0] == .codex
                && tokenSelection.allAccounts
                && tokenSelection.label == nil
                && tokenSelection.index == nil
            guard supportsAllCodexAccounts || TokenAccountSupportCatalog.support(for: providerList[0]) != nil else {
                Self.exit(
                    code: .failure,
                    message: "Error: \(providerList[0].rawValue) does not support token accounts.",
                    output: output,
                    kind: .args)
            }
        }

        let browserDetection = BrowserDetection()
        let fetcher = UsageFetcher()
        let claudeFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)
        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: tokenSelection,
                config: config,
                verbose: verbose,
                resolutionScope: appAutoVerifier ? .ambientAccount : .configuredAccounts)
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .config)
        }

        var sections: [String] = []
        var payload: [ProviderPayload] = []
        var exitCode: ExitCode = .success
        let command = UsageCommandContext(
            format: format,
            includeCredits: includeCredits,
            sourceModeOverride: parsedSourceMode,
            antigravityPlanDebug: antigravityPlanDebug,
            augmentDebug: augmentDebug,
            webDebugDumpHTML: webDebugDumpHTML,
            webTimeout: webTimeout,
            verbose: verbose,
            useColor: useColor,
            resetStyle: resetStyle,
            weeklyWorkDays: weeklyWorkDays,
            jsonOnly: output.jsonOnly,
            includeAllCodexAccounts: tokenSelection.allAccounts && providerList == [.codex],
            fetcher: fetcher,
            claudeFetcher: claudeFetcher,
            browserDetection: browserDetection,
            providerRuntime: appAutoVerifier ? .app : .cli)

        for p in providerList {
            let status = includeStatus ? await Self.fetchStatus(for: p) : nil
            if appAutoVerifier {
                // Background app Auto intentionally launches the opaque Claude owner CLI only after a successful
                // user-initiated fetch has established this process's account-scoped availability marker. Recreate
                // that real app lifecycle before exercising the background route; discard the foreground payload.
                var establishmentCommand = command
                establishmentCommand.sourceModeOverride = .cli
                let establishment = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await Self.fetchUsageOutputs(
                        provider: p,
                        status: status,
                        tokenContext: tokenContext,
                        command: establishmentCommand)
                }
                if establishment.exitCode != .success {
                    exitCode = establishment.exitCode
                    sections.append(contentsOf: establishment.sections)
                    payload.append(contentsOf: establishment.payload)
                    continue
                }
            }
            // CLI usage should not clear Keychain cooldowns or attempt interactive Keychain prompts.
            let output = await ProviderInteractionContext.$current.withValue(.background) {
                await Self.fetchUsageOutputs(
                    provider: p,
                    status: status,
                    tokenContext: tokenContext,
                    command: command)
            }
            if output.exitCode != .success {
                exitCode = output.exitCode
            }
            sections.append(contentsOf: output.sections)
            payload.append(contentsOf: output.payload)
        }

        Self.printUsageOutput(
            format: format,
            toonRequested: output.toonRequested,
            sections: sections,
            payload: payload,
            pretty: output.pretty)

        Self.exit(code: exitCode, output: output, kind: exitCode == .success ? .runtime : .provider)
    }

    /// TOON piggybacks on the JSON fetch/render pipeline (same data, denser rendering at print time)
    /// rather than being a first-class `OutputFormat` case, so it doesn't ripple into every other
    /// command's exhaustive `switch format` sites. `toonRequested` also travels on the returned
    /// preferences so early-exit error paths (`Self.exit`, `Self.loadConfig`) render TOON instead of
    /// silently falling back to JSON. `allowsToon` is opt-in here and nowhere else: `cost`, `cache`,
    /// `config`, `hooks`, and `diagnose` advertise only `text | json`, so they keep the legacy
    /// decoder that ignores unrecognized `--format` values.
    static func resolveUsageOutputPreferences(from values: ParsedValues) -> CLIOutputPreferences {
        CLIOutputPreferences.from(values: values, allowsToon: true)
    }

    private static func printUsageOutput(
        format: OutputFormat,
        toonRequested: Bool,
        sections: [String],
        payload: [ProviderPayload],
        pretty: Bool)
    {
        if toonRequested {
            print(ToonFormatter.encode(payload))
            return
        }
        switch format {
        case .text:
            if !sections.isEmpty {
                print(sections.joined(separator: "\n\n"))
            }
        case .json:
            printJSON(payload, pretty: pretty)
        }
    }

    static func appAutoVerifierArgumentError(
        enabled: Bool,
        providers: [UsageProvider],
        sourceMode: ProviderSourceMode?,
        tokenSelection: TokenAccountCLISelection) -> String?
    {
        guard enabled else { return nil }
        // Provider-specific by design: this hidden verifier recreates Claude's owner-CLI lifecycle only.
        guard providers == [.claude], sourceMode == .auto else {
            return "--app-auto-verifier requires --provider claude --source auto."
        }
        guard !tokenSelection.usesOverride else {
            return "--app-auto-verifier does not accept token-account selection."
        }
        return nil
    }

    static func fetchUsageOutputs(
        provider: UsageProvider,
        status: ProviderStatusPayload?,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        // Provider-specific by design: Codex can enumerate reconciled live, managed, and profile-home accounts.
        if provider == .codex, command.includeAllCodexAccounts {
            var output = UsageCommandOutput()
            let accounts = tokenContext.visibleCodexAccounts().visibleAccounts
            let selections: [CodexVisibleAccount?] = accounts.isEmpty ? [nil] : accounts.map { Optional($0) }
            for visibleAccount in selections {
                let result = await Self.fetchUsageOutput(
                    provider: provider,
                    account: nil,
                    codexVisibleAccount: visibleAccount,
                    status: status,
                    tokenContext: tokenContext,
                    command: command)
                output.merge(result)
            }
            return output
        }

        let accounts: [ProviderTokenAccount]
        do {
            accounts = try tokenContext.resolvedAccounts(for: provider)
        } catch {
            return Self.usageOutputForAccountResolutionError(
                provider: provider,
                status: status,
                command: command,
                error: error)
        }

        let selections = Self.accountSelections(from: accounts)
        var output = UsageCommandOutput()
        let accountRefreshDelay = TokenAccountSupportCatalog
            .support(for: provider)?.minimumDelayBetweenAccountRefreshes
        for (index, account) in selections.enumerated() {
            if index > 0, let accountRefreshDelay {
                do {
                    try await Task.sleep(for: accountRefreshDelay)
                } catch {
                    return output
                }
            }
            let result = await Self.fetchUsageOutput(
                provider: provider,
                account: account,
                status: status,
                tokenContext: tokenContext,
                command: command)
            output.merge(result)
        }
        return output
    }

    private static func accountSelections(from accounts: [ProviderTokenAccount]) -> [ProviderTokenAccount?] {
        if accounts.isEmpty {
            return [nil]
        }
        return accounts.map { Optional($0) }
    }

    private static func usageOutputForAccountResolutionError(
        provider: UsageProvider,
        status: ProviderStatusPayload?,
        command: UsageCommandContext,
        error: Error) -> UsageCommandOutput
    {
        var output = UsageCommandOutput()
        output.exitCode = .failure
        if command.format == .json {
            output.payload.append(Self.makeProviderErrorPayload(
                provider: provider,
                account: nil,
                source: command.sourceModeOverride?.rawValue ?? "auto",
                status: status,
                error: error,
                kind: .provider))
        } else if command.cardsLayout {
            output.cardFailures.append(CLICardFailure(
                provider: provider,
                accountLabel: nil,
                message: error.localizedDescription))
        } else if !command.jsonOnly {
            Self.writeStderr("Error: \(error.localizedDescription)\n")
        }
        return output
    }

    // swiftlint:disable:next function_parameter_count
    private static func makeUsagePayload(
        provider: UsageProvider,
        accountLabel: String?,
        cacheAccountKey: String?,
        version: String?,
        source: String,
        status: ProviderStatusPayload?,
        usage: UsageSnapshot,
        credits: CreditsSnapshot?,
        antigravityPlanInfo: AntigravityPlanInfoSummary?,
        dashboard: OpenAIDashboardSnapshot?,
        diagnostic: String?,
        weeklyWorkDays: Int?) -> ProviderPayload
    {
        ProviderPayload(
            provider: provider,
            account: accountLabel,
            cacheAccountKey: cacheAccountKey,
            version: version,
            source: source,
            status: status,
            usage: usage,
            credits: credits,
            antigravityPlanInfo: antigravityPlanInfo,
            openaiDashboard: dashboard,
            error: nil,
            diagnostic: diagnostic,
            pace: CLIRenderer.providerPacePayload(provider: provider, snapshot: usage, weeklyWorkDays: weeklyWorkDays))
    }

    private static func appendSuccessRenderOutput(
        _ input: UsageSuccessRenderInput,
        output: inout UsageCommandOutput)
    {
        switch input.command.format {
        case .text:
            if input.command.cardsLayout {
                output.cards.append(CLICardsRenderer.makeCard(CLICardBuildInput(
                    provider: input.provider,
                    snapshot: input.usage,
                    credits: input.credits,
                    source: input.source,
                    status: input.status,
                    notes: input.notes,
                    useColor: input.command.useColor,
                    resetStyle: input.command.resetStyle,
                    weeklyWorkDays: input.command.weeklyWorkDays,
                    now: Date())))
            } else {
                var text = CLIRenderer.renderText(
                    provider: input.provider,
                    snapshot: input.usage,
                    credits: input.credits,
                    context: RenderContext(
                        header: Self.makeHeader(
                            provider: input.provider,
                            version: input.version,
                            source: input.source),
                        status: input.status,
                        useColor: input.command.useColor,
                        resetStyle: input.command.resetStyle,
                        weeklyWorkDays: input.command.weeklyWorkDays,
                        notes: input.notes))
                // Provider-specific by design: OpenAI dashboard payloads are behavioral Codex fetch results.
                if let dashboard = input.dashboard, input.provider == .codex, input.effectiveSourceMode.usesWeb {
                    text += "\n" + Self.renderOpenAIWebDashboardText(dashboard)
                }
                output.sections.append(text)
            }
        case .json:
            output.payload.append(self.makeUsagePayload(
                provider: input.provider,
                accountLabel: input.accountLabel,
                cacheAccountKey: input.cacheAccountKey,
                version: input.version,
                source: input.source,
                status: input.status,
                usage: input.usage,
                credits: input.credits,
                antigravityPlanInfo: input.antigravityPlanInfo,
                dashboard: input.dashboard,
                diagnostic: input.diagnostic,
                weeklyWorkDays: input.command.weeklyWorkDays))
        }
    }

    private static func fetchUsageOutput(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        codexVisibleAccount: CodexVisibleAccount? = nil,
        status: ProviderStatusPayload?,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        var output = UsageCommandOutput()
        let env = tokenContext.environment(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            account: account,
            codexActiveSourceOverride: codexVisibleAccount?.selectionSource)
        let settings = tokenContext.settingsSnapshot(
            for: provider,
            account: account,
            codexActiveSourceOverride: codexVisibleAccount?.selectionSource)
        let configSource = tokenContext.preferredSourceMode(for: provider)
        let baseSource = command.sourceModeOverride ?? configSource
        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: baseSource,
            provider: provider,
            account: account)
        let cacheAccountKey = Self.usageCacheAccountKey(
            provider: provider,
            account: account,
            codexVisibleAccount: codexVisibleAccount)

        #if !os(macOS)
        if Self.sourceModeRequiresWebSupport(
            effectiveSourceMode,
            provider: provider,
            environment: env,
            settings: settings)
        {
            return Self.webSourceUnsupportedOutput(
                provider: provider,
                account: (
                    label: account?.label ?? codexVisibleAccount?.menuDisplayName,
                    cacheKey: cacheAccountKey),
                source: effectiveSourceMode.rawValue,
                status: status,
                command: command)
        }
        #endif

        let resolvedCLIVersion = provider == .codex
            ? Self.detectVersion(for: provider, browserDetection: command.browserDetection)
            : nil
        let fetchContext = ProviderFetchContext(
            runtime: command.providerRuntime,
            sourceMode: effectiveSourceMode,
            includeCredits: command.includeCredits,
            requiresOptionalUsageCompleteness: true,
            webTimeout: command.webTimeout,
            webDebugDumpHTML: command.webDebugDumpHTML,
            verbose: command.verbose,
            env: env,
            settings: settings,
            fetcher: tokenContext.fetcher(base: command.fetcher, provider: provider, env: env),
            claudeFetcher: command.claudeFetcher,
            browserDetection: command.browserDetection,
            selectedTokenAccountID: account?.id,
            tokenAccountTokenUpdater: tokenContext.tokenUpdater(for: account),
            providerManualTokenUpdater: tokenContext.manualTokenUpdater(),
            persistsCLISessions: Self.persistsCLISessions(provider: provider, command: command),
            persistentCLISessionIdleWindow: command.persistentCLISessionIdleWindow,
            resolvedCLIVersion: resolvedCLIVersion)
        let outcome = await Self.fetchProviderUsage(provider: provider, context: fetchContext)
        if command.verbose, !command.jsonOnly {
            Self.printFetchAttempts(provider: provider, attempts: outcome.attempts)
        }

        switch outcome.result {
        case let .success(result):
            let antigravityPlanInfo = await Self.fetchAntigravityPlanInfoIfNeeded(
                provider: provider,
                command: command)
            await Self.emitAugmentDebugIfNeeded(provider: provider, command: command)

            var usage = result.usage.scoped(to: provider)
            if let account {
                usage = tokenContext.applyAccountLabel(usage, provider: provider, account: account)
            } else if let codexVisibleAccount {
                usage = tokenContext.applyCodexVisibleAccountLabel(usage, account: codexVisibleAccount)
            }

            var dashboard = result.dashboard
            // Provider-specific by design: JSON preserves Codex's optional behavioral dashboard payload.
            if dashboard == nil, command.format == .json, provider == .codex {
                dashboard = Self.loadOpenAIDashboardIfAvailable(
                    usage: usage,
                    sourceLabel: result.sourceLabel,
                    context: fetchContext)
            }

            let shouldDetectVersion = Self.shouldDetectVersion(provider: provider, result: result)
            let version = Self.normalizeVersion(
                raw: shouldDetectVersion
                    ? (resolvedCLIVersion
                        ?? Self.detectVersion(for: provider, browserDetection: command.browserDetection))
                    : nil)
            let source = result.sourceLabel
            let notes = Self.usageTextNotes(
                provider: provider,
                sourceMode: effectiveSourceMode,
                resolvedSourceLabel: source,
                dataConfidence: usage.dataConfidence) + (result.diagnostic.map { [$0] } ?? [])

            Self.appendSuccessRenderOutput(
                UsageSuccessRenderInput(
                    provider: provider,
                    accountLabel: account?.label ?? codexVisibleAccount?.menuDisplayName,
                    cacheAccountKey: cacheAccountKey,
                    version: version,
                    source: source,
                    status: status,
                    usage: usage,
                    credits: result.credits,
                    antigravityPlanInfo: antigravityPlanInfo,
                    dashboard: dashboard,
                    effectiveSourceMode: effectiveSourceMode,
                    command: command,
                    diagnostic: result.diagnostic,
                    notes: notes),
                output: &output)
        case let .failure(error):
            output.exitCode = Self.mapError(error)
            if command.format == .json {
                output.payload.append(Self.makeProviderErrorPayload(
                    provider: provider,
                    account: account?.label ?? codexVisibleAccount?.menuDisplayName,
                    cacheAccountKey: cacheAccountKey,
                    source: effectiveSourceMode.rawValue,
                    status: status,
                    error: error,
                    kind: .provider))
            } else if command.cardsLayout {
                output.cardFailures.append(CLICardFailure(
                    provider: provider,
                    accountLabel: account?.label ?? codexVisibleAccount?.menuDisplayName,
                    message: error.localizedDescription))
            } else if !command.jsonOnly {
                if let accountLabel = account?.label ?? codexVisibleAccount?.menuDisplayName {
                    Self.writeStderr(
                        "Error (\(provider.rawValue) - \(accountLabel)): \(error.localizedDescription)\n")
                } else {
                    Self.writeStderr("Error: \(error.localizedDescription)\n")
                }
                if let summary = Self.kiloAutoFallbackSummary(
                    provider: provider,
                    sourceMode: effectiveSourceMode,
                    attempts: outcome.attempts)
                {
                    Self.writeStderr("\(summary)\n")
                }
            }
        }

        return await Self.finishUsageOutput(output, provider: provider, command: command)
    }

    static func shouldDetectVersion(provider: UsageProvider, result: ProviderFetchResult) -> Bool {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        guard descriptor.cli.versionDetector != nil else { return false }
        guard result.strategyKind != .webDashboard else { return false }
        // Provider-specific by design: Claude OAuth is in-process and has no CLI version to report.
        return !(provider == .claude && result.strategyKind == .oauth)
    }

    private static func holdsAntigravitySession(
        provider: UsageProvider,
        command: UsageCommandContext) -> Bool
    {
        self.holdsAntigravityCLISessionForPlanDebug(
            provider: provider,
            planDebugEnabled: command.antigravityPlanDebug,
            jsonOnly: command.jsonOnly,
            persistsCLISessions: command.persistCLISessions)
    }

    private static func persistsCLISessions(
        provider: UsageProvider,
        command: UsageCommandContext) -> Bool
    {
        command.persistCLISessions || self.holdsAntigravitySession(provider: provider, command: command)
    }

    static func holdsAntigravityCLISessionForPlanDebug(
        provider: UsageProvider,
        planDebugEnabled: Bool,
        jsonOnly: Bool,
        persistsCLISessions: Bool) -> Bool
    {
        // Provider-specific by design: --antigravity-plan-debug interrogates its persistent helper session.
        provider == .antigravity
            && planDebugEnabled
            && !jsonOnly
            && !persistsCLISessions
    }

    private static func finishUsageOutput(
        _ output: UsageCommandOutput,
        provider: UsageProvider,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        if self.holdsAntigravitySession(provider: provider, command: command) {
            await ProviderCLISessionLifecycle.shutdownPersistentSessions()
        }
        return output
    }

    private static func fetchAntigravityPlanInfoIfNeeded(
        provider: UsageProvider,
        command: UsageCommandContext) async -> AntigravityPlanInfoSummary?
    {
        // Provider-specific by design: --antigravity-plan-debug requests its plan-only diagnostic.
        guard command.antigravityPlanDebug,
              provider == .antigravity,
              !command.jsonOnly
        else {
            return nil
        }
        let info = try? await AntigravityStatusProbe().fetchPlanInfoSummary()
        if command.format == .text, let info {
            Self.printAntigravityPlanInfo(info)
        }
        return info
    }

    private static func emitAugmentDebugIfNeeded(
        provider: UsageProvider,
        command: UsageCommandContext) async
    {
        // Provider-specific by design: --augment-debug emits Augment's explicit diagnostic dump.
        guard command.augmentDebug, provider == .augment else { return }
        #if os(macOS)
        let dump = await AugmentStatusProbe.latestDumps()
        if command.format == .text, !dump.isEmpty, !command.jsonOnly {
            Self.writeStderr("Augment API responses:\n\(dump)\n")
        }
        #endif
    }

    private static func webSourceUnsupportedOutput(
        provider: UsageProvider,
        account: (label: String?, cacheKey: String?),
        source: String,
        status: ProviderStatusPayload?,
        command: UsageCommandContext) -> UsageCommandOutput
    {
        var output = UsageCommandOutput()
        let error = NSError(
            domain: "CodexBarCLI",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Error: selected source requires web support and is only supported on macOS."])
        output.exitCode = .failure
        if command.format == .json {
            output.payload.append(Self.makeProviderErrorPayload(
                provider: provider,
                account: account.label,
                cacheAccountKey: account.cacheKey,
                source: source,
                status: status,
                error: error,
                kind: .runtime))
        } else if command.cardsLayout {
            output.cardFailures.append(CLICardFailure(
                provider: provider,
                accountLabel: account.label,
                message: error.localizedDescription))
        } else if !command.jsonOnly {
            Self.writeStderr("Error: \(error.localizedDescription)\n")
        }
        return output
    }

    static func usageCacheAccountKey(
        provider _: UsageProvider,
        account: ProviderTokenAccount?,
        codexVisibleAccount: CodexVisibleAccount?) -> String?
    {
        if let account {
            return "token:\(account.id.uuidString.lowercased())"
        }
        if let codexVisibleAccount {
            if let workspaceAccountID = codexVisibleAccount.workspaceAccountID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !workspaceAccountID.isEmpty,
                !codexVisibleAccount.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let email = codexVisibleAccount.email
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return "codex:workspace:\(workspaceAccountID):email:\(email)"
            }
            if let storedAccountID = codexVisibleAccount.storedAccountID {
                return "codex:stored:\(storedAccountID.uuidString.lowercased())"
            }
            if let authFingerprint = codexVisibleAccount.authFingerprint {
                return "codex:auth:\(authFingerprint)"
            }
            return nil
        }
        return nil
    }

    static func sourceModeRequiresWebSupport(
        _ sourceMode: ProviderSourceMode,
        provider: UsageProvider,
        environment: [String: String]? = nil,
        settings: ProviderSettingsSnapshot? = nil) -> Bool
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        if descriptor.cli.isBrowserSupportExempt(
            sourceMode: sourceMode,
            environment: environment,
            settings: settings)
        {
            return false
        }
        return switch sourceMode {
        case .web:
            true
        case .auto:
            descriptor.fetchPlan.sourceModes.contains(.web)
        case .cli, .oauth, .api:
            false
        }
    }
}
