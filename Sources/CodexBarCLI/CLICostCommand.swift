import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    private static let costSupportedProviders: Set<UsageProvider> = [.claude, .codex]

    static func runCost(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let config = CodexBarCLI.loadConfig(output: output)
        let selection = CodexBarCLI.decodeProvider(from: values, config: config)
        let providers = Self.costProviders(from: selection)
        let unsupported = selection.asList.filter { !Self.costSupportedProviders.contains($0) }
        if !unsupported.isEmpty {
            let names = unsupported
                .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
                .sorted()
                .joined(separator: ", ")
            if !output.jsonOnly {
                Self.writeStderr("Skipping providers without local cost usage: \(names)\n")
            }
        }
        guard !providers.isEmpty else {
            Self.exit(
                code: .failure,
                message: "Error: cost is only supported for Claude and Codex.",
                output: output,
                kind: .args)
        }

        let format = output.format
        let forceRefresh = values.flags.contains("refresh")
        let useColor = Self.shouldUseColor(noColor: values.flags.contains("noColor"), format: format)
        let historyDays = Self.decodeCostHistoryDays(from: values)

        let fetcher = CostUsageFetcher()
        var sections: [String] = []
        var payload: [CostPayload] = []
        var exitCode: ExitCode = .success

        for provider in providers {
            do {
                // Cost usage is local-only; it does not require web/CLI provider fetches.
                let snapshot = try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    forceRefresh: forceRefresh,
                    historyDays: historyDays,
                    refreshPricingInBackground: false)
                switch format {
                case .text:
                    sections.append(Self.renderCostText(provider: provider, snapshot: snapshot, useColor: useColor))
                case .json:
                    payload.append(Self.makeCostPayload(provider: provider, snapshot: snapshot, error: nil))
                }
            } catch {
                exitCode = Self.mapError(error)
                if format == .json {
                    payload.append(Self.makeCostPayload(provider: provider, snapshot: nil, error: error))
                } else if !output.jsonOnly {
                    Self.writeStderr("Error: \(error.localizedDescription)\n")
                }
            }
        }

        switch format {
        case .text:
            if !sections.isEmpty {
                print(sections.joined(separator: "\n\n"))
            }
        case .json:
            if !payload.isEmpty {
                Self.printJSON(payload, pretty: output.pretty)
            }
        }

        Self.exit(code: exitCode, output: output, kind: exitCode == .success ? .runtime : .provider)
    }

    static func renderCostText(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        useColor: Bool) -> String
    {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let header = Self.costHeaderLine("\(name) Cost (API-rate estimate)", useColor: useColor)

        let todayCost = snapshot.sessionCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let todayTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let todayLine = todayTokens.map { "Today: \(todayCost) · \($0) tokens" } ?? "Today: \(todayCost)"

        let monthCost = snapshot.last30DaysCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let monthTokens = snapshot.last30DaysTokens.map { UsageFormatter.tokenCountString($0) }
        let historyLabel = snapshot.historyLabel
            ?? (snapshot.historyDays == 1 ? "Today" : "Last \(snapshot.historyDays) days")
        let monthLine = monthTokens.map {
            "\(historyLabel): \(monthCost) · \($0) tokens"
        } ?? "\(historyLabel): \(monthCost)"

        let hintLine = UsageFormatter.costEstimateHint(provider: provider)
        return [header, todayLine, monthLine, hintLine].joined(separator: "\n")
    }

    private static func costHeaderLine(_ header: String, useColor: Bool) -> String {
        guard useColor else { return header }
        return "\u{001B}[1;36m\(header)\u{001B}[0m"
    }

    static func costProviders(from selection: ProviderSelection) -> [UsageProvider] {
        selection.asList.filter { Self.costSupportedProviders.contains($0) }
    }

    static func makeCostPayload(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot?,
        error: Error?) -> CostPayload
    {
        let daily = snapshot?.daily.map { entry in
            CostDailyEntryPayload(
                date: entry.date,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheReadTokens: entry.cacheReadTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD,
                modelsUsed: entry.modelsUsed,
                modelBreakdowns: entry.modelBreakdowns?.map { breakdown in
                    CostModelBreakdownPayload(
                        modelName: breakdown.modelName,
                        costUSD: breakdown.costUSD,
                        totalTokens: breakdown.totalTokens)
                })
        } ?? []

        return CostPayload(
            provider: provider.rawValue,
            source: "local",
            updatedAt: snapshot?.updatedAt ?? (error == nil ? nil : Date()),
            currencyCode: snapshot?.currencyCode,
            sessionTokens: snapshot?.sessionTokens,
            sessionCostUSD: snapshot?.sessionCostUSD,
            historyDays: snapshot?.historyDays,
            last30DaysTokens: snapshot?.last30DaysTokens,
            last30DaysCostUSD: snapshot?.last30DaysCostUSD,
            daily: daily,
            totals: snapshot.flatMap(Self.costTotals(from:)),
            error: error.map { Self.makeErrorPayload($0) })
    }

    private static func costTotals(from snapshot: CostUsageTokenSnapshot) -> CostTotalsPayload? {
        let entries = snapshot.daily
        guard !entries.isEmpty else {
            guard snapshot.last30DaysTokens != nil || snapshot.last30DaysCostUSD != nil else { return nil }
            return CostTotalsPayload(
                totalInputTokens: nil,
                totalOutputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: snapshot.last30DaysTokens,
                totalCostUSD: snapshot.last30DaysCostUSD)
        }

        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreation = 0
        var totalTokens = 0
        var totalCost = 0.0
        var sawInput = false
        var sawOutput = false
        var sawCacheRead = false
        var sawCacheCreation = false
        var sawTokens = false
        var sawCost = false

        for entry in entries {
            if let input = entry.inputTokens {
                totalInput += input
                sawInput = true
            }
            if let output = entry.outputTokens {
                totalOutput += output
                sawOutput = true
            }
            if let cacheRead = entry.cacheReadTokens {
                totalCacheRead += cacheRead
                sawCacheRead = true
            }
            if let cacheCreation = entry.cacheCreationTokens {
                totalCacheCreation += cacheCreation
                sawCacheCreation = true
            }
            if let tokens = entry.totalTokens {
                totalTokens += tokens
                sawTokens = true
            }
            if let cost = entry.costUSD {
                totalCost += cost
                sawCost = true
            }
        }

        // Prefer totals derived from daily rows; fall back to snapshot aggregates when rows omit fields.
        return CostTotalsPayload(
            totalInputTokens: sawInput ? totalInput : nil,
            totalOutputTokens: sawOutput ? totalOutput : nil,
            cacheReadTokens: sawCacheRead ? totalCacheRead : nil,
            cacheCreationTokens: sawCacheCreation ? totalCacheCreation : nil,
            totalTokens: sawTokens ? totalTokens : snapshot.last30DaysTokens,
            totalCostUSD: sawCost ? totalCost : snapshot.last30DaysCostUSD)
    }

    private static func decodeCostHistoryDays(from values: ParsedValues) -> Int {
        guard let raw = values.options["days"]?.last,
              let parsed = Int(raw)
        else { return 30 }
        return max(1, min(365, parsed))
    }
}

