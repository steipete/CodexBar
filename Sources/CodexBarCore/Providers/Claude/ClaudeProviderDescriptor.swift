import Foundation

public enum ClaudeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .claude,
            metadata: ProviderMetadata(
                id: .claude,
                displayName: "Claude",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: "Sonnet",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Claude Code usage",
                cliName: "claude",
                defaultEnabled: false,
                isPrimaryProvider: true,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://console.anthropic.com/settings/billing",
                subscriptionDashboardURL: "https://claude.ai/settings/usage",
                changelogURL: "https://github.com/anthropics/claude-code/releases",
                statusPageURL: "https://status.claude.com/"),
            branding: ProviderBranding(
                iconStyle: .claude,
                iconResourceName: "ProviderIcon-claude",
                color: ProviderColor(red: 204 / 255, green: 124 / 255, blue: 94 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: self.noDataMessage),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web, .cli, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "claude",
                versionDetector: { browserDetection in
                    ClaudeUsageFetcher(browserDetection: browserDetection).detectVersion()
                }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        if context.sourceMode == .api || self.hasAutoAdminAPIKey(context: context) {
            return [ClaudeAdminAPIFetchStrategy()]
        }
        if ClaudeAdminAPIFetchStrategy.isSelectedAdminAPIAccount(context: context) {
            return [ClaudeAdminAPIFetchStrategy()]
        }

        let planningInput = Self.makePlanningInput(context: context)
        let plan = ClaudeSourcePlanner.resolve(input: planningInput)
        let manualCookieHeader = Self.manualCookieHeader(from: context)

        return plan.orderedSteps.map { step in
            let strategy: any ProviderFetchStrategy = switch step.dataSource {
            case .api:
                ClaudeAdminAPIFetchStrategy()
            case .oauth:
                ClaudeOAuthFetchStrategy()
            case .web:
                ClaudeWebFetchStrategy(browserDetection: context.browserDetection)
            case .cli:
                ClaudeCLIFetchStrategy(
                    useWebExtras: context.runtime == .app
                        && planningInput.webExtrasEnabled,
                    manualCookieHeader: manualCookieHeader,
                    browserDetection: context.browserDetection,
                    hasWebFallback: planningInput.hasWebSession)
            case .auto:
                fatalError("Planner must not emit .auto as an executable step.")
            }
            return ClaudePlannedFetchStrategy(base: strategy, plannedStep: step)
        }
    }

    private static func hasAutoAdminAPIKey(context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto && ClaudeAdminAPISettingsReader.apiKey(environment: context.env) != nil
    }

    private static func makePlanningInput(context: ProviderFetchContext) -> ClaudeSourcePlanningInput {
        let webExtrasEnabled = context.settings?.claude?.webExtrasEnabled ?? false
        let needsOAuthAvailability = context.runtime == .app && context.sourceMode == .auto
        let hasWebSession = Self.hasPlausibleWebSession(context: context)

        return ClaudeSourcePlanningInput(
            runtime: context.runtime,
            selectedDataSource: Self.sourceDataSource(from: context.sourceMode),
            webExtrasEnabled: webExtrasEnabled,
            hasWebSession: hasWebSession,
            hasCLI: ClaudeCLIResolver.isAvailable(environment: context.env),
            hasOAuthCredentials: needsOAuthAvailability && ClaudeOAuthPlanningAvailability.isAvailable(
                runtime: context.runtime,
                sourceMode: context.sourceMode,
                environment: context.env))
    }

    private static func hasPlausibleWebSession(context: ProviderFetchContext) -> Bool {
        switch context.sourceMode {
        case .api, .oauth, .cli:
            return false
        case .web:
            // Explicit web performs its cookie/session work inside the bounded fetch.
            return context.settings?.claude?.cookieSource != .off
        case .auto:
            break
        }

        guard ClaudeWebFetchStrategy.isSupportedOnCurrentPlatform else { return false }

        switch context.settings?.claude?.cookieSource {
        case .off?:
            return false
        case .manual?:
            return ClaudeWebFetchStrategy.hasManualSessionKey(context: context)
        case .auto?, nil:
            // Browser/Keychain inspection can block. Keep planning synchronous and let the web step
            // perform the bounded availability check if app-auto actually reaches its last fallback.
            // CLI auto continues to perform its real session import inside the bounded web fetch.
            return true
        }
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.claude?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.claude?.manualCookieHeader)
    }

    private static func noDataMessage() -> String {
        "No Claude usage logs found in ~/.config/claude/projects, ~/.claude/projects, " +
            "or Claude Desktop sessions."
    }

    public static func resolveUsageStrategy(
        selectedDataSource: ClaudeUsageDataSource,
        webExtrasEnabled: Bool,
        hasWebSession: Bool,
        hasCLI: Bool,
        hasOAuthCredentials: Bool) -> ClaudeUsageStrategy
    {
        let plan = ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: selectedDataSource,
            webExtrasEnabled: webExtrasEnabled,
            hasWebSession: hasWebSession,
            hasCLI: hasCLI,
            hasOAuthCredentials: hasOAuthCredentials))
        return plan.compatibilityStrategy ?? ClaudeUsageStrategy(dataSource: selectedDataSource, useWebExtras: false)
    }

    private static func sourceDataSource(from mode: ProviderSourceMode) -> ClaudeUsageDataSource {
        switch mode {
        case .auto:
            .auto
        case .api:
            .api
        case .web:
            .web
        case .cli:
            .cli
        case .oauth:
            .oauth
        }
    }
}

