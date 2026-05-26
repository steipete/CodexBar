import CodexBarCore
import Commander
import Foundation

struct UsageCommandContext {
    let format: OutputFormat
    let includeCredits: Bool
    let sourceModeOverride: ProviderSourceMode?
    let antigravityPlanDebug: Bool
    let augmentDebug: Bool
    let webDebugDumpHTML: Bool
    let webTimeout: TimeInterval
    let verbose: Bool
    let useColor: Bool
    let resetStyle: ResetTimeDisplayStyle
    let jsonOnly: Bool
    let includeAllCodexAccounts: Bool
    let fetcher: UsageFetcher
    let claudeFetcher: ClaudeUsageFetcher
    let browserDetection: BrowserDetection
}

struct UsageCommandOutput {
    var sections: [String] = []
    var payload: [ProviderPayload] = []
    var exitCode: ExitCode = .success
}

extension UsageCommandOutput {
    mutating func merge(_ other: UsageCommandOutput) {
        self.sections.append(contentsOf: other.sections)
        self.payload.append(contentsOf: other.payload)
        if other.exitCode != .success {
            self.exitCode = other.exitCode
        }
    }
}

extension CodexBarCLI {
    static func runUsage(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
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
        let antigravityPlanDebug = values.flags.contains("antigravityPlanDebug")
        let augmentDebug = values.flags.contains("augmentDebug")
        let webDebugDumpHTML = values.flags.contains("webDebugDumpHtml")
        let webTimeout = Self.decodeWebTimeout(from: values) ?? 60
        let verbose = values.flags.contains("verbose")
        let noColor = values.flags.contains("noColor")
        let useColor = Self.shouldUseColor(noColor: noColor, format: format)
        let resetStyle = Self.resetTimeDisplayStyleFromDefaults()
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

        if tokenSelection.usesOverride {
            guard providerList.count == 1 else {
                Self.exit(
                    code: .failure,
                    message: "Error: account selection requires a single provider.",
                    output: output,
                    kind: .args)
            }
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
                verbose: verbose)
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
            jsonOnly: output.jsonOnly,
            includeAllCodexAccounts: tokenSelection.allAccounts && providerList == [.codex],
            fetcher: fetcher,
            claudeFetcher: claudeFetcher,
            browserDetection: browserDetection)

        for p in providerList {
            let status = includeStatus ? await Self.fetchStatus(for: p) : nil
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

        switch format {
        case .text:
            if !sections.isEmpty {
                print(sections.joined(separator: "\n\n"))
            }
        case .json:
            Self.printJSON(payload, pretty: output.pretty)
        }

        Self.exit(code: exitCode, output: output, kind: exitCode == .success ? .runtime : .provider)
    }

    static func fetchUsageOutputs(
        provider: UsageProvider,
        status: ProviderStatusPayload?,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
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
        for account in selections {
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
        if accounts.isEmpty { return [nil] }
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
        } else if !command.jsonOnly {
            Self.writeStderr("Error: \(error.localizedDescription)\n")
        }
        return output
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

        #if !os(macOS)
        if Self.sourceModeRequiresWebSupport(
            effectiveSourceMode,
            provider: provider,
            environment: env,
            settings: settings)
        {
            return Self.webSourceUnsupportedOutput(
                provider: provider,
                account: account?.label ?? codexVisibleAccount?.menuDisplayName,
                source: effectiveSourceMode.rawValue,
                status: status,
                command: command)
        }
        #endif

        let fetchContext = ProviderFetchContext(
            runtime: .cli,
            sourceMode: effectiveSourceMode,
            includeCredits: command.includeCredits,
            webTimeout: command.webTimeout,
            webDebugDumpHTML: command.webDebugDumpHTML,
            verbose: command.verbose,
            env: env,
            settings: settings,
            fetcher: tokenContext.fetcher(base: command.fetcher, provider: provider, env: env),
            claudeFetcher: command.claudeFetcher,
            browserDetection: command.browserDetection,
            selectedTokenAccountID: account?.id,
            tokenAccountTokenUpdater: tokenContext.tokenUpdater(for: account))
        let outcome = await Self.fetchProviderUsage(
            provider: provider,
            context: fetchContext)
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
            if dashboard == nil, command.format == .json, provider == .codex {
                dashboard = Self.loadOpenAIDashboardIfAvailable(
                    usage: usage,
                    sourceLabel: result.sourceLabel,
                    context: fetchContext)
            }

            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let shouldDetectVersion = descriptor.cli.versionDetector != nil
                && result.strategyKind != ProviderFetchKind.webDashboard
            let version = Self.normalizeVersion(
                raw: shouldDetectVersion
                    ? Self.detectVersion(for: provider, browserDetection: command.browserDetection)
                    : nil)
            let source = result.sourceLabel
            let header = Self.makeHeader(provider: provider, version: version, source: source)
            let notes = Self.usageTextNotes(
                provider: provider,
                sourceMode: effectiveSourceMode,
                resolvedSourceLabel: source)

            switch command.format {
            case .text:
                var text = CLIRenderer.renderText(
                    provider: provider,
                    snapshot: usage,
                    credits: result.credits,
                    context: RenderContext(
                        header: header,
                        status: status,
                        useColor: command.useColor,
                        resetStyle: command.resetStyle,
                        notes: notes))
                if let dashboard, provider == .codex, effectiveSourceMode.usesWeb {
                    text += "\n" + Self.renderOpenAIWebDashboardText(dashboard)
                }
                output.sections.append(text)
            case .json:
                output.payload.append(ProviderPayload(
                    provider: provider,
                    account: account?.label ?? codexVisibleAccount?.menuDisplayName,
                    version: version,
                    source: source,
                    status: status,
                    usage: usage,
                    credits: result.credits,
                    antigravityPlanInfo: antigravityPlanInfo,
                    openaiDashboard: dashboard,
                    error: nil))
            }
        case let .failure(error):
            output.exitCode = Self.mapError(error)
            if command.format == .json {
                output.payload.append(Self.makeProviderErrorPayload(
                    provider: provider,
                    account: account?.label ?? codexVisibleAccount?.menuDisplayName,
                    source: effectiveSourceMode.rawValue,
                    status: status,
                    error: error,
                    kind: .provider))
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

        return output
    }

    private static func fetchAntigravityPlanInfoIfNeeded(
        provider: UsageProvider,
        command: UsageCommandContext) async -> AntigravityPlanInfoSummary?
    {
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
        account: String?,
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
                account: account,
                source: source,
                status: status,
                error: error,
                kind: .runtime))
        } else if !command.jsonOnly {
            Self.writeStderr("Error: \(error.localizedDescription)\n")
        }
        return output
    }

    static func sourceModeRequiresWebSupport(
        _ sourceMode: ProviderSourceMode,
        provider: UsageProvider,
        environment: [String: String]? = nil,
        settings: ProviderSettingsSnapshot? = nil) -> Bool
    {
        guard provider != .grok else {
            return false
        }
        if provider == .ollama,
           sourceMode == .auto,
           settings?.ollama?.cookieSource == .off
           || environment.map({ ProviderTokenResolver.ollamaToken(environment: $0) != nil }) == true
        {
            return false
        }
        return switch sourceMode {
        case .web:
            true
        case .auto:
            ProviderDescriptorRegistry.descriptor(for: provider).fetchPlan.sourceModes.contains(.web)
        case .cli, .oauth, .api:
            false
        }
    }
}
