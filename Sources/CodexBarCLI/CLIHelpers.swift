import CodexBarCore
import Commander
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

extension CodexBarCLI {
    static func decodeProvider(from values: ParsedValues, config: CodexBarConfig) -> ProviderSelection {
        let rawOverride = values.options["provider"]?.last
        return Self.providerSelection(rawOverride: rawOverride, enabled: config.enabledProviders())
    }

    static func providerSelection(rawOverride: String?, enabled: [UsageProvider]) -> ProviderSelection {
        if let rawOverride, let parsed = ProviderSelection(argument: rawOverride) {
            return parsed
        }
        if enabled.count >= 3 { return .all }
        if enabled.count == 2 {
            let enabledSet = Set(enabled)
            let primary = Set(ProviderDescriptorRegistry.all.filter(\ .metadata.isPrimaryProvider).map(\ .id))
            if !primary.isEmpty, enabledSet == primary {
                return .both
            }
            return .custom(enabled)
        }
        if let first = enabled.first { return ProviderSelection(provider: first) }
        return .single(.codex)
    }

    static func decodeFormat(from values: ParsedValues) -> OutputFormat {
        if let raw = values.options["format"]?.last, let parsed = OutputFormat(argument: raw) {
            return parsed
        }
        if values.flags.contains("jsonShortcut") || values.flags.contains("json") || values.flags.contains("jsonOnly") {
            return .json
        }
        return .text
    }

    static func decodeTokenAccountSelection(from values: ParsedValues) throws -> TokenAccountCLISelection {
        let label = values.options["account"]?.last
        let rawIndex = values.options["accountIndex"]?.last
        var index: Int?
        if let rawIndex {
            guard let parsed = Int(rawIndex), parsed > 0 else {
                throw CLIArgumentError("--account-index must be a positive integer.")
            }
            index = parsed - 1
        }
        let allAccounts = values.flags.contains("allAccounts")
        return TokenAccountCLISelection(label: label, index: index, allAccounts: allAccounts)
    }

    static func shouldUseColor(noColor: Bool, format: OutputFormat) -> Bool {
        guard format == .text else { return false }
        if noColor { return false }
        let env = ProcessInfo.processInfo.environment
        if env["TERM"]?.lowercased() == "dumb" { return false }
        return isatty(STDOUT_FILENO) == 1
    }

    static func detectVersion(for provider: UsageProvider, browserDetection: BrowserDetection) -> String? {
        ProviderDescriptorRegistry.descriptor(for: provider).cli.versionDetector?(browserDetection)
    }

