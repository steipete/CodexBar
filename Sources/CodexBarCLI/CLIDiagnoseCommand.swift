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
            providerSelection = Self.providerSelection(
                rawOverride: nil,
                enabled: config.enabledProviders().compactMap(\.firstPartyProvider))
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
                config: tokenContext.config.providerConfig(for: provider.instanceID),
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
        let adapter = ProviderDescriptorRegistry.descriptor(for: provider).credentials ?? ProviderCredentialAdapter()
        return adapter.diagnosticAuthSummary(
            account: account,
            config: config,
            environment: environment,
            settings: settings)
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
}
#endif
