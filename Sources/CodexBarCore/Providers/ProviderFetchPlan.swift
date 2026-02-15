import Foundation

public enum ProviderRuntime: Sendable {
    case app
    case cli
}

public enum ProviderSourceMode: String, CaseIterable, Sendable, Codable {
    case auto
    case web
    case cli
    case oauth
    case api

    public var usesWeb: Bool {
        self == .auto || self == .web
    }
}

public struct ProviderFetchContext: Sendable {
    public let runtime: ProviderRuntime
    public let sourceMode: ProviderSourceMode
    public let includeCredits: Bool
    public let webTimeout: TimeInterval
    public let webDebugDumpHTML: Bool
    public let verbose: Bool
    public let env: [String: String]
    public let settings: ProviderSettingsSnapshot?
    public let fetcher: UsageFetcher
    public let claudeFetcher: any ClaudeUsageFetching
    public let browserDetection: BrowserDetection
    public let onAntigravityCredentialsRefreshed: (@Sendable (String, AntigravityOAuthCredentials) -> Void)?

    public init(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        includeCredits: Bool,
        webTimeout: TimeInterval,
        webDebugDumpHTML: Bool,
        verbose: Bool,
        env: [String: String],
        settings: ProviderSettingsSnapshot?,
        fetcher: UsageFetcher,
        claudeFetcher: any ClaudeUsageFetching,
        browserDetection: BrowserDetection,
        onAntigravityCredentialsRefreshed: (@Sendable (String, AntigravityOAuthCredentials) -> Void)? = nil)
    {
        self.runtime = runtime
        self.sourceMode = sourceMode
        self.includeCredits = includeCredits
        self.webTimeout = webTimeout
        self.webDebugDumpHTML = webDebugDumpHTML
        self.verbose = verbose
        self.env = env
        self.settings = settings
        self.fetcher = fetcher
        self.claudeFetcher = claudeFetcher
        self.browserDetection = browserDetection
        self.onAntigravityCredentialsRefreshed = onAntigravityCredentialsRefreshed
    }
}

public struct ProviderFetchResult: Sendable {
    public let usage: UsageSnapshot
    public let credits: CreditsSnapshot?
    public let dashboard: OpenAIDashboardSnapshot?
    public let sourceLabel: String
    public let strategyID: String
    public let strategyKind: ProviderFetchKind

    public init(
        usage: UsageSnapshot,
        credits: CreditsSnapshot?,
        dashboard: OpenAIDashboardSnapshot?,
        sourceLabel: String,
        strategyID: String,
        strategyKind: ProviderFetchKind)
    {
        self.usage = usage
        self.credits = credits
        self.dashboard = dashboard
        self.sourceLabel = sourceLabel
        self.strategyID = strategyID
        self.strategyKind = strategyKind
    }
}

public struct ProviderFetchAttempt: Sendable {
    public let strategyID: String
    public let kind: ProviderFetchKind
    public let wasAvailable: Bool
    public let errorDescription: String?

    public init(strategyID: String, kind: ProviderFetchKind, wasAvailable: Bool, errorDescription: String?) {
        self.strategyID = strategyID
        self.kind = kind
        self.wasAvailable = wasAvailable
        self.errorDescription = errorDescription
    }
}

public struct ProviderFetchOutcome: @unchecked Sendable {
    public let result: Result<ProviderFetchResult, Error>
    public let attempts: [ProviderFetchAttempt]

    public init(result: Result<ProviderFetchResult, Error>, attempts: [ProviderFetchAttempt]) {
        self.result = result
        self.attempts = attempts
    }
}

public enum ProviderFetchError: LocalizedError, Sendable {
    case noAvailableStrategy(UsageProvider)

    public var errorDescription: String? {
        switch self {
        case let .noAvailableStrategy(provider):
            "No available fetch strategy for \(provider.rawValue)."
        }
    }
}

public enum ProviderFetchKind: Sendable {
    case cli
    case web
    case oauth
    case apiToken
    case localProbe
    case webDashboard
}

public protocol ProviderFetchStrategy: Sendable {
    var id: String { get }
    var kind: ProviderFetchKind { get }
    func isAvailable(_ context: ProviderFetchContext) async -> Bool
    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult
    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool
}

extension ProviderFetchStrategy {
    public func makeResult(
        usage: UsageSnapshot,
        credits: CreditsSnapshot? = nil,
        dashboard: OpenAIDashboardSnapshot? = nil,
        sourceLabel: String) -> ProviderFetchResult
    {
        ProviderFetchResult(
            usage: usage,
            credits: credits,
            dashboard: dashboard,
            sourceLabel: sourceLabel,
            strategyID: self.id,
            strategyKind: self.kind)
    }
}

public struct ProviderFetchPipeline: Sendable {
    public let resolveStrategies: @Sendable (ProviderFetchContext) async -> [any ProviderFetchStrategy]

    public init(resolveStrategies: @escaping @Sendable (ProviderFetchContext) async -> [any ProviderFetchStrategy]) {
        self.resolveStrategies = resolveStrategies
    }

    public func fetch(context: ProviderFetchContext, provider: UsageProvider) async -> ProviderFetchOutcome {
        let strategies = await self.resolveStrategies(context)
        var attempts: [ProviderFetchAttempt] = []
        attempts.reserveCapacity(strategies.count)

        for strategy in strategies {
            let available = await strategy.isAvailable(context)

            guard available else {
                attempts.append(ProviderFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: false,
                    errorDescription: nil))
                continue
            }

            do {
                let result = try await strategy.fetch(context)
                attempts.append(ProviderFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: true,
                    errorDescription: nil))
                return ProviderFetchOutcome(result: .success(result), attempts: attempts)
            } catch {
                attempts.append(ProviderFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: true,
                    errorDescription: error.localizedDescription))
                if strategy.shouldFallback(on: error, context: context) {
                    continue
                }
                return ProviderFetchOutcome(result: .failure(error), attempts: attempts)
            }
        }

        let error = ProviderFetchError.noAvailableStrategy(provider)
        return ProviderFetchOutcome(result: .failure(error), attempts: attempts)
    }
}

public struct ProviderFetchPlan: Sendable {
    public let sourceModes: Set<ProviderSourceMode>
    public let pipeline: ProviderFetchPipeline

    public init(sourceModes: Set<ProviderSourceMode>, pipeline: ProviderFetchPipeline) {
        self.sourceModes = sourceModes
        self.pipeline = pipeline
    }

    public func fetchOutcome(context: ProviderFetchContext, provider: UsageProvider) async -> ProviderFetchOutcome {
        await self.pipeline.fetch(context: context, provider: provider)
    }
}