public struct ClaudeUsageStrategy: Equatable, Sendable {
    public let dataSource: ClaudeUsageDataSource
    public let useWebExtras: Bool
}

public enum ClaudeOAuthPlanningAvailability {
    public static func isAvailable(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        environment: [String: String]) -> Bool
    {
        ClaudeOAuthFetchStrategy.isPlausiblyAvailable(
            runtime: runtime,
            sourceMode: sourceMode,
            environment: environment)
    }
}

private struct ClaudePlannedFetchStrategy: ProviderFetchStrategy {
    let base: any ProviderFetchStrategy
    let plannedStep: ClaudeFetchPlanStep

    var id: String {
        self.base.id
    }

    var kind: ProviderFetchKind {
        self.base.kind
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.sourceMode == .auto else {
            return await self.base.isAvailable(context)
        }
        guard self.plannedStep.isPlausiblyAvailable else { return false }
        if context.runtime == .app,
           self.plannedStep.dataSource == .cli || self.plannedStep.dataSource == .web
        {
            return await self.base.isAvailable(context)
        }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try await self.base.fetch(context)
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        self.base.shouldFallback(on: error, context: context)
    }
}

struct ClaudeAdminAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "claude.admin-api"
    let kind: ProviderFetchKind = .apiToken
    let usageFetcher: @Sendable (String) async throws -> ClaudeAdminAPIUsageSnapshot

    init(
        usageFetcher: @escaping @Sendable (String) async throws -> ClaudeAdminAPIUsageSnapshot = { apiKey in
            try await ClaudeAdminAPIUsageFetcher.fetchUsage(apiKey: apiKey)
        })
    {
        self.usageFetcher = usageFetcher
    }

    static func isSelectedAdminAPIAccount(context: ProviderFetchContext) -> Bool {
        guard context.selectedTokenAccountID != nil else { return false }
        return self.resolveToken(environment: context.env) != nil
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw ClaudeAdminAPISettingsError.missingToken
        }
        let usage = try await self.usageFetcher(apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "admin-api")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.runtime == .app &&
            context.sourceMode == .auto &&
            !Self.isSelectedAdminAPIAccount(context: context)
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.claudeAdminAPIToken(environment: environment)
    }
}

