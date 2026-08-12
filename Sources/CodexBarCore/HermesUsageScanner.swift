import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
private let hermesSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

public struct HermesUsageProviderRoute: Sendable, Equatable, Codable {
    public let provider: UsageProvider
    public let modelsDevProviderID: String

    public init(provider: UsageProvider, modelsDevProviderID: String) {
        self.provider = provider
        self.modelsDevProviderID = modelsDevProviderID
    }
}

/// Conservative mapping from Hermes' persisted `billing_provider` routes to CodexBar providers.
///
/// Only exact, product-equivalent routes belong here. Routing placeholders (`auto`, `custom`, `moa`)
/// and broader clouds such as Azure AI Foundry deliberately stay unmapped because their model vendor
/// cannot be recovered reliably from the route name alone.
public enum HermesUsageProviderMapping {
    /// Provider-specific by design: Hermes persists external billing_provider route IDs, so the import boundary
    /// needs one explicit audited mapping to CodexBar identities and models.dev rate sources.
    private static let routes: [String: HermesUsageProviderRoute] = [
        "alibaba": .init(provider: .qwencloud, modelsDevProviderID: "alibaba"),
        // Subscription catalogs publish zero plan rates. API-equivalent estimates use the
        // corresponding direct vendor catalog instead of turning included usage into a false $0.
        "alibaba-coding-plan": .init(provider: .alibaba, modelsDevProviderID: "alibaba"),
        "anthropic": .init(provider: .claude, modelsDevProviderID: "anthropic"),
        "bedrock": .init(provider: .bedrock, modelsDevProviderID: "amazon-bedrock"),
        "copilot": .init(provider: .copilot, modelsDevProviderID: "github-copilot"),
        "copilot-acp": .init(provider: .copilot, modelsDevProviderID: "github-copilot"),
        "deepinfra": .init(provider: .deepinfra, modelsDevProviderID: "deepinfra"),
        "deepseek": .init(provider: .deepseek, modelsDevProviderID: "deepseek"),
        "fireworks": .init(provider: .fireworks, modelsDevProviderID: "fireworks-ai"),
        "gemini": .init(provider: .gemini, modelsDevProviderID: "google"),
        "kilocode": .init(provider: .kilo, modelsDevProviderID: "kilo"),
        "kimi-coding": .init(provider: .kimi, modelsDevProviderID: "moonshotai"),
        "kimi-coding-cn": .init(provider: .moonshot, modelsDevProviderID: "moonshotai-cn"),
        "minimax": .init(provider: .minimax, modelsDevProviderID: "minimax"),
        "minimax-cn": .init(provider: .minimax, modelsDevProviderID: "minimax-cn"),
        "minimax-oauth": .init(provider: .minimax, modelsDevProviderID: "minimax"),
        "ollama-cloud": .init(provider: .ollama, modelsDevProviderID: "ollama-cloud"),
        "openai-api": .init(provider: .openai, modelsDevProviderID: "openai"),
        "openai-codex": .init(provider: .codex, modelsDevProviderID: "openai"),
        "opencode-go": .init(provider: .opencodego, modelsDevProviderID: "opencode-go"),
        "opencode-zen": .init(provider: .opencode, modelsDevProviderID: "opencode"),
        "openrouter": .init(provider: .openrouter, modelsDevProviderID: "openrouter"),
        "qwen-oauth": .init(provider: .qwencloud, modelsDevProviderID: "alibaba"),
        "stepfun": .init(provider: .stepfun, modelsDevProviderID: "stepfun-ai"),
        "vertex": .init(provider: .vertexai, modelsDevProviderID: "google-vertex"),
        "xai": .init(provider: .xai, modelsDevProviderID: "xai"),
        "xai-oauth": .init(provider: .grok, modelsDevProviderID: "xai"),
        "xiaomi": .init(provider: .mimo, modelsDevProviderID: "xiaomi"),
        "zai": .init(provider: .zai, modelsDevProviderID: "zai"),
    ]

    public static var supportedBillingProviders: [String] {
        self.routes.keys.sorted()
    }