    static func normalizeVersion(raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let match = raw.range(of: #"(\d+(?:\.\d+)+)"#, options: .regularExpression) {
            return String(raw[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeHeader(provider: UsageProvider, version: String?, source: String) -> String {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        if let version, !version.isEmpty {
            return "\(name) \(version) (\(source))"
        }
        return "\(name) (\(source))"
    }

    static func printFetchAttempts(provider: UsageProvider, attempts: [ProviderFetchAttempt]) {
        guard !attempts.isEmpty else { return }
        self.writeStderr("[\(provider.rawValue)] fetch strategies:\n")
        for attempt in attempts {
            let kindLabel = Self.fetchKindLabel(attempt.kind)
            var line = "  - \(attempt.strategyID) (\(kindLabel))"
            line += attempt.wasAvailable ? " available" : " unavailable"
            if let error = attempt.errorDescription, !error.isEmpty {
                line += " error=\(error)"
            }
            self.writeStderr("\(line)\n")
        }
    }

    private static func fetchKindLabel(_ kind: ProviderFetchKind) -> String {
        switch kind {
        case .cli: "cli"
        case .web: "web"
        case .oauth: "oauth"
        case .apiToken: "api"
        case .localProbe: "local"
        case .webDashboard: "web"
        }
    }

    static func fetchStatus(for provider: UsageProvider) async -> ProviderStatusPayload? {
        let urlString = ProviderDescriptorRegistry.descriptor(for: provider).metadata.statusPageURL
        guard let urlString,
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

    static func resetTimeDisplayStyleFromDefaults() -> ResetTimeDisplayStyle {
        let domains = [
            "com.steipete.codexbar",
            "com.steipete.codexbar.debug",
        ]
        for domain in domains {
            if let value = UserDefaults(suiteName: domain)?.object(forKey: "resetTimesShowAbsolute") as? Bool {
                return value ? .absolute : .countdown
            }
        }
        let fallback = UserDefaults.standard.object(forKey: "resetTimesShowAbsolute") as? Bool ?? false
        return fallback ? .absolute : .countdown
    }

    static func fetchProviderUsage(
        provider: UsageProvider,
        context: ProviderFetchContext) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        if !descriptor.fetchPlan.sourceModes.contains(context.sourceMode) {
            let error = SourceSelectionError.unsupported(
                provider: descriptor.cli.name,
                source: context.sourceMode)
            return ProviderFetchOutcome(result: .failure(error), attempts: [])
        }
        return await descriptor.fetchOutcome(context: context)
    }

    private enum SourceSelectionError: LocalizedError {
        case unsupported(provider: String, source: ProviderSourceMode)

        var errorDescription: String? {
            switch self {
            case let .unsupported(provider, source):
                "Source '\(source.rawValue)' is not supported for \(provider)."
            }
        }
    }

    static func loadOpenAIDashboardIfAvailable(
        usage: UsageSnapshot,
        fetcher: UsageFetcher) -> OpenAIDashboardSnapshot?
    {
        guard let cache = OpenAIDashboardCacheStore.load() else { return nil }
        let codexEmail = (usage.accountEmail(for: .codex) ?? fetcher.loadAccountInfo().email)?
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

    static func decodeWebTimeout(from values: ParsedValues) -> TimeInterval? {
        if let raw = values.options["webTimeout"]?.last, let seconds = Double(raw) {
            return seconds
        }
        return nil
    }

    static func decodeSourceMode(from values: ParsedValues) -> ProviderSourceMode? {
        if values.flags.contains("web") {
            return .web
        }
        guard let raw = values.options["source"]?.last?.lowercased() else { return nil }
        if raw == "local" {
            return .cli
        }
        return ProviderSourceMode(rawValue: raw)
    }

    static func renderOpenAIWebDashboardText(_ dash: OpenAIDashboardSnapshot) -> String {
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

    static func mapError(_ error: Error) -> ExitCode {
        switch error {
        case TTYCommandRunner.Error.binaryNotFound,
             CodexStatusProbeError.codexNotInstalled,
             ClaudeUsageError.claudeNotInstalled,
             GeminiStatusProbeError.geminiNotInstalled:
            ExitCode(2)
        case CodexStatusProbeError.timedOut,
             TTYCommandRunner.Error.timedOut,
             GeminiStatusProbeError.timedOut,
             CostUsageError.timedOut:
            ExitCode(4)
        case ClaudeUsageError.parseFailed,
             ClaudeUsageError.oauthFailed,
             CostUsageError.unsupportedProvider,
             UsageError.decodeFailed,
             UsageError.noRateLimitsFound,
             GeminiStatusProbeError.parseFailed:
            ExitCode(3)
        default:
            .failure
        }
    }

    static func printAntigravityPlanInfo(_ info: AntigravityPlanInfoSummary) {
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

    static func loadConfig(output: CLIOutputPreferences) -> CodexBarConfig {
        let store = CodexBarConfigStore()
        do {
            if let existing = try store.load() {
                return existing
            }
            return CodexBarConfig.makeDefault()
        } catch {
            if output.usesJSONOutput {
                let payload = ProviderPayload(
                    providerID: "cli",
                    account: nil,
                    version: nil,
                    source: "cli",
                    status: nil,
                    usage: nil,
                    credits: nil,
                    antigravityPlanInfo: nil,
                    openaiDashboard: nil,
                    error: self.makeErrorPayload(code: .failure, message: error.localizedDescription, kind: .config))
                self.printJSON([payload], pretty: output.pretty)
            } else {
                self.writeStderr("Error: \(error.localizedDescription)\n")
            }
            Self.platformExit(ExitCode.failure.rawValue)
        }
    }
}

struct CLIArgumentError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        self.message
    }
}

#if DEBUG
extension CodexBarCLI {
    static func _usageSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(UsageOptions())
    }

    static func _costSignatureForTesting() -> CommandSignature {
        CommandSignature.describe(CostOptions())
    }

    static func _decodeFormatForTesting(from values: ParsedValues) -> OutputFormat {
        self.decodeFormat(from: values)
    }

    static func _decodeWebTimeoutForTesting(from values: ParsedValues) -> TimeInterval? {
        self.decodeWebTimeout(from: values)
    }

    static func _decodeSourceModeForTesting(from values: ParsedValues) -> ProviderSourceMode? {
        self.decodeSourceMode(from: values)
    }
}
#endif
