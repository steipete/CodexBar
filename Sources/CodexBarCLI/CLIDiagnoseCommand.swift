import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runDiagnose(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)

        let providerRaw = values.options["provider"]?.last ?? "minimax"
        guard providerRaw.lowercased() == "minimax" else {
            Self.exit(
                code: .failure,
                message: "Error: only 'minimax' provider is supported for diagnose",
                output: output,
                kind: .args)
        }

        let format = Self.decodeFormat(from: values)
        guard format == .json else {
            Self.exit(
                code: .failure,
                message: "Error: only JSON format is supported for diagnose",
                output: output,
                kind: .args)
        }

        let pretty = values.flags.contains("pretty")
        let verbose = values.flags.contains("verbose")
        let browserDetection = BrowserDetection()
        let fetcher = UsageFetcher()

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

        let activeMiniMaxAccount: ProviderTokenAccount? = {
            let accounts = (try? tokenContext.resolvedAccounts(for: .minimax)) ?? []
            return accounts.first
        }()
        let env = tokenContext.environment(
            base: ProcessInfo.processInfo.environment,
            provider: .minimax,
            account: activeMiniMaxAccount,
            codexActiveSourceOverride: nil)
        let settings = tokenContext.settingsSnapshot(
            for: .minimax,
            account: activeMiniMaxAccount,
            codexActiveSourceOverride: nil)
        let sourceMode = tokenContext.preferredSourceMode(for: .minimax)

        let authMode = Self.resolveMiniMaxAuthMode(environment: env, settings: settings)

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
            browserDetection: browserDetection)

        let outcome = await Self.fetchProviderUsage(provider: .minimax, context: fetchContext)

        let diagnostic = MiniMaxDiagnosticExportBuilder.build(
            outcome: outcome,
            settings: settings,
            authMode: authMode)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = .sortedKeys
        }

        do {
            let data = try encoder.encode(diagnostic)
            var jsonString = String(data: data, encoding: .utf8) ?? "{}"
            jsonString = LogRedactor.redact(jsonString)
            print(jsonString)
        } catch {
            Self.exit(
                code: .failure,
                message: "Error encoding diagnostic: \(error.localizedDescription)",
                output: output,
                kind: .runtime)
        }

        Self.exit(code: .success, output: output, kind: .runtime)
    }
}

extension CodexBarCLI {
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
    static func _resolveMiniMaxAuthModeForTesting(
        environment: [String: String],
        settings: ProviderSettingsSnapshot?) -> MiniMaxAuthMode
    {
        self.resolveMiniMaxAuthMode(environment: environment, settings: settings)
    }
}
#endif