    public static func route(
        for rawBillingProvider: String,
        billingBaseURL: String? = nil) -> HermesUsageProviderRoute?
    {
        let normalized = rawBillingProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, let route = self.routes[normalized] else { return nil }
        let host = billingBaseURL.flatMap(URL.init(string:))?.host?.lowercased()

        // Provider-specific by design: persisted Kimi/Moonshot, MiniMax OAuth, and StepFun route IDs span
        // region/product hosts.
        switch normalized {
        case "kimi-coding", "kimi-coding-cn":
            if host == "api.moonshot.ai" {
                return .init(provider: .moonshot, modelsDevProviderID: "moonshotai")
            }
            if host == "api.moonshot.cn" {
                return .init(provider: .moonshot, modelsDevProviderID: "moonshotai-cn")
            }
            if host == "api.kimi.com" {
                return .init(provider: .kimi, modelsDevProviderID: "moonshotai")
            }
        case "minimax-oauth":
            if host == "api.minimaxi.com" {
                return .init(provider: .minimax, modelsDevProviderID: "minimax-cn")
            }
            if host == "api.minimax.io" {
                return .init(provider: .minimax, modelsDevProviderID: "minimax")
            }
        case "stepfun":
            if host == "api.stepfun.com" {
                return .init(provider: .stepfun, modelsDevProviderID: "stepfun")
            }
            if host == "api.stepfun.ai" {
                return .init(provider: .stepfun, modelsDevProviderID: "stepfun-ai")
            }
        default:
            break
        }
        return route
    }
}

public struct HermesUsageTokenCounts: Sendable, Equatable, Codable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = max(0, input)
        self.output = max(0, output)
        self.cacheRead = max(0, cacheRead)
        self.cacheWrite = max(0, cacheWrite)
        self.reasoning = max(0, reasoning)
    }

    /// Hermes' canonical token buckets are disjoint except reasoning, which is a subset of output.
    /// Reasoning is therefore reported separately and intentionally excluded from this total.
    public var total: Int {
        self.input + self.output + self.cacheRead + self.cacheWrite
    }

    fileprivate static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning)
    }

    fileprivate static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    fileprivate static func positiveResidual(_ aggregate: Self, minus attributed: Self) -> Self {
        Self(
            input: max(0, aggregate.input - attributed.input),
            output: max(0, aggregate.output - attributed.output),
            cacheRead: max(0, aggregate.cacheRead - attributed.cacheRead),
            cacheWrite: max(0, aggregate.cacheWrite - attributed.cacheWrite),
            reasoning: max(0, aggregate.reasoning - attributed.reasoning))
    }
}

public struct HermesUsageSummary: Sendable, Equatable, Codable {
    public let tokens: HermesUsageTokenCounts
    public let requests: Int
    public let sessions: Int
    public let hermesEstimatedCostUSD: Double?
    public let actualCostUSD: Double?
    public let subscriptionIncludedTokens: Int
    public let subscriptionIncludedRequests: Int
    public let apiEquivalentCostUSD: Double?
    public let apiEquivalentPricedTokens: Int
    public let apiEquivalentUnpricedTokens: Int

    public init(
        tokens: HermesUsageTokenCounts,
        requests: Int,
        sessions: Int,
        hermesEstimatedCostUSD: Double?,
        actualCostUSD: Double?,
        subscriptionIncludedTokens: Int,
        subscriptionIncludedRequests: Int,
        apiEquivalentCostUSD: Double?,
        apiEquivalentPricedTokens: Int,
        apiEquivalentUnpricedTokens: Int)
    {
        self.tokens = tokens
        self.requests = max(0, requests)
        self.sessions = max(0, sessions)
        self.hermesEstimatedCostUSD = hermesEstimatedCostUSD
        self.actualCostUSD = actualCostUSD
        self.subscriptionIncludedTokens = max(0, subscriptionIncludedTokens)
        self.subscriptionIncludedRequests = max(0, subscriptionIncludedRequests)
        self.apiEquivalentCostUSD = apiEquivalentCostUSD
        self.apiEquivalentPricedTokens = max(0, apiEquivalentPricedTokens)
        self.apiEquivalentUnpricedTokens = max(0, apiEquivalentUnpricedTokens)
    }
}

public struct HermesUsageNamedBreakdown: Sendable, Equatable, Codable {
    public let name: String
    public let summary: HermesUsageSummary

    public init(name: String, summary: HermesUsageSummary) {
        self.name = name
        self.summary = summary
    }
}

public struct HermesUsageProviderReport: Sendable, Equatable, Codable {
    public let provider: UsageProvider
    public let billingProviders: [String]
    public let summary: HermesUsageSummary
    public let models: [HermesUsageNamedBreakdown]
    public let tasks: [HermesUsageNamedBreakdown]

    public init(
        provider: UsageProvider,
        billingProviders: [String],
        summary: HermesUsageSummary,
        models: [HermesUsageNamedBreakdown],
        tasks: [HermesUsageNamedBreakdown])
    {
        self.provider = provider
        self.billingProviders = billingProviders
        self.summary = summary
        self.models = models
        self.tasks = tasks
    }
}

