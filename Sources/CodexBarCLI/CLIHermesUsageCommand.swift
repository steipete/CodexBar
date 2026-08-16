import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runHermesUsage(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let useColor = Self.shouldUseColor(
            noColor: values.flags.contains("noColor"),
            format: output.format)

        do {
            let provider = try Self.decodeHermesUsageProvider(from: values)
            let explicitDatabases = Self.decodeHermesUsageDatabaseURLs(from: values)
            let sources: [HermesUsageDatabaseSource] = if explicitDatabases.isEmpty {
                HermesUsageDatabaseDiscovery.discover()
            } else {
                explicitDatabases.map {
                    HermesUsageDatabaseSource(
                        label: HermesUsageDatabaseDiscovery.label(forDatabaseURL: $0),
                        databaseURL: $0)
                }
            }
            guard !sources.isEmpty else {
                throw CLIArgumentError(
                    "No Hermes state.db databases found. Pass --database <path[,path...]> or set HERMES_HOME.")
            }

            let scanner = HermesUsageScanner()
            if values.flags.contains("refreshPricing") {
                await scanner.refreshPricingIfNeeded()
            }
            var report = try scanner.scan(sources: sources)
            try Self.validateHermesUsageSources(report.sources)
            if let provider {
                report = try Self.filterHermesUsageReport(report, provider: provider)
            }

            switch output.format {
            case .text:
                print(Self.renderHermesUsageText(report, useColor: useColor))
            case .json:
                Self.printJSON(report, pretty: output.pretty)
            }
            Self.exit(code: .success, output: output, kind: .runtime)
        } catch {
            Self.exit(
                code: Self.mapError(error),
                message: "Error: \(error.localizedDescription)",
                output: output,
                kind: error is CLIArgumentError ? .args : .runtime)
        }
    }

    static func decodeHermesUsageProvider(from values: ParsedValues) throws -> UsageProvider? {
        guard let raw = values.options["provider"]?.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.lowercased() != "all"
        else { return nil }
        guard let provider = UsageProvider(rawValue: raw.lowercased()) else {
            throw CLIArgumentError("Unknown CodexBar provider '\(raw)'.")
        }
        let supported = Set(HermesUsageProviderMapping.supportedBillingProviders.compactMap {
            HermesUsageProviderMapping.route(for: $0)?.provider
        })
        guard supported.contains(provider) else {
            let list = supported.map(\.rawValue).sorted().joined(separator: ", ")
            throw CLIArgumentError("Hermes local usage is not mapped to \(raw). Supported providers: \(list).")
        }
        return provider
    }

    static func decodeHermesUsageDatabaseURLs(
        from values: ParsedValues,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL]
    {
        let paths = values.options["database"]?.flatMap { raw in
            raw.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        } ?? []
        var seen: Set<String> = []
        return paths.compactMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let path: String = if trimmed == "~" {
                homeDirectory.path
            } else if trimmed.hasPrefix("~/") {
                homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2))).path
            } else {
                NSString(string: trimmed).expandingTildeInPath
            }
            let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    static func filterHermesUsageReport(
        _ report: HermesUsageReport,
        provider: UsageProvider) throws -> HermesUsageReport
    {
        guard let providerReport = report.providers.first(where: { $0.provider == provider }) else {
            throw CLIArgumentError("No Hermes usage found for CodexBar provider '\(provider.rawValue)'.")
        }
        return HermesUsageReport(
            schemaVersion: report.schemaVersion,
            generatedAt: report.generatedAt,
            sources: report.sources,
            summary: providerReport.summary,
            providers: [providerReport],
            unmapped: [],
            warnings: report.warnings)
    }

    static func validateHermesUsageSources(_ sources: [HermesUsageSourceReport]) throws {
        guard sources.contains(where: { $0.status == .read }) else {
            let details = sources.map { "\($0.label): \($0.status.rawValue)" }.joined(separator: ", ")
            throw HermesUsageCLIError.noReadableSources(details: details)
        }
    }

    static func renderHermesUsageText(_ report: HermesUsageReport, useColor _: Bool) -> String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.locale = Locale(identifier: "en_US_POSIX")

        func integer(_ value: Int) -> String {
            number.string(from: NSNumber(value: value)) ?? String(value)
        }

        func currency(_ value: Double?) -> String {
            value.map { UsageFormatter.currencyString($0, currencyCode: "USD") } ?? "unknown"
        }

        func summaryLines(_ summary: HermesUsageSummary, prefix: String = "") -> [String] {
            let tokens = summary.tokens
            var lines = [
                "\(prefix)Tokens: \(integer(tokens.total)) " +
                    "(input \(integer(tokens.input)), cache read \(integer(tokens.cacheRead)), " +
                    "cache write \(integer(tokens.cacheWrite)), output \(integer(tokens.output)), " +
                    "reasoning \(integer(tokens.reasoning)) subset of output)",
                "\(prefix)Requests: \(integer(summary.requests)) · Sessions: \(integer(summary.sessions))",
                "\(prefix)Actual billed: \(currency(summary.actualCostUSD))",
                "\(prefix)Hermes estimate: \(currency(summary.hermesEstimatedCostUSD))",
                "\(prefix)API-equivalent: " + (summary.apiEquivalentCostUSD.map { "~\(currency($0))" } ?? "unknown") +
                    " · priced \(integer(summary.apiEquivalentPricedTokens)) / " +
                    "unpriced \(integer(summary.apiEquivalentUnpricedTokens)) tokens",
                "\(prefix)Included in subscription: \(integer(summary.subscriptionIncludedTokens)) tokens · " +
                    "\(integer(summary.subscriptionIncludedRequests)) requests",
            ]
            if summary.actualCostUSD == nil {
                lines[2] += " (not reported)"
            }
            if summary.hermesEstimatedCostUSD == nil {
                lines[3] += " (not reported)"
            }
            return lines
        }

        var lines = ["Hermes local usage snapshot"]
        lines.append(contentsOf: summaryLines(report.summary))
        if !report.providers.isEmpty {
            lines.append("")
            lines.append("Mapped providers:")
            for provider in report.providers {
                let descriptor = ProviderDescriptorRegistry.descriptor(for: provider.provider)
                lines.append(
                    "- \(descriptor.metadata.displayName): \(integer(provider.summary.tokens.total)) tokens · " +
                        "actual \(currency(provider.summary.actualCostUSD)) · " +
                        "Hermes estimate \(currency(provider.summary.hermesEstimatedCostUSD)) · " +
                        "API-equivalent " +
                        (provider.summary.apiEquivalentCostUSD.map { "~\(currency($0))" } ?? "unknown"))
            }
        }
        if !report.unmapped.isEmpty {
            lines.append("")
            lines.append("Unmapped routes: \(report.unmapped.map(\.billingProvider).joined(separator: ", "))")
        }
        if !report.sources.isEmpty {
            lines.append("")
            lines.append("Sources:")
            for source in report.sources {
                lines.append("- \(source.label): \(source.status.rawValue) (\(source.databasePath))")
            }
        }
        if !report.warnings.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(contentsOf: report.warnings.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

enum HermesUsageCLIError: LocalizedError, Equatable {
    case noReadableSources(details: String)

    var errorDescription: String? {
        switch self {
        case let .noReadableSources(details):
            "No Hermes usage databases could be read (\(details))."
        }
    }
}

struct HermesUsageOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("database"), help: "Hermes state.db path(s), comma-separated; overrides discovery")
    var database: [String]?

    @Option(name: .long("provider"), help: "Filter by mapped CodexBar provider, or all")
    var provider: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long("no-color"), help: "Disable ANSI colors in text output")
    var noColor: Bool = false

    @Flag(name: .long("refresh-pricing"), help: "Refresh the public models.dev catalog before estimating")
    var refreshPricing: Bool = false
}
