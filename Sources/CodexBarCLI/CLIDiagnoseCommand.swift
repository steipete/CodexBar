import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runDiagnose(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)

        let format = Self.decodeFormat(from: values)
        guard format == .json else {
            Self.exit(
                code: .failure,
                message: "Error: only JSON format is supported for diagnose",
                output: output,
                kind: .args)
        }

        let providerSelection: ProviderSelection
        if let rawProvider = values.options["provider"]?.last {
            guard let parsed = ProviderSelection(argument: rawProvider) else {
                Self.exit(
                    code: .failure,
                    message: "Error: unknown provider '\(rawProvider)'",
                    output: output,
                    kind: .args)
            }
            providerSelection = parsed
        } else {
            providerSelection = Self.providerSelection(rawOverride: nil, enabled: config.enabledProviders())
        }

        let providers = providerSelection.asList
        let pretty = values.flags.contains("pretty")
        let verbose = values.flags.contains("verbose")
        let outputPath = values.options["output"]?.last
        let browserDetection = BrowserDetection()
        let baseFetcher = UsageFetcher()

        let tokenSelection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: tokenSelection,
                config: config,
                verbose: verbose)
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .config)
        }

        var diagnostics: [ProviderDiagnosticExport] = []
        diagnostics.reserveCapacity(providers.count)
        for provider in providers {
            await diagnostics.append(Self.makeDiagnosticExport(
                provider: provider,
                tokenContext: tokenContext,
                baseFetcher: baseFetcher,
                browserDetection: browserDetection,
                verbose: verbose))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : .sortedKeys

        do {
            let data: Data = if diagnostics.count == 1, let diagnostic = diagnostics.first {
                try encoder.encode(diagnostic)
            } else {
                try encoder.encode(ProviderDiagnosticBatchExport(
                    timestamp: Date(),
                    diagnostics: diagnostics))
            }
            var jsonString = String(data: data, encoding: .utf8) ?? "{}"
            jsonString = LogRedactor.redact(jsonString)
            if let outputPath, !outputPath.isEmpty {
                try Self.writeDiagnosticExport(jsonString, to: outputPath)
            } else {
                print(jsonString)
            }
        } catch {
            Self.exit(
                code: .failure,
                message: "Error encoding diagnostic: \(error.localizedDescription)",
                output: output,
                kind: .runtime)
        }

        Self.exit(code: .success, output: output, kind: .runtime)
    }

    static func writeDiagnosticExport(_ jsonString: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if !parent.path.isEmpty {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true)
        }
        try jsonString.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension CodexBarCLI {
    private static func makeDiagnosticExport(
        provider: UsageProvider,
        tokenContext: TokenAccountCLIContext,
        baseFetcher: UsageFetcher,
        browserDetection: BrowserDetection,
        verbose: Bool) async -> ProviderDiagnosticExport
    {
        let account = ((try? tokenContext.resolvedAccounts(for: provider)) ?? []).first
        let env = tokenContext.environment(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            account: account,
            codexActiveSourceOverride: nil)
        let settings = tokenContext.settingsSnapshot(
            for: provider,
            account: account,
            codexActiveSourceOverride: nil)
        let preferredSourceMode = tokenContext.preferredSourceMode(for: provider)
        let sourceMode = tokenContext.effectiveSourceMode(
            base: preferredSourceMode,
            provider: provider,
            account: account)
        let fetcher = tokenContext.fetcher(base: baseFetcher, provider: provider, env: env)
        let fetchContext = ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: true,
            includeOptionalUsage: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: verbose,
            env: env,
            settings: settings,
            fetcher: fetcher,
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: account?.id,
            tokenAccountTokenUpdater: tokenContext.tokenUpdater(for: account),
            providerManualTokenUpdater: tokenContext.manualTokenUpdater())
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let outcome = await Self.fetchProviderUsage(provider: provider, context: fetchContext)
        return ProviderDiagnosticExportBuilder.build(.init(
            provider: provider,
            descriptor: descriptor,
            outcome: outcome,
            sourceMode: sourceMode,
            settings: settings,
            auth: Self.diagnosticAuthSummary(
                provider: provider,
                account: account,
                config: tokenContext.config.providerConfig(for: provider),
                environment: env,
                settings: settings),
            appVersion: Self.currentVersion()))
    }

    static func diagnosticAuthSummary(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        config: ProviderConfig?,
        environment: [String: String],
        settings: ProviderSettingsSnapshot?) -> ProviderDiagnosticAuthSummary
    {
        if provider == .minimax {
            let authMode = self.resolveMiniMaxAuthMode(environment: environment, settings: settings)
            return ProviderDiagnosticAuthSummary(
                configured: authMode.usesAPIToken || authMode.usesCookie,
                modes: authMode == .none ? [] : [authMode.description])
        }

        var modes: [String] = []
        if account != nil {
            modes.append("tokenAccount")
        }
        let hasConfigAPIAuth = if provider == .bedrock {
            config?.sanitizedAPIKey != nil && config?.sanitizedSecretKey != nil
        } else {
            config?.sanitizedAPIKey != nil || config?.sanitizedSecretKey != nil
        }
        if hasConfigAPIAuth {
            modes.append("api")
        }
        if Self.environmentAPIAuthConfigured(provider: provider, environment: environment), !modes.contains("api") {
            modes.append("api")
        }
        if config?.sanitizedCookieHeader != nil {
            modes.append("web")
        }
        if Self.environmentWebAuthConfigured(provider: provider, environment: environment), !modes.contains("web") {
            modes.append("web")
        }
        return ProviderDiagnosticAuthSummary(
            configured: !modes.isEmpty,
            modes: modes)
    }

    private static func environmentAPIAuthConfigured(
        provider: UsageProvider,
        environment: [String: String]) -> Bool
    {
        self.environmentCoreAPIAuthConfigured(provider: provider, environment: environment) ||
            self.environmentExtendedAPIAuthConfigured(provider: provider, environment: environment)
    }

    private static func environmentCoreAPIAuthConfigured(
        provider: UsageProvider,
        environment: [String: String]) -> Bool
    {
        switch provider {
        case .alibaba:
            AlibabaCodingPlanSettingsReader.apiToken(environment: environment) != nil
        case .azureopenai:
            AzureOpenAISettingsReader.apiKey(environment: environment) != nil
        case .bedrock:
            BedrockSettingsReader.hasCredentials(environment: environment)
        case .claude:
            ClaudeAdminAPISettingsReader.apiKey(environment: environment) != nil
        case .codebuff:
            CodebuffSettingsReader.apiKey(environment: environment) != nil
        case .chutes:
            ChutesSettingsReader.apiKey(environment: environment) != nil
        case .crof:
            CrofSettingsReader.apiKey(environment: environment) != nil
        case .crossmodel:
            CrossModelSettingsReader.apiToken(environment: environment) != nil
        case .deepgram:
            DeepgramSettingsReader.apiKey(environment: environment) != nil
        case .deepseek:
            DeepSeekSettingsReader.apiKey(environment: environment) != nil
        case .doubao:
            DoubaoSettingsReader.apiKey(environment: environment) != nil
        case .elevenlabs:
            ElevenLabsSettingsReader.apiKey(environment: environment) != nil
        case .groq:
            GroqSettingsReader.apiKey(environment: environment) != nil
        case .kilo:
            KiloSettingsReader.apiKey(environment: environment) != nil
        default:
            false
        }
    }

    private static func environmentExtendedAPIAuthConfigured(
        provider: UsageProvider,
        environment: [String: String]) -> Bool
    {
        switch provider {
        case .kimi:
            KimiSettingsReader.apiKey(environment: environment) != nil
        case .kimik2:
            KimiK2SettingsReader.apiKey(environment: environment) != nil
        case .llmproxy:
            LLMProxySettingsReader.apiKey(environment: environment) != nil
        case .moonshot:
            MoonshotSettingsReader.apiKey(environment: environment) != nil
        case .ollama:
            OllamaAPISettingsReader.apiKey(environment: environment) != nil
        case .openai:
            OpenAIAPISettingsReader.apiKey(environment: environment) != nil
        case .openrouter:
            OpenRouterSettingsReader.apiToken(environment: environment) != nil
        case .stepfun:
            StepFunSettingsReader.token(environment: environment) != nil
        case .synthetic:
            SyntheticSettingsReader.apiKey(environment: environment) != nil
        case .venice:
            VeniceSettingsReader.apiKey(environment: environment) != nil
        case .warp:
            WarpSettingsReader.apiKey(environment: environment) != nil
        case .zai:
            ZaiSettingsReader.apiToken(environment: environment) != nil
        default:
            false
        }
    }

    private static func environmentWebAuthConfigured(
        provider: UsageProvider,
        environment: [String: String]) -> Bool
    {
        switch provider {
        case .alibabatokenplan:
            AlibabaTokenPlanSettingsReader.cookieHeader(environment: environment) != nil
        case .kimi:
            KimiSettingsReader.authToken(environment: environment) != nil
        case .manus:
            ManusSettingsReader.sessionToken(environment: environment) != nil
        case .perplexity:
            PerplexitySettingsReader.sessionToken(environment: environment) != nil
        default:
            false
        }
    }

    static func resolveMiniMaxAuthMode(
        environment: [String: String],
        settings: ProviderSettingsSnapshot?) -> MiniMaxAuthMode
    {
        let apiToken = ProviderTokenResolver.minimaxToken(environment: environment)
        let envCookieHeader = ProviderTokenResolver.minimaxCookie(environment: environment)
        let settingsCookieHeader = CookieHeaderNormalizer.normalize(settings?.minimax?.manualCookieHeader)
        let cookieHeader = envCookieHeader ?? settingsCookieHeader
        return MiniMaxAuthMode.resolve(apiToken: apiToken, cookieHeader: cookieHeader)
    }
}

#if DEBUG
extension CodexBarCLI {
    static func _diagnosticAuthSummaryForTesting(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        config: ProviderConfig?,
        environment: [String: String],
        settings: ProviderSettingsSnapshot?) -> ProviderDiagnosticAuthSummary
    {
        self.diagnosticAuthSummary(
            provider: provider,
            account: account,
            config: config,
            environment: environment,
            settings: settings)
    }

    static func _resolveMiniMaxAuthModeForTesting(
        environment: [String: String],
        settings: ProviderSettingsSnapshot?) -> MiniMaxAuthMode
    {
        self.resolveMiniMaxAuthMode(environment: environment, settings: settings)
    }
}
#endif