public struct HermesUsageUnmappedReport: Sendable, Equatable, Codable {
    public let billingProvider: String
    public let summary: HermesUsageSummary
    public let models: [HermesUsageNamedBreakdown]
    public let tasks: [HermesUsageNamedBreakdown]

    public init(
        billingProvider: String,
        summary: HermesUsageSummary,
        models: [HermesUsageNamedBreakdown],
        tasks: [HermesUsageNamedBreakdown])
    {
        self.billingProvider = billingProvider
        self.summary = summary
        self.models = models
        self.tasks = tasks
    }
}

public enum HermesUsageSourceStatus: String, Sendable, Equatable, Codable {
    case read
    case missing
    case incompatible
    case locked
    case corrupt
    case unreadable
}

public struct HermesUsageSourceReport: Sendable, Equatable, Codable {
    public let label: String
    public let databasePath: String
    public let status: HermesUsageSourceStatus
    public let error: String?

    public init(label: String, databasePath: String, status: HermesUsageSourceStatus, error: String? = nil) {
        self.label = label
        self.databasePath = databasePath
        self.status = status
        self.error = error
    }
}

public struct HermesUsageReport: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let sources: [HermesUsageSourceReport]
    public let summary: HermesUsageSummary
    public let providers: [HermesUsageProviderReport]
    public let unmapped: [HermesUsageUnmappedReport]
    public let warnings: [String]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        sources: [HermesUsageSourceReport],
        summary: HermesUsageSummary,
        providers: [HermesUsageProviderReport],
        unmapped: [HermesUsageUnmappedReport],
        warnings: [String])
    {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sources = sources
        self.summary = summary
        self.providers = providers
        self.unmapped = unmapped
        self.warnings = warnings
    }
}

public struct HermesUsageDatabaseSource: Sendable, Equatable, Codable {
    public let label: String
    public let databaseURL: URL

    public init(label: String, databaseURL: URL) {
        self.label = label
        self.databaseURL = databaseURL
    }
}

public enum HermesUsageDatabaseDiscovery {
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [HermesUsageDatabaseSource]
    {
        let root = homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
        var candidates: [HermesUsageDatabaseSource] = []
        let defaultDatabase = root.appendingPathComponent("state.db", isDirectory: false)
        if FileManager.default.fileExists(atPath: defaultDatabase.path) {
            candidates.append(.init(label: "default", databaseURL: defaultDatabase))
        }

        let profilesRoot = root.appendingPathComponent("profiles", isDirectory: true)
        let profileDirectories = (try? FileManager.default.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for profileDirectory in profileDirectories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? profileDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let database = profileDirectory.appendingPathComponent("state.db", isDirectory: false)
            guard FileManager.default.fileExists(atPath: database.path) else { continue }
            candidates.append(.init(label: profileDirectory.lastPathComponent, databaseURL: database))
        }

        if let rawActiveHome = environment["HERMES_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawActiveHome.isEmpty
        {
            let expanded = NSString(string: rawActiveHome).expandingTildeInPath
            let activeHome = URL(fileURLWithPath: expanded, isDirectory: true)
            let database = activeHome.appendingPathComponent("state.db", isDirectory: false)
            if FileManager.default.fileExists(atPath: database.path) {
                candidates.append(.init(
                    label: Self.label(forDatabaseURL: database),
                    databaseURL: database))
            }
        }

        var seen: Set<String> = []
        return candidates.filter { source in
            let path = source.databaseURL.resolvingSymlinksInPath().standardizedFileURL.path
            return seen.insert(path).inserted
        }
    }

    public static func label(forDatabaseURL databaseURL: URL) -> String {
        let parent = databaseURL.deletingLastPathComponent()
        if parent.lastPathComponent == ".hermes" {
            return "default"
        }
        if parent.deletingLastPathComponent().lastPathComponent == "profiles" {
            return parent.lastPathComponent
        }
        let label = parent.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Hermes" : label
    }
}

public struct HermesUsageScanner: Sendable {
    private let modelsDevCacheRoot: URL?

    public init(modelsDevCacheRoot: URL? = nil) {
        self.modelsDevCacheRoot = modelsDevCacheRoot
    }

    /// Refreshes the public models.dev catalog used for the independent API-equivalent estimate.
    /// The Hermes database remains local and read-only; only the pricing catalog uses the network.
    public func refreshPricingIfNeeded(now: Date = Date()) async {
        await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: self.modelsDevCacheRoot)
    }