struct ClaudeOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "claude.oauth"
    let kind: ProviderFetchKind = .oauth

    #if DEBUG
    @TaskLocal static var nonInteractiveCredentialRecordOverride: ClaudeOAuthCredentialRecord?
    @TaskLocal static var claudeCLIAvailableOverride: Bool?
    #endif

    private func loadNonInteractiveCredentialRecord(environment: [String: String]) -> ClaudeOAuthCredentialRecord? {
        #if DEBUG
        if let override = Self.nonInteractiveCredentialRecordOverride { return override }
        #endif

        return try? ClaudeOAuthCredentialsStore.loadRecord(
            environment: environment,
            allowKeychainPrompt: false,
            respectKeychainPromptCooldown: true,
            allowClaudeKeychainRepairWithoutPrompt: false)
    }

    private func isClaudeCLIAvailable(environment: [String: String]) -> Bool {
        #if DEBUG
        if let override = Self.claudeCLIAvailableOverride { return override }
        #endif
        return ClaudeCLIResolver.isAvailable(environment: environment)
    }

    static func isPlausiblyAvailable(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        environment: [String: String]) -> Bool
    {
        let hasEnvironmentOAuthToken = !(environment[ClaudeOAuthCredentialsStore.environmentTokenKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        if hasEnvironmentOAuthToken {
            return true
        }

        let strategy = ClaudeOAuthFetchStrategy()
        let nonInteractiveRecord = strategy.loadNonInteractiveCredentialRecord(environment: environment)
        let nonInteractiveCredentials = nonInteractiveRecord?.credentials
        let hasRequiredScopeWithoutPrompt = nonInteractiveCredentials?.scopes.contains("user:profile") == true
        if hasRequiredScopeWithoutPrompt, nonInteractiveCredentials?.isExpired == false {
            return true
        }

        let claudeCLIAvailable = strategy.isClaudeCLIAvailable(environment: environment)

        if let nonInteractiveRecord, hasRequiredScopeWithoutPrompt, nonInteractiveRecord.credentials.isExpired {
            switch nonInteractiveRecord.owner {
            case .codexbar:
                let refreshToken = nonInteractiveRecord.credentials.refreshToken?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if sourceMode == .auto {
                    return !refreshToken.isEmpty
                }
                return true
            case .claudeCLI:
                if sourceMode == .auto {
                    return claudeCLIAvailable
                }
                return true
            case .environment:
                return sourceMode != .auto
            }
        }

        guard sourceMode == .auto else { return true }

        let fallbackPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode()
        let promptPolicyApplicable = ClaudeOAuthKeychainPromptPreference.isApplicable()
        if ProviderInteractionContext.current == .userInitiated {
            _ = ClaudeOAuthKeychainAccessGate.clearDenied()
        }

        let shouldAllowStartupBootstrap = runtime == .app &&
            ProviderRefreshContext.current == .startup &&
            ProviderInteractionContext.current == .background &&
            fallbackPromptMode == .onlyOnUserAction &&
            !ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: environment)
        if shouldAllowStartupBootstrap {
            return ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
        }

        if promptPolicyApplicable,
           !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
        {
            return false
        }
        return ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt()
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.isPlausiblyAvailable(
            runtime: context.runtime,
            sourceMode: context.sourceMode,
            environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: context.browserDetection,
            environment: context.env,
            runtime: context.runtime,
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: context.sourceMode == .auto,
            allowBackgroundDelegatedRefresh: false,
            allowStartupBootstrapPrompt: context.runtime == .app &&
                (context.sourceMode == .auto || context.sourceMode == .oauth),
            useWebExtras: false)
        let usage = try await fetcher.loadLatestUsage(model: "sonnet")
        return ProviderFetchResult(
            usage: Self.snapshot(from: usage),
            credits: nil,
            dashboard: nil,
            sourceLabel: "oauth",
            strategyID: self.id,
            strategyKind: self.kind,
            claudeOAuthKeychainPersistentRefHash: usage.oauthKeychainPersistentRefHash,
            claudeOAuthHistoryOwnerIdentifier: usage.oauthHistoryOwnerIdentifier,
            claudeOAuthKeychainCredentialMismatch: usage.oauthKeychainCredentialMismatch,
            claudeOAuthKeychainCredentialAbsent: usage.oauthKeychainCredentialAbsent,
            claudeOAuthKeychainCredentialUnavailable: usage.oauthKeychainCredentialUnavailable)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        // In Auto mode, fall back to the next strategy (cli/web) if OAuth fails (e.g. user cancels keychain prompt
        // or auth breaks).
        context.runtime == .app && context.sourceMode == .auto
    }

    fileprivate static func snapshot(from usage: ClaudeUsageSnapshot) -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: usage.accountEmail,
            accountOrganization: usage.accountOrganization,
            loginMethod: usage.loginMethod)
        let primary = usage.primaryWindowKind == .spendLimit ? nil : usage.primary
        return UsageSnapshot(
            primary: primary,
            secondary: usage.secondary,
            tertiary: usage.opus,
            extraRateWindows: usage.extraRateWindows.isEmpty ? nil : usage.extraRateWindows,
            providerCost: usage.providerCost,
            updatedAt: usage.updatedAt,
            identity: identity)
    }

    static func _snapshotForTesting(from usage: ClaudeUsageSnapshot) -> UsageSnapshot {
        self.snapshot(from: usage)
    }
}

private final class ClaudeWebFetchDeadlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: ContinuousClock.Instant?

    func remainingBudget(
        fullBudget: Duration,
        now: ContinuousClock.Instant) -> Duration
    {
        self.lock.lock()
        defer { self.lock.unlock() }

        let deadline: ContinuousClock.Instant
        if let existingDeadline = self.deadline {
            deadline = existingDeadline
        } else {
            deadline = now.advanced(by: fullBudget)
            self.deadline = deadline
        }
        return max(.zero, now.duration(to: deadline))
    }
}

struct ClaudeWebFetchStrategy: ProviderFetchStrategy {
    typealias UsageLoader = @Sendable (ProviderFetchContext) async throws -> ClaudeUsageSnapshot
    typealias DeadlineNow = @Sendable () -> ContinuousClock.Instant

    #if DEBUG
    @TaskLocal static var availabilityProbeOverrideForTesting:
        (@Sendable (ProviderFetchContext, BrowserDetection) -> Bool)?
    @TaskLocal static var usageLoaderOverrideForTesting: UsageLoader?
    #endif

    let id: String = "claude.web"
    let kind: ProviderFetchKind = .web
    let browserDetection: BrowserDetection
    private let usageLoader: UsageLoader?
    private let deadlineState: ClaudeWebFetchDeadlineState
    private let deadlineNow: DeadlineNow

    init(
        browserDetection: BrowserDetection,
        usageLoader: UsageLoader? = nil,
        deadlineNow: @escaping DeadlineNow = { ContinuousClock.now })
    {
        self.browserDetection = browserDetection
        self.usageLoader = usageLoader
        self.deadlineState = ClaudeWebFetchDeadlineState()
        self.deadlineNow = deadlineNow
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let appAutoRemainingBudget: Duration?
        if context.runtime == .app, context.sourceMode == .auto {
            guard let fullBudget = Self.timeoutDuration(context.webTimeout) else { return false }
            let remainingBudget = self.deadlineState.remainingBudget(
                fullBudget: fullBudget,
                now: self.deadlineNow())
            guard remainingBudget > .zero else { return false }
            appAutoRemainingBudget = remainingBudget
        } else {
            appAutoRemainingBudget = nil
        }

        return switch context.settings?.claude?.cookieSource {
        case .off?:
            false
        case .manual?:
            Self.hasManualSessionKey(context: context)
        case .auto?, nil:
            if let appAutoRemainingBudget {
                await Self.hasBrowserSessionKey(context: context, before: appAutoRemainingBudget)
            } else {
                // Explicit web and CLI auto perform the real browser import inside the bounded fetch.
                true
            }
        }
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try await self.loadUsage(before: context.webTimeout, context: context)
        return self.makeResult(
            usage: ClaudeOAuthFetchStrategy.snapshot(from: usage),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        guard !Task.isCancelled,
              !(error is CancellationError),
              (error as? URLError)?.code != .cancelled
        else {
            return false
        }
        // In CLI runtime auto mode, web comes before CLI so fallback is required.
        // In app runtime auto mode, web is terminal and should surface its concrete error.
        return context.runtime == .cli
    }

    fileprivate static func hasManualSessionKey(context: ProviderFetchContext) -> Bool {
        ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: self.manualCookieHeader(from: context))
    }

