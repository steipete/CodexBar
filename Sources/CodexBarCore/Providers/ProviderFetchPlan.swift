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
    public typealias TokenAccountTokenUpdater = @Sendable (UsageProvider, UUID, String) async -> Void
    public typealias ProviderManualTokenUpdater = @Sendable (UsageProvider, String) async -> Void

    public let runtime: ProviderRuntime
    public let sourceMode: ProviderSourceMode
    public let includeCredits: Bool
    public let includeOptionalUsage: Bool
    public let webTimeout: TimeInterval
    public let webDebugDumpHTML: Bool
    public let verbose: Bool
    public let env: [String: String]
    public let settings: ProviderSettingsSnapshot?
    public let fetcher: UsageFetcher
    public let claudeFetcher: any ClaudeUsageFetching
    public let browserDetection: BrowserDetection
    public let selectedTokenAccountID: UUID?
    public let tokenAccountTokenUpdater: TokenAccountTokenUpdater?
    public let providerManualTokenUpdater: ProviderManualTokenUpdater?
    public let costUsageHistoryDays: Int
    /// Whether warm CLI helper sessions (such as the managed Antigravity `agy`
    /// process) may outlive a single fetch. True for long-lived hosts (the app,
    /// `codexbar serve`); false for one-shot CLI invocations that should reset
    /// the session after each fetch.
    public let persistsCLISessions: Bool
    /// Minimum idle lifetime for persistent CLI helper sessions. Long-lived
    /// hosts set this beyond their refresh cadence so a slow cold start can
    /// recover on the next refresh.
    public let persistentCLISessionIdleWindow: TimeInterval?

    public init(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        includeCredits: Bool,
        includeOptionalUsage: Bool = true,
        webTimeout: TimeInterval,
        webDebugDumpHTML: Bool,
        verbose: Bool,
        env: [String: String],
        settings: ProviderSettingsSnapshot?,
        fetcher: UsageFetcher,
        claudeFetcher: any ClaudeUsageFetching,
        browserDetection: BrowserDetection,
        selectedTokenAccountID: UUID? = nil,
        tokenAccountTokenUpdater: TokenAccountTokenUpdater? = nil,
        providerManualTokenUpdater: ProviderManualTokenUpdater? = nil,
        costUsageHistoryDays: Int = 30,
        persistsCLISessions: Bool = false,
        persistentCLISessionIdleWindow: TimeInterval? = nil)
    {
        self.runtime = runtime
        self.sourceMode = sourceMode
        self.includeCredits = includeCredits
        self.includeOptionalUsage = includeOptionalUsage
        self.webTimeout = webTimeout
        self.webDebugDumpHTML = webDebugDumpHTML
        self.verbose = verbose
        self.env = env
        self.settings = settings
        self.fetcher = fetcher
        self.claudeFetcher = claudeFetcher
        self.browserDetection = browserDetection
        self.selectedTokenAccountID = selectedTokenAccountID
        self.tokenAccountTokenUpdater = tokenAccountTokenUpdater
        self.providerManualTokenUpdater = providerManualTokenUpdater
        self.costUsageHistoryDays = max(1, min(365, costUsageHistoryDays))
        self.persistsCLISessions = persistsCLISessions
        self.persistentCLISessionIdleWindow = persistentCLISessionIdleWindow
    }
}

public enum ProviderCLISessionLifecycle {
    public static func shutdownPersistentSessions() async {
        await AntigravityCLISession.shared.reset()
    }
}