    public func scan(
        databaseURLs: [URL],
        generatedAt: Date = Date()) throws -> HermesUsageReport
    {
        let sources = databaseURLs.map {
            HermesUsageDatabaseSource(
                label: HermesUsageDatabaseDiscovery.label(forDatabaseURL: $0),
                databaseURL: $0)
        }
        return try self.scan(sources: sources, generatedAt: generatedAt)
    }

    public func scan(
        sources: [HermesUsageDatabaseSource],
        generatedAt: Date = Date()) throws -> HermesUsageReport
    {
        var rows: [HermesUsageRow] = []
        var sourceReports: [HermesUsageSourceReport] = []
        var seen: Set<String> = []

        for source in sources {
            let standardizedURL = source.databaseURL.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(standardizedURL.path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
                sourceReports.append(.init(
                    label: source.label,
                    databasePath: standardizedURL.path,
                    status: .missing))
                continue
            }

            do {
                let sourceRows = try Self.readRows(databaseURL: standardizedURL, sourceLabel: source.label)
                rows.append(contentsOf: sourceRows)
                sourceReports.append(.init(
                    label: source.label,
                    databasePath: standardizedURL.path,
                    status: .read))
            } catch let error as HermesUsageReadError {
                sourceReports.append(.init(
                    label: source.label,
                    databasePath: standardizedURL.path,
                    status: error.status,
                    error: error.message))
            }
        }

        return self.makeReport(rows: rows, sources: sourceReports, generatedAt: generatedAt)
    }

    private func makeReport(
        rows: [HermesUsageRow],
        sources: [HermesUsageSourceReport],
        generatedAt: Date) -> HermesUsageReport
    {
        var overall = HermesUsageAccumulator()
        var providers: [UsageProvider: HermesUsageGroupAccumulator] = [:]
        var unmapped: [String: HermesUsageGroupAccumulator] = [:]

        for row in rows {
            let route = HermesUsageProviderMapping.route(
                for: row.billingProvider,
                billingBaseURL: row.billingBaseURL)
            let apiEquivalentCost = route.flatMap { route in
                self.apiEquivalentCost(row: row, route: route, generatedAt: generatedAt)
            }
            overall.add(row, apiEquivalentCostUSD: apiEquivalentCost)

            if let route {
                var group = providers[route.provider] ?? HermesUsageGroupAccumulator()
                group.billingProviders.insert(row.billingProvider)
                group.add(row, apiEquivalentCostUSD: apiEquivalentCost)
                providers[route.provider] = group
            } else {
                let key = Self.unmappedKey(row.billingProvider)
                var group = unmapped[key] ?? HermesUsageGroupAccumulator()
                group.add(row, apiEquivalentCostUSD: nil)
                unmapped[key] = group
            }
        }

        let providerReports = providers.map { provider, group in
            HermesUsageProviderReport(
                provider: provider,
                billingProviders: group.billingProviders.sorted(),
                summary: group.summary.finalized(),
                models: group.namedBreakdowns(group.models),
                tasks: group.namedBreakdowns(group.tasks))
        }
        .sorted { lhs, rhs in
            if lhs.summary.tokens.total != rhs.summary.tokens.total {
                return lhs.summary.tokens.total > rhs.summary.tokens.total
            }
            return lhs.provider.rawValue < rhs.provider.rawValue
        }

        let unmappedReports = unmapped.map { provider, group in
            HermesUsageUnmappedReport(
                billingProvider: provider,
                summary: group.summary.finalized(),
                models: group.namedBreakdowns(group.models),
                tasks: group.namedBreakdowns(group.tasks))
        }
        .sorted { $0.billingProvider < $1.billingProvider }

        var warnings = [
            "Hermes state.db stores cumulative per-session rows; this is a current snapshot, not exact daily history.",
            "Actual billed cost, Hermes stored estimates, subscription-included usage, " +
                "and API-equivalent estimates are separate fields.",
            "API-equivalent estimates use standard models.dev rates; cumulative rows cannot reconstruct " +
                "per-request tiered pricing.",
        ]
        if !unmappedReports.isEmpty {
            warnings.append("Unmapped billing_provider values are reported but not attributed to a CodexBar provider.")
        }
        if sources.contains(where: { $0.status != .read }) {
            warnings.append("One or more Hermes databases could not be read; totals have partial source coverage.")
        }

        return HermesUsageReport(
            generatedAt: generatedAt,
            sources: sources,
            summary: overall.finalized(),
            providers: providerReports,
            unmapped: unmappedReports,
            warnings: warnings)
    }