    fileprivate static func hasBrowserSessionKey(
        context: ProviderFetchContext,
        before timeout: Duration) async -> Bool
    {
        let browserDetection = context.browserDetection
        let sourceTask = Task<Bool, Error> {
            #if DEBUG
            if let override = Self.availabilityProbeOverrideForTesting {
                return override(context, browserDetection)
            }
            #endif
            return ClaudeWebAPIFetcher.hasSessionKey(browserDetection: browserDetection)
        }
        let race = BoundedTaskJoin(sourceTask: sourceTask)
        switch await race.value(joinGrace: timeout) {
        case let .value(isAvailable):
            return isAvailable
        case .failure, .timedOut:
            return false
        }
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.claude?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.claude?.manualCookieHeader)
    }

    private func loadUsage(
        before timeout: TimeInterval,
        context: ProviderFetchContext) async throws -> ClaudeUsageSnapshot
    {
        guard let timeoutDuration = Self.timeoutDuration(timeout) else {
            throw ClaudeWebFetchStrategyError.invalidTimeout
        }
        let remainingBudget = self.deadlineState.remainingBudget(
            fullBudget: timeoutDuration,
            now: self.deadlineNow())
        guard remainingBudget > .zero else {
            try Task.checkCancellation()
            throw ClaudeWebFetchStrategyError.timedOut(seconds: timeout)
        }
        let sourceTask = Task<ClaudeUsageSnapshot, Error> {
            if let usageLoader = self.usageLoader {
                return try await usageLoader(context)
            }
            #if DEBUG
            if let usageLoader = Self.usageLoaderOverrideForTesting {
                return try await usageLoader(context)
            }
            #endif
            let fetcher = ClaudeUsageFetcher(
                browserDetection: self.browserDetection,
                dataSource: .web,
                useWebExtras: false,
                manualCookieHeader: Self.manualCookieHeader(from: context),
                webOrganizationID: context.settings?.claude?.organizationID)
            return try await fetcher.loadLatestUsage(model: "sonnet")
        }
        let race = BoundedTaskJoin(sourceTask: sourceTask)
        switch await race.value(joinGrace: remainingBudget) {
        case let .value(usage):
            try Task.checkCancellation()
            return usage
        case let .failure(error):
            throw error
        case .timedOut:
            try Task.checkCancellation()
            throw ClaudeWebFetchStrategyError.timedOut(seconds: timeout)
        }
    }

    private static func timeoutDuration(_ timeout: TimeInterval) -> Duration? {
        guard timeout.isFinite,
              timeout >= 0,
              timeout <= TimeInterval(Int64.max)
        else {
            return nil
        }
        return .seconds(timeout)
    }

    fileprivate static var isSupportedOnCurrentPlatform: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

public enum ClaudeWebFetchStrategyError: LocalizedError, Equatable, Sendable {
    case invalidTimeout
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "Claude web usage fetch timeout must be a finite, nonnegative value within the supported range."
        case let .timedOut(seconds):
            "Claude web usage fetch timed out after \(seconds.formatted()) seconds."
        }
    }
}

struct ClaudeCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "claude.cli"
    let kind: ProviderFetchKind = .cli
    let useWebExtras: Bool
    let manualCookieHeader: String?
    let browserDetection: BrowserDetection
    let hasWebFallback: Bool

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // The interactive Claude REPL can open browser OAuth when it starts logged out. Background Auto refreshes
        // must establish CLI authentication through the non-interactive status command before starting that REPL.
        guard context.runtime == .app,
              context.sourceMode == .auto,
              ProviderInteractionContext.current == .background
        else {
            return true
        }
        guard let binary = ClaudeCLIResolver.resolvedBinaryPath(environment: context.env) else { return false }
        return await ClaudeCLIAuthStatusProbe.isLoggedIn(binary: binary, environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let keepAlive = context.settings?.debugKeepCLISessionsAlive ?? false
        let fetcher = ClaudeUsageFetcher(
            browserDetection: browserDetection,
            environment: context.env,
            dataSource: .cli,
            useWebExtras: self.useWebExtras,
            manualCookieHeader: self.manualCookieHeader,
            webOrganizationID: context.settings?.claude?.organizationID,
            keepCLISessionsAlive: keepAlive)
        let usage = try await fetcher.loadLatestUsage(model: "sonnet")
        return self.makeResult(
            usage: ClaudeOAuthFetchStrategy.snapshot(from: usage),
            sourceLabel: "claude")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.runtime == .app, context.sourceMode == .auto else { return false }
        guard !ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(error.localizedDescription) else {
            return false
        }
        // Reuse the bounded planning result instead of repeating browser/Keychain work after CLI failure.
        return self.hasWebFallback
    }
}