struct CostOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(
        name: .long("provider"),
        help: ProviderHelp.optionHelp)
    var provider: ProviderSelection?

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

    @Flag(name: .long("refresh"), help: "Force refresh by ignoring cached scans")
    var refresh: Bool = false

    @Option(name: .long("days"), help: "Cost history window in days (1...365)")
    var days: Int?
}

struct CostPayload: Encodable {
    let provider: String
    let source: String
    let updatedAt: Date?
    let currencyCode: String?
    let sessionTokens: Int?
    let sessionCostUSD: Double?
    let historyDays: Int?
    let last30DaysTokens: Int?
    let last30DaysCostUSD: Double?
    let daily: [CostDailyEntryPayload]
    let totals: CostTotalsPayload?
    let error: ProviderErrorPayload?

    init(
        provider: String,
        source: String,
        updatedAt: Date?,
        currencyCode: String? = nil,
        sessionTokens: Int?,
        sessionCostUSD: Double?,
        historyDays: Int?,
        last30DaysTokens: Int?,
        last30DaysCostUSD: Double?,
        daily: [CostDailyEntryPayload],
        totals: CostTotalsPayload?,
        error: ProviderErrorPayload?)
    {
        self.provider = provider
        self.source = source
        self.updatedAt = updatedAt
        self.currencyCode = currencyCode
        self.sessionTokens = sessionTokens
        self.sessionCostUSD = sessionCostUSD
        self.historyDays = historyDays
        self.last30DaysTokens = last30DaysTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.daily = daily
        self.totals = totals
        self.error = error
    }
}

struct CostDailyEntryPayload: Encodable {
    let date: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let totalTokens: Int?
    let costUSD: Double?
    let modelsUsed: [String]?
    let modelBreakdowns: [CostModelBreakdownPayload]?

    private enum CodingKeys: String, CodingKey {
        case date
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case totalTokens
        case costUSD = "totalCost"
        case modelsUsed
        case modelBreakdowns
    }
}

struct CostModelBreakdownPayload: Encodable {
    let modelName: String
    let costUSD: Double?
    let totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case modelName
        case costUSD = "cost"
        case totalTokens
    }
}

struct CostTotalsPayload: Encodable {
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let totalTokens: Int?
    let totalCostUSD: Double?

    private enum CodingKeys: String, CodingKey {
        case totalInputTokens = "inputTokens"
        case totalOutputTokens = "outputTokens"
        case cacheReadTokens
        case cacheCreationTokens
        case totalTokens
        case totalCostUSD = "totalCost"
    }
}

// Intentionally empty.