    private func apiEquivalentCost(
        row: HermesUsageRow,
        route: HermesUsageProviderRoute,
        generatedAt: Date) -> Double?
    {
        guard row.tokens.total > 0,
              let lookup = ModelsDevPricingPipeline.lookup(
                  providerID: route.modelsDevProviderID,
                  modelID: row.model,
                  now: generatedAt,
                  cacheRoot: self.modelsDevCacheRoot)
        else { return nil }

        let pricing = lookup.pricing
        // Some subscription catalogs intentionally publish all-zero plan rates. That describes
        // what the plan charges, not an API-equivalent market price. Keep it unpriced rather than
        // turning included usage into a misleading $0 estimate.
        guard pricing.inputCostPerToken > 0
            || pricing.outputCostPerToken > 0
            || (pricing.cacheReadInputCostPerToken ?? 0) > 0
            || (pricing.cacheCreationInputCostPerToken ?? 0) > 0
        else { return nil }
        let input = Double(row.tokens.input) * pricing.inputCostPerToken
        let output = Double(row.tokens.output) * pricing.outputCostPerToken
        let cacheRead = Double(row.tokens.cacheRead)
            * (pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken)
        let cacheWrite = Double(row.tokens.cacheWrite)
            * (pricing.cacheCreationInputCostPerToken ?? pricing.inputCostPerToken)
        return input + output + cacheRead + cacheWrite
    }

    private static func unmappedKey(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "unknown" : normalized
    }
}

private struct HermesUsageRow {
    let sourceLabel: String
    let sessionID: String
    let model: String
    let billingProvider: String
    let billingBaseURL: String
    let billingMode: String
    let task: String
    let tokens: HermesUsageTokenCounts
    let requests: Int
    let estimatedCostUSD: Double
    let actualCostUSD: Double
    let costStatus: String
    let costSource: String

    var isSubscriptionIncluded: Bool {
        self.billingMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "subscription_included"
            || self.costStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "included"
    }

    var taskDisplayName: String {
        let trimmed = self.task.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "agent" : trimmed
    }

    var hasHermesEstimate: Bool {
        guard !self.isSubscriptionIncluded else { return false }
        let status = self.costStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if status == "estimated" || status == "actual" { return true }
        let source = self.costSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return self.estimatedCostUSD > 0 && source != "none"
    }

    var hasActualCost: Bool {
        self.actualCostUSD > 0
    }
}

private struct HermesUsageAccumulator {
    var tokens = HermesUsageTokenCounts()
    var requests = 0
    var sessionIDs: Set<String> = []
    var hermesEstimatedCostUSD = 0.0
    var hasHermesEstimatedCost = false
    var actualCostUSD = 0.0
    var hasActualCost = false
    var subscriptionIncludedTokens = 0
    var subscriptionIncludedRequests = 0
    var apiEquivalentCostUSD = 0.0
    var hasAPIEquivalentCost = false
    var apiEquivalentPricedTokens = 0
    var apiEquivalentUnpricedTokens = 0

    mutating func add(_ row: HermesUsageRow, apiEquivalentCostUSD: Double?) {
        self.tokens += row.tokens
        self.requests += max(0, row.requests)
        if !row.sessionID.isEmpty {
            self.sessionIDs.insert("\(row.sourceLabel)\0\(row.sessionID)")
        }
        if row.hasHermesEstimate {
            self.hermesEstimatedCostUSD += max(0, row.estimatedCostUSD)
            self.hasHermesEstimatedCost = true
        }
        if row.hasActualCost {
            self.actualCostUSD += max(0, row.actualCostUSD)
            self.hasActualCost = true
        }
        if row.isSubscriptionIncluded {
            self.subscriptionIncludedTokens += row.tokens.total
            self.subscriptionIncludedRequests += max(0, row.requests)
        }
        if let apiEquivalentCostUSD {
            self.apiEquivalentCostUSD += max(0, apiEquivalentCostUSD)
            self.apiEquivalentPricedTokens += row.tokens.total
            self.hasAPIEquivalentCost = true
        } else {
            self.apiEquivalentUnpricedTokens += row.tokens.total
        }
    }