public struct ProviderFetchResult: Sendable {
    public let usage: UsageSnapshot
    public let credits: CreditsSnapshot?
    public let dashboard: OpenAIDashboardSnapshot?
    public let sourceLabel: String
    public let strategyID: String
    public let strategyKind: ProviderFetchKind
    /// Optional live diagnostic retained alongside an otherwise usable snapshot.
    public let diagnostic: String?
    /// Transient account ownership evidence for plan-utilization history.
    /// The raw Keychain reference never enters the persisted usage snapshot.
    public let claudeOAuthKeychainPersistentRefHash: String?
    /// A one-way discriminator derived from the winning Claude OAuth credential.
    /// Raw access and refresh tokens never enter the fetch result or persisted history.
    public let claudeOAuthHistoryOwnerIdentifier: String?
    /// Whether a prompt-free comparison proved the winning credential differs from Claude Code's Keychain entry.
    public let claudeOAuthKeychainCredentialMismatch: Bool
    /// Whether a prompt-free probe proved Claude Code has no Keychain credential.
    public let claudeOAuthKeychainCredentialAbsent: Bool
    /// Whether the winning Claude CLI credential could not be compared with Keychain without prompting.
    public let claudeOAuthKeychainCredentialUnavailable: Bool

    public init(
        usage: UsageSnapshot,
        credits: CreditsSnapshot?,
        dashboard: OpenAIDashboardSnapshot?,
        sourceLabel: String,
        strategyID: String,
        strategyKind: ProviderFetchKind,
        diagnostic: String? = nil,
        claudeOAuthKeychainPersistentRefHash: String? = nil,
        claudeOAuthHistoryOwnerIdentifier: String? = nil,
        claudeOAuthKeychainCredentialMismatch: Bool = false,
        claudeOAuthKeychainCredentialAbsent: Bool = false,
        claudeOAuthKeychainCredentialUnavailable: Bool = false)
    {
        self.usage = usage
        self.credits = credits
        self.dashboard = dashboard
        self.sourceLabel = sourceLabel
        self.strategyID = strategyID
        self.strategyKind = strategyKind
        self.diagnostic = diagnostic
        self.claudeOAuthKeychainPersistentRefHash = claudeOAuthKeychainPersistentRefHash
        self.claudeOAuthHistoryOwnerIdentifier = claudeOAuthHistoryOwnerIdentifier
        self.claudeOAuthKeychainCredentialMismatch = claudeOAuthKeychainCredentialMismatch
        self.claudeOAuthKeychainCredentialAbsent = claudeOAuthKeychainCredentialAbsent
        self.claudeOAuthKeychainCredentialUnavailable = claudeOAuthKeychainCredentialUnavailable
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
        sourceLabel: String,
        diagnostic: String? = nil) -> ProviderFetchResult
    {
        ProviderFetchResult(
            usage: usage,
            credits: credits,
            dashboard: dashboard,
            sourceLabel: sourceLabel,
            strategyID: self.id,
            strategyKind: self.kind,
            diagnostic: diagnostic)
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
        var lastAvailableError: Error?

        guard !Task.isCancelled else {
            return ProviderFetchOutcome(result: .failure(CancellationError()), attempts: attempts)
        }

        for strategy in strategies {
            guard !Task.isCancelled else {
                return ProviderFetchOutcome(result: .failure(CancellationError()), attempts: attempts)
            }
            let available = await strategy.isAvailable(context)

            guard !Task.isCancelled else {
                return ProviderFetchOutcome(result: .failure(CancellationError()), attempts: attempts)
            }
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
                try Task.checkCancellation()
                attempts.append(ProviderFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: true,
                    errorDescription: nil))
                return ProviderFetchOutcome(result: .success(result), attempts: attempts)
            } catch {
                lastAvailableError = error
                attempts.append(ProviderFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: true,
                    errorDescription: error.localizedDescription))
                if Task.isCancelled || error is CancellationError {
                    return ProviderFetchOutcome(result: .failure(CancellationError()), attempts: attempts)
                }
                if strategy.shouldFallback(on: error, context: context) {
                    continue
                }
                return ProviderFetchOutcome(result: .failure(error), attempts: attempts)
            }
        }

        let error = lastAvailableError ?? ProviderFetchError.noAvailableStrategy(provider)
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