    func finalized() -> HermesUsageSummary {
        HermesUsageSummary(
            tokens: self.tokens,
            requests: self.requests,
            sessions: self.sessionIDs.count,
            hermesEstimatedCostUSD: self.hasHermesEstimatedCost ? self.hermesEstimatedCostUSD : nil,
            actualCostUSD: self.hasActualCost ? self.actualCostUSD : nil,
            subscriptionIncludedTokens: self.subscriptionIncludedTokens,
            subscriptionIncludedRequests: self.subscriptionIncludedRequests,
            apiEquivalentCostUSD: self.hasAPIEquivalentCost ? self.apiEquivalentCostUSD : nil,
            apiEquivalentPricedTokens: self.apiEquivalentPricedTokens,
            apiEquivalentUnpricedTokens: self.apiEquivalentUnpricedTokens)
    }
}

private struct HermesUsageGroupAccumulator {
    var summary = HermesUsageAccumulator()
    var billingProviders: Set<String> = []
    var models: [String: HermesUsageAccumulator] = [:]
    var tasks: [String: HermesUsageAccumulator] = [:]

    mutating func add(_ row: HermesUsageRow, apiEquivalentCostUSD: Double?) {
        self.summary.add(row, apiEquivalentCostUSD: apiEquivalentCostUSD)
        var model = self.models[row.model] ?? HermesUsageAccumulator()
        model.add(row, apiEquivalentCostUSD: apiEquivalentCostUSD)
        self.models[row.model] = model
        var task = self.tasks[row.taskDisplayName] ?? HermesUsageAccumulator()
        task.add(row, apiEquivalentCostUSD: apiEquivalentCostUSD)
        self.tasks[row.taskDisplayName] = task
    }

    func namedBreakdowns(_ values: [String: HermesUsageAccumulator]) -> [HermesUsageNamedBreakdown] {
        values.map { name, accumulator in
            HermesUsageNamedBreakdown(name: name, summary: accumulator.finalized())
        }
        .sorted { lhs, rhs in
            if lhs.summary.tokens.total != rhs.summary.tokens.total {
                return lhs.summary.tokens.total > rhs.summary.tokens.total
            }
            return lhs.name < rhs.name
        }
    }
}

private struct HermesUsageReadError: Error {
    let status: HermesUsageSourceStatus
    let message: String
}

#if canImport(SQLite3) || canImport(CSQLite3)
extension HermesUsageScanner {
    private struct SessionAggregate {
        let sessionID: String
        let model: String
        let billingProvider: String
        let billingBaseURL: String
        let billingMode: String
        let tokens: HermesUsageTokenCounts
        let requests: Int
        let estimatedCostUSD: Double
        let actualCostUSD: Double
        let costStatus: String
        let costSource: String
    }

    private struct AttributedTotals {
        var tokens = HermesUsageTokenCounts()
        var requests = 0
        var estimatedCostUSD = 0.0
        var actualCostUSD = 0.0

        mutating func add(_ row: HermesUsageRow) {
            self.tokens += row.tokens
            self.requests += max(0, row.requests)
            self.estimatedCostUSD += max(0, row.estimatedCostUSD)
            self.actualCostUSD += max(0, row.actualCostUSD)
        }
    }

    fileprivate static func readRows(databaseURL: URL, sourceLabel: String) throws -> [HermesUsageRow] {
        var database: OpaquePointer?
        let walExists = FileManager.default.fileExists(atPath: databaseURL.path + "-wal")
        let shmExists = FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
        guard walExists == shmExists else {
            throw HermesUsageReadError(
                status: .unreadable,
                message: "Hermes WAL sidecars are incomplete; refusing to create or replace them")
        }
        // Active WAL needs the ordinary read-only connection so committed WAL rows stay visible.
        // An idle WAL database without sidecars uses immutable mode, which prevents SQLite from
        // recreating -wal/-shm files next to a source CodexBar promises not to modify.
        let query = walExists ? "mode=ro" : "mode=ro&immutable=1"
        let uri = databaseURL.absoluteURL.absoluteString + "?\(query)"
        let openResult = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard openResult == SQLITE_OK else {
            let error = Self.readError(database: database, resultCode: openResult)
            sqlite3_close(database)
            throw error
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        let queryOnlyResult = sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)
        guard queryOnlyResult == SQLITE_OK else {
            throw Self.readError(database: database, resultCode: queryOnlyResult)
        }

        let modelColumns = try Self.tableColumns(database: database, table: "session_model_usage")
        let sessionColumns = try Self.tableColumns(database: database, table: "sessions")
        guard modelColumns != nil || sessionColumns != nil else {
            throw HermesUsageReadError(
                status: .incompatible,
                message: "Neither session_model_usage nor sessions exists")
        }

        var rows: [HermesUsageRow] = []
        if let modelColumns {
            rows = try Self.readModelUsageRows(
                database: database,
                columns: modelColumns,
                sourceLabel: sourceLabel)
        }

        guard let sessionColumns else { return rows }
        let sessions = try Self.readSessionAggregates(database: database, columns: sessionColumns)
        var attributed: [String: AttributedTotals] = [:]
        // Hermes deliberately records auxiliary tasks only in session_model_usage; sessions contains
        // main-loop totals. Subtracting auxiliary rows here would erase an equal amount of legacy
        // main-loop residual whenever task attribution exists but the main-loop attribution does not.
        for row in rows where row.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var totals = attributed[row.sessionID] ?? AttributedTotals()
            totals.add(row)
            attributed[row.sessionID] = totals
        }
        for session in sessions {
            let totals = attributed[session.sessionID] ?? AttributedTotals()
            let residualTokens = HermesUsageTokenCounts.positiveResidual(session.tokens, minus: totals.tokens)
            let residualRequests = max(0, session.requests - totals.requests)
            let residualEstimatedCost = max(0, session.estimatedCostUSD - totals.estimatedCostUSD)
            let residualActualCost = max(0, session.actualCostUSD - totals.actualCostUSD)
            guard residualTokens.total > 0 || residualTokens.reasoning > 0 || residualRequests > 0
                || residualEstimatedCost > 0 || residualActualCost > 0
            else { continue }
            rows.append(HermesUsageRow(
                sourceLabel: sourceLabel,
                sessionID: session.sessionID,
                model: session.model,
                billingProvider: session.billingProvider,
                billingBaseURL: session.billingBaseURL,
                billingMode: session.billingMode,
                task: "",
                tokens: residualTokens,
                requests: residualRequests,
                estimatedCostUSD: residualEstimatedCost,
                actualCostUSD: residualActualCost,
                costStatus: session.costStatus,
                costSource: session.costSource))
        }
        return rows
    }

    private static func readModelUsageRows(
        database: OpaquePointer?,
        columns: Set<String>,
        sourceLabel: String) throws -> [HermesUsageRow]
    {
        let required = [
            "session_id", "model", "billing_provider", "api_call_count", "input_tokens", "output_tokens",
            "cache_read_tokens", "cache_write_tokens",
        ]
        guard required.allSatisfy(columns.contains) else {
            throw HermesUsageReadError(status: .incompatible, message: "session_model_usage has an unsupported schema")
        }
        let query = """
        SELECT session_id, model, billing_provider,
               \(Self.columnExpression(columns, "billing_base_url", fallback: "''")),
               \(Self.columnExpression(columns, "billing_mode", fallback: "''")),
               \(Self.columnExpression(columns, "task", fallback: "''")),
               api_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
               \(Self.columnExpression(columns, "reasoning_tokens", fallback: "0")),
               \(Self.columnExpression(columns, "estimated_cost_usd", fallback: "0")),
               \(Self.columnExpression(columns, "actual_cost_usd", fallback: "0")),
               \(Self.columnExpression(columns, "cost_status", fallback: "''")),
               \(Self.columnExpression(columns, "cost_source", fallback: "''"))
        FROM session_model_usage
        """
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard prepare == SQLITE_OK else { throw Self.readError(database: database, resultCode: prepare) }
        defer { sqlite3_finalize(statement) }

        var rows: [HermesUsageRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Self.readError(database: database, resultCode: step) }
            rows.append(HermesUsageRow(
                sourceLabel: sourceLabel,
                sessionID: Self.text(statement, 0),
                model: Self.nonEmptyText(statement, 1) ?? "unknown",
                billingProvider: Self.text(statement, 2),
                billingBaseURL: Self.text(statement, 3),
                billingMode: Self.text(statement, 4),
                task: Self.text(statement, 5),
                tokens: HermesUsageTokenCounts(
                    input: Self.integer(statement, 7),
                    output: Self.integer(statement, 8),
                    cacheRead: Self.integer(statement, 9),
                    cacheWrite: Self.integer(statement, 10),
                    reasoning: Self.integer(statement, 11)),
                requests: Self.integer(statement, 6),
                estimatedCostUSD: max(0, sqlite3_column_double(statement, 12)),
                actualCostUSD: max(0, sqlite3_column_double(statement, 13)),
                costStatus: Self.text(statement, 14),
                costSource: Self.text(statement, 15)))
        }
        return rows
    }

    private static func readSessionAggregates(
        database: OpaquePointer?,
        columns: Set<String>) throws -> [SessionAggregate]
    {
        let required = ["id", "model", "billing_provider", "api_call_count", "input_tokens", "output_tokens"]
        guard required.allSatisfy(columns.contains) else {
            throw HermesUsageReadError(status: .incompatible, message: "sessions has an unsupported usage schema")
        }
        let query = """
        SELECT id, model, billing_provider,
               \(Self.columnExpression(columns, "billing_base_url", fallback: "''")),
               \(Self.columnExpression(columns, "billing_mode", fallback: "''")),
               api_call_count, input_tokens, output_tokens,
               \(Self.columnExpression(columns, "cache_read_tokens", fallback: "0")),
               \(Self.columnExpression(columns, "cache_write_tokens", fallback: "0")),
               \(Self.columnExpression(columns, "reasoning_tokens", fallback: "0")),
               \(Self.columnExpression(columns, "estimated_cost_usd", fallback: "0")),
               \(Self.columnExpression(columns, "actual_cost_usd", fallback: "0")),
               \(Self.columnExpression(columns, "cost_status", fallback: "''")),
               \(Self.columnExpression(columns, "cost_source", fallback: "''"))
        FROM sessions
        """
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard prepare == SQLITE_OK else { throw Self.readError(database: database, resultCode: prepare) }
        defer { sqlite3_finalize(statement) }

        var rows: [SessionAggregate] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Self.readError(database: database, resultCode: step) }
            rows.append(SessionAggregate(
                sessionID: Self.text(statement, 0),
                model: Self.nonEmptyText(statement, 1) ?? "unknown",
                billingProvider: Self.text(statement, 2),
                billingBaseURL: Self.text(statement, 3),
                billingMode: Self.text(statement, 4),
                tokens: HermesUsageTokenCounts(
                    input: Self.integer(statement, 6),
                    output: Self.integer(statement, 7),
                    cacheRead: Self.integer(statement, 8),
                    cacheWrite: Self.integer(statement, 9),
                    reasoning: Self.integer(statement, 10)),
                requests: Self.integer(statement, 5),
                estimatedCostUSD: max(0, sqlite3_column_double(statement, 11)),
                actualCostUSD: max(0, sqlite3_column_double(statement, 12)),
                costStatus: Self.text(statement, 13),
                costSource: Self.text(statement, 14)))
        }
        return rows
    }

    private static func tableColumns(database: OpaquePointer?, table: String) throws -> Set<String>? {
        var existsStatement: OpaquePointer?
        let existsQuery = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var result = sqlite3_prepare_v2(database, existsQuery, -1, &existsStatement, nil)
        guard result == SQLITE_OK else { throw Self.readError(database: database, resultCode: result) }
        defer { sqlite3_finalize(existsStatement) }
        sqlite3_bind_text(existsStatement, 1, table, -1, hermesSQLiteTransient)
        result = sqlite3_step(existsStatement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw Self.readError(database: database, resultCode: result) }

        var statement: OpaquePointer?
        let query = "PRAGMA table_info('\(table)')"
        result = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard result == SQLITE_OK else { throw Self.readError(database: database, resultCode: result) }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while true {
            result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Self.readError(database: database, resultCode: result) }
            columns.insert(Self.text(statement, 1))
        }
        return columns
    }

    private static func columnExpression(_ columns: Set<String>, _ column: String, fallback: String) -> String {
        columns.contains(column) ? "COALESCE(\(column), \(fallback))" : fallback
    }

    private static func integer(_ statement: OpaquePointer?, _ index: Int32) -> Int {
        let value = max(Int64(0), sqlite3_column_int64(statement, index))
        return value > Int64(Int.max) ? Int.max : Int(value)
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index)
        else { return "" }
        return String(cString: value)
    }

    private static func nonEmptyText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        let value = Self.text(statement, index).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func readError(database: OpaquePointer?, resultCode: Int32) -> HermesUsageReadError {
        let primaryCode = resultCode & 0xFF
        let status: HermesUsageSourceStatus = switch primaryCode {
        case SQLITE_BUSY, SQLITE_LOCKED: .locked
        case SQLITE_CORRUPT, SQLITE_NOTADB: .corrupt
        default: .unreadable
        }
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(resultCode)"
        return HermesUsageReadError(status: status, message: message)
    }
}
#else
extension HermesUsageScanner {
    fileprivate static func readRows(databaseURL _: URL, sourceLabel _: String) throws -> [HermesUsageRow] {
        throw HermesUsageReadError(status: .incompatible, message: "SQLite support is unavailable")
    }
}
#endif
