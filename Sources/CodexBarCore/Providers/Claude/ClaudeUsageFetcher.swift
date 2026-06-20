import Foundation

public protocol ClaudeUsageFetching: Sendable {
    func loadLatestUsage(model: String) async throws -> ClaudeUsageSnapshot
    func debugRawProbe(model: String) async -> String
    func detectVersion() -> String?
}

public struct ClaudeUsageSnapshot: Sendable {
    public enum PrimaryWindowKind: Equatable, Sendable {
        case usage
        case spendLimit
    }

    public let primary: RateWindow
    public let primaryWindowKind: PrimaryWindowKind
    public let secondary: RateWindow?
    public let opus: RateWindow?
    public let extraRateWindows: [NamedRateWindow]
    public let providerCost: ProviderCostSnapshot?
    public let updatedAt: Date
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let rawText: String?

    public init(
        primary: RateWindow,
        primaryWindowKind: PrimaryWindowKind = .usage,
        secondary: RateWindow?,
        opus: RateWindow?,
        extraRateWindows: [NamedRateWindow] = [],
        providerCost: ProviderCostSnapshot? = nil,
        updatedAt: Date,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?,
        rawText: String?)
    {
        self.primary = primary
        self.primaryWindowKind = primaryWindowKind
        self.secondary = secondary
        self.opus = opus
        self.extraRateWindows = extraRateWindows
        self.providerCost = providerCost
        self.updatedAt = updatedAt
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
        self.rawText = rawText
    }
}

public enum ClaudeUsageError: LocalizedError, Sendable {
    case claudeNotInstalled
    case parseFailed(String)
    case oauthFailed(String)

    public var errorDescription: String? {
        switch self {
        case .claudeNotInstalled:
            "Claude CLI is not installed. Install it from https://code.claude.com/docs/en/overview."
        case let .parseFailed(details):
            "Could not parse Claude usage: \(details)"
        case let .oauthFailed(details):
            details
        }
    }
}

public struct ClaudeUsageFetcher: ClaudeUsageFetching, Sendable {
    private static let sessionWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60
    private static let cliAutoProbeTimeout: TimeInterval = 12
    private static let cliProbeTimeout: TimeInterval = 24
    private static let cliRetryProbeTimeout: TimeInterval = 60
    private struct Configuration {
        let environment: [String: String]
        let runtime: ProviderRuntime
        let dataSource: ClaudeUsageDataSource
        let oauthKeychainPromptCooldownEnabled: Bool
        let allowBackgroundDelegatedRefresh: Bool
        let allowStartupBootstrapPrompt: Bool
        let useWebExtras: Bool
        let manualCookieHeader: String?
        let webOrganizationID: String?
        let keepCLISessionsAlive: Bool
        let browserDetection: BrowserDetection
    }

    private let configuration: Configuration
    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static var isClaudeOAuthFlowDebugEnabled: Bool {
        ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_CLAUDE_OAUTH_FLOW"] == "1"
    }

    private var environment: [String: String] {
        self.configuration.environment
    }

    private var runtime: ProviderRuntime {
        self.configuration.runtime
    }

    private var dataSource: ClaudeUsageDataSource {
        self.configuration.dataSource
    }

    private var oauthKeychainPromptCooldownEnabled: Bool {
        self.configuration.oauthKeychainPromptCooldownEnabled
    }

    private var allowBackgroundDelegatedRefresh: Bool {
        self.configuration.allowBackgroundDelegatedRefresh
    }

    private var allowStartupBootstrapPrompt: Bool {
        self.configuration.allowStartupBootstrapPrompt
    }

    private var useWebExtras: Bool {
        self.configuration.useWebExtras
    }

    private var manualCookieHeader: String? {
        self.configuration.manualCookieHeader
    }

    private var webOrganizationID: String? {
        self.configuration.webOrganizationID
    }

    private var keepCLISessionsAlive: Bool {
        self.configuration.keepCLISessionsAlive
    }

    private var browserDetection: BrowserDetection {
        self.configuration.browserDetection
    }

    private struct ClaudeOAuthKeychainPromptPolicy {
        let mode: ClaudeOAuthKeychainPromptMode
        let isApplicable: Bool
        let interaction: ProviderInteraction

        var canPromptNow: Bool {
            switch self.mode {
            case .never:
                false
            case .onlyOnUserAction:
                self.interaction == .userInitiated
            case .always:
                true
            }
        }

        /// Respect the Keychain prompt cooldown for background operations to avoid spamming system dialogs.
        /// User actions (menu open / refresh / settings) are allowed to bypass the cooldown.
        var shouldRespectKeychainPromptCooldown: Bool {
            self.interaction != .userInitiated
        }

        var interactionLabel: String {
            self.interaction == .userInitiated ? "user" : "background"
        }
    }

    private static func currentClaudeOAuthInteractivePromptPolicy() -> ClaudeOAuthKeychainPromptPolicy {
        let policy = ClaudeOAuthKeychainPromptPolicy(
            mode: ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode(),
            isApplicable: true,
            interaction: ProviderInteractionContext.current)

        // User actions should be able to immediately retry a Security.framework fallback repair after a background
        // cooldown was recorded, even when /usr/bin/security is the primary reader.
        if policy.interaction == .userInitiated {
            if ClaudeOAuthKeychainAccessGate.clearDenied() {
                Self.log.info("Claude OAuth keychain cooldown cleared by user action")
            }
        }
        return policy
    }

    private static func currentClaudeOAuthDelegatedRefreshPolicy() -> ClaudeOAuthKeychainPromptPolicy {
        ClaudeOAuthKeychainPromptPolicy(
            mode: ClaudeOAuthKeychainPromptPreference.current(),
            isApplicable: ClaudeOAuthKeychainPromptPreference.isApplicable(),
            interaction: ProviderInteractionContext.current)
    }

    private static func assertDelegatedRefreshAllowedInCurrentInteraction(
        policy: ClaudeOAuthKeychainPromptPolicy,
        allowBackgroundDelegatedRefresh: Bool) throws
    {
        guard policy.isApplicable else { return }
        if policy.mode == .never {
            throw ClaudeUsageError.oauthFailed("Delegated refresh is disabled by 'never' keychain policy.")
        }
        if policy.mode == .onlyOnUserAction,
           policy.interaction != .userInitiated,
           !allowBackgroundDelegatedRefresh
        {
            throw ClaudeUsageError.oauthFailed(
                "Claude OAuth token expired, but background repair is suppressed when Keychain prompt policy "
                    + "is set to only prompt on user action. Open the CodexBar menu or click Refresh to retry.")
        }
    }

    #if DEBUG
    @TaskLocal static var loadOAuthCredentialsOverride: (@Sendable (
        [String: String],
        Bool,
        Bool) async throws -> ClaudeOAuthCredentials)?
    @TaskLocal static var fetchOAuthUsageOverride: (@Sendable (String) async throws -> OAuthUsageResponse)?
    @TaskLocal static var delegatedRefreshAttemptOverride: (@Sendable (
        Date,
        TimeInterval,
        [String: String]) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)?
    @TaskLocal static var hasCachedCredentialsOverride: Bool?
    #endif

    /// Creates a new ClaudeUsageFetcher.
    /// - Parameters:
    ///   - environment: Process environment (default: current process environment)
    ///   - dataSource: Usage data source (default: OAuth API).
    ///   - useWebExtras: If true, attempts to enrich usage with Claude web data (cookies).
    public init(
        browserDetection: BrowserDetection,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runtime: ProviderRuntime = .app,
        dataSource: ClaudeUsageDataSource = .oauth,
        oauthKeychainPromptCooldownEnabled: Bool = false,
        allowBackgroundDelegatedRefresh: Bool = false,
        allowStartupBootstrapPrompt: Bool = false,
        useWebExtras: Bool = false,
        manualCookieHeader: String? = nil,
        webOrganizationID: String? = nil,
        keepCLISessionsAlive: Bool = false)
    {
        self.configuration = Configuration(
            environment: environment,
            runtime: runtime,
            dataSource: dataSource,
            oauthKeychainPromptCooldownEnabled: oauthKeychainPromptCooldownEnabled,
            allowBackgroundDelegatedRefresh: allowBackgroundDelegatedRefresh,
            allowStartupBootstrapPrompt: allowStartupBootstrapPrompt,
            useWebExtras: useWebExtras,
            manualCookieHeader: manualCookieHeader,
            webOrganizationID: webOrganizationID,
            keepCLISessionsAlive: keepCLISessionsAlive,
            browserDetection: browserDetection)
    }

    private struct OAuthExecutor {
        let fetcher: ClaudeUsageFetcher

        func load(allowDelegatedRetry: Bool) async throws -> ClaudeUsageSnapshot {
            do {
                let promptPolicy = ClaudeUsageFetcher.currentClaudeOAuthInteractivePromptPolicy()

                #if DEBUG
                let hasCache = if let hasCachedCredentialsOverride = ClaudeUsageFetcher.hasCachedCredentialsOverride {
                    hasCachedCredentialsOverride
                } else if ClaudeUsageFetcher.loadOAuthCredentialsOverride != nil {
                    false
                } else {
                    ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: self.fetcher.environment)
                }
                #else
                let hasCache = ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: self.fetcher.environment)
                #endif

                let startupBootstrapOverride = self.shouldAllowStartupBootstrapPrompt(
                    policy: promptPolicy,
                    hasCache: hasCache)
                let allowKeychainPrompt = (promptPolicy.canPromptNow || startupBootstrapOverride) && !hasCache
                ClaudeUsageFetcher.logOAuthBootstrapPromptDecision(
                    allowKeychainPrompt: allowKeychainPrompt,
                    policy: promptPolicy,
                    hasCache: hasCache,
                    startupBootstrapOverride: startupBootstrapOverride)

                let credentials = try await ClaudeOAuthCredentialsStore.$allowBackgroundPromptBootstrap
                    .withValue(startupBootstrapOverride) {
                        try await ClaudeUsageFetcher.loadOAuthCredentials(
                            environment: self.fetcher.environment,
                            allowKeychainPrompt: allowKeychainPrompt,
                            respectKeychainPromptCooldown: promptPolicy.shouldRespectKeychainPromptCooldown)
                    }

                try self.validateRequiredOAuthScope(credentials)
                let usage = try await ClaudeUsageFetcher.fetchOAuthUsage(accessToken: credentials.accessToken)
                return try ClaudeUsageFetcher.mapOAuthUsage(usage, credentials: credentials)
            } catch let error as CancellationError {
                throw error
            } catch let error as ClaudeUsageError {
                throw error
            } catch let error as ClaudeOAuthCredentialsError {
                if case .refreshDelegatedToClaudeCLI = error {
                    return try await self.loadAfterDelegatedRefresh(allowDelegatedRetry: allowDelegatedRetry)
                }
                throw ClaudeUsageError.oauthFailed(error.localizedDescription)
            } catch let error as ClaudeOAuthFetchError {
                if case .rateLimited = error {
                    throw ClaudeUsageError.oauthFailed(error.localizedDescription)
                }
                ClaudeOAuthCredentialsStore.invalidateCache()
                if case let .serverError(statusCode, body) = error,
                   statusCode == 403,
                   body?.contains("user:profile") ?? false
                {
                    throw ClaudeUsageError.oauthFailed(
                        "Claude OAuth token does not meet scope requirement 'user:profile'. "
                            + "Run `claude setup-token` to re-generate credentials, or switch Claude Source to "
                            + "Web/CLI.")
                }
                throw ClaudeUsageError.oauthFailed(error.localizedDescription)
            } catch {
                throw ClaudeUsageError.oauthFailed(error.localizedDescription)
            }
        }

        private func shouldAllowStartupBootstrapPrompt(
            policy: ClaudeOAuthKeychainPromptPolicy,
            hasCache: Bool) -> Bool
        {
            guard self.fetcher.allowStartupBootstrapPrompt else { return false }
            guard !hasCache else { return false }
            guard ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode() == .onlyOnUserAction else {
                return false
            }
            guard policy.interaction == .background else { return false }
            return ProviderRefreshContext.current == .startup
        }

        private func loadAfterDelegatedRefresh(allowDelegatedRetry: Bool) async throws -> ClaudeUsageSnapshot {
            guard allowDelegatedRetry else {
                throw ClaudeUsageError.oauthFailed(
                    "Claude OAuth token expired and delegated Claude CLI refresh did not recover. "
                        + "Run `claude login`, then retry.")
            }

            try Task.checkCancellation()

            let delegatedPromptPolicy = ClaudeUsageFetcher.currentClaudeOAuthDelegatedRefreshPolicy()
            try ClaudeUsageFetcher.assertDelegatedRefreshAllowedInCurrentInteraction(
                policy: delegatedPromptPolicy,
                allowBackgroundDelegatedRefresh: self.fetcher.allowBackgroundDelegatedRefresh)

            let delegatedOutcome = await ClaudeUsageFetcher.attemptDelegatedRefresh(
                environment: self.fetcher.environment)
            ClaudeUsageFetcher.log.info(
                "Claude OAuth delegated refresh attempted",
                metadata: [
                    "outcome": ClaudeUsageFetcher.delegatedRefreshOutcomeLabel(delegatedOutcome),
                ])

            do {
                if self.fetcher.oauthKeychainPromptCooldownEnabled {
                    switch delegatedOutcome {
                    case .skippedByCooldown, .cliUnavailable:
                        throw ClaudeUsageError.oauthFailed(
                            "Claude OAuth token expired; delegated refresh is unavailable (outcome="
                                + "\(ClaudeUsageFetcher.delegatedRefreshOutcomeLabel(delegatedOutcome))).")
                    case .attemptedSucceeded, .attemptedFailed:
                        break
                    }
                }

                try Task.checkCancellation()

                _ = ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()

                let didSyncSilently = delegatedOutcome == .attemptedSucceeded
                    && ClaudeOAuthCredentialsStore.syncFromClaudeKeychainWithoutPrompt(now: Date())

                let promptPolicy = ClaudeUsageFetcher.currentClaudeOAuthInteractivePromptPolicy()
                ClaudeUsageFetcher.logDeferredBackgroundDelegatedRecoveryIfNeeded(
                    delegatedOutcome: delegatedOutcome,
                    didSyncSilently: didSyncSilently,
                    policy: promptPolicy)
                let retryAllowKeychainPrompt = promptPolicy.canPromptNow && !didSyncSilently
                if retryAllowKeychainPrompt {
                    ClaudeUsageFetcher.log.info(
                        "Claude OAuth keychain prompt allowed (post-delegation retry)",
                        metadata: [
                            "interaction": promptPolicy.interactionLabel,
                            "promptMode": promptPolicy.mode.rawValue,
                            "promptPolicyApplicable": "\(promptPolicy.isApplicable)",
                            "delegatedOutcome": ClaudeUsageFetcher.delegatedRefreshOutcomeLabel(delegatedOutcome),
                            "didSyncSilently": "\(didSyncSilently)",
                        ])
                }
                if ClaudeUsageFetcher.isClaudeOAuthFlowDebugEnabled {
                    ClaudeUsageFetcher.log.debug(
                        "Claude OAuth credential load (post-delegation retry start)",
                        metadata: [
                            "cooldownEnabled": "\(self.fetcher.oauthKeychainPromptCooldownEnabled)",
                            "didSyncSilently": "\(didSyncSilently)",
                            "allowKeychainPrompt": "\(retryAllowKeychainPrompt)",
                            "delegatedOutcome": ClaudeUsageFetcher.delegatedRefreshOutcomeLabel(delegatedOutcome),
                            "interaction": promptPolicy.interactionLabel,
                            "promptMode": promptPolicy.mode.rawValue,
                            "promptPolicyApplicable": "\(promptPolicy.isApplicable)",
                        ])
                }

                let refreshedCredentials = try await ClaudeUsageFetcher.loadOAuthCredentials(
                    environment: self.fetcher.environment,
                    allowKeychainPrompt: retryAllowKeychainPrompt,
                    respectKeychainPromptCooldown: promptPolicy.shouldRespectKeychainPromptCooldown)
                if ClaudeUsageFetcher.isClaudeOAuthFlowDebugEnabled {
                    ClaudeUsageFetcher.log.debug(
                        "Claude OAuth credential load (post-delegation retry)",
                        metadata: [
                            "cooldownEnabled": "\(self.fetcher.oauthKeychainPromptCooldownEnabled)",
                            "didSyncSilently": "\(didSyncSilently)",
                            "allowKeychainPrompt": "\(retryAllowKeychainPrompt)",
                            "delegatedOutcome": ClaudeUsageFetcher.delegatedRefreshOutcomeLabel(delegatedOutcome),
                            "interaction": promptPolicy.interactionLabel,
                            "promptMode": promptPolicy.mode.rawValue,
                            "promptPolicyApplicable": "\(promptPolicy.isApplicable)",
                        ])
                }

                try self.validateRequiredOAuthScope(refreshedCredentials)
                let usage = try await ClaudeUsageFetcher.fetchOAuthUsage(
                    accessToken: refreshedCredentials.accessToken)
                return try ClaudeUsageFetcher.mapOAuthUsage(usage, credentials: refreshedCredentials)
            } catch {
                ClaudeUsageFetcher.log.debug(
                    "Claude OAuth post-delegation retry failed",
                    metadata: ClaudeUsageFetcher.delegatedRetryFailureMetadata(
                        error: error,
                        oauthKeychainPromptCooldownEnabled: self.fetcher.oauthKeychainPromptCooldownEnabled,
                        delegatedOutcome: delegatedOutcome))
                throw ClaudeUsageError.oauthFailed(
                    ClaudeUsageFetcher.delegatedRefreshFailureMessage(
                        for: delegatedOutcome,
                        retryError: error))
            }
        }

        private func validateRequiredOAuthScope(_ credentials: ClaudeOAuthCredentials) throws {
            guard credentials.scopes.contains("user:profile") else {
                let scopes = credentials.scopes.joined(separator: ", ")
                let detail = scopes.isEmpty
                    ? "Claude OAuth token missing 'user:profile' scope."
                    : "Claude OAuth token missing 'user:profile' scope (has: \(scopes))."
                throw ClaudeUsageError.oauthFailed(
                    detail + " Run `claude setup-token` to re-generate credentials, or switch Claude Source to "
                        + "Web/CLI.")
            }
        }
    }

    private struct StepExecutor {
        let fetcher: ClaudeUsageFetcher

        func loadLatestUsage(model: String) async throws -> ClaudeUsageSnapshot {
            switch self.fetcher.dataSource {
            case .auto:
                return try await self.executeAuto(model: model)
            case .api:
                throw ClaudeUsageError.parseFailed("Claude Admin API usage is handled by the provider descriptor.")
            case .oauth:
                var snapshot = try await self.fetcher.loadViaOAuth(allowDelegatedRetry: true)
                snapshot = await self.fetcher.applyWebExtrasIfNeeded(to: snapshot)
                return snapshot
            case .web:
                return try await self.fetcher.loadViaWebAPI()
            case .cli:
                return try await self.loadViaCLIWithRetry(model: model)
            }
        }

        private func executeAuto(model: String) async throws -> ClaudeUsageSnapshot {
            let plan = await self.makeAutoFetchPlan()
            self.logAutoPlan(plan)

            let executionSteps = plan.executionSteps
            for (index, step) in executionSteps.enumerated() {
                do {
                    return try await self.execute(step: step, model: model)
                } catch {
                    if index < executionSteps.count - 1 {
                        ClaudeUsageFetcher.log.debug(
                            "Claude planner step failed; falling back to next step",
                            metadata: [
                                "step": step.dataSource.rawValue,
                                "reason": step.inclusionReason.rawValue,
                                "errorType": String(describing: type(of: error)),
                            ])
                        continue
                    }
                    throw error
                }
            }
            throw ClaudeUsageError.parseFailed("Claude planner produced no executable steps.")
        }

        private func makeAutoFetchPlan() async -> ClaudeFetchPlan {
            let hasWebSession =
                if let header = self.fetcher.manualCookieHeader {
                    ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: header)
                } else {
                    ClaudeWebAPIFetcher.hasSessionKey(browserDetection: self.fetcher.browserDetection)
                }
            let hasCLI = ClaudeCLIResolver.isAvailable(environment: self.fetcher.environment)
            return ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
                runtime: self.fetcher.runtime,
                selectedDataSource: .auto,
                webExtrasEnabled: self.fetcher.useWebExtras,
                hasWebSession: hasWebSession,
                hasCLI: hasCLI,
                hasOAuthCredentials: ClaudeOAuthPlanningAvailability.isAvailable(
                    runtime: self.fetcher.runtime,
                    sourceMode: .auto,
                    environment: self.fetcher.environment)))
        }

        private func logAutoPlan(_ plan: ClaudeFetchPlan) {
            var metadata: [String: String] = [
                "plannerOrder": plan.orderLabel,
                "selected": plan.preferredStep?.dataSource.rawValue ?? "none",
                "noSourceAvailable": "\(plan.isNoSourceAvailable)",
                "webExtrasEnabled": "\(self.fetcher.useWebExtras)",
                "oauthReadStrategy": ClaudeOAuthKeychainReadStrategyPreference.current().rawValue,
            ]
            for (index, step) in plan.orderedSteps.enumerated() {
                metadata["step\(index)"] =
                    "\(step.dataSource.rawValue):\(step.inclusionReason.rawValue):\(step.isPlausiblyAvailable)"
            }
            ClaudeUsageFetcher.log.debug("Claude auto source planner", metadata: metadata)
        }

        private func execute(step: ClaudeFetchPlanStep, model: String) async throws -> ClaudeUsageSnapshot {
            switch step.dataSource {
            case .api:
                throw ClaudeUsageError.parseFailed("Planner emitted invalid api execution step.")
            case .oauth:
                var snapshot = try await self.fetcher.loadViaOAuth(allowDelegatedRetry: true)
                snapshot = await self.fetcher.applyWebExtrasIfNeeded(to: snapshot)
                return snapshot
            case .web:
                return try await self.fetcher.loadViaWebAPI()
            case .cli:
                return try await self.loadViaAutoCLI(model: model)
            case .auto:
                throw ClaudeUsageError.parseFailed("Planner emitted invalid auto execution step.")
            }
        }

        private func loadViaAutoCLI(model: String) async throws -> ClaudeUsageSnapshot {
            do {
                return try await self.loadViaCLI(model: model, timeout: ClaudeUsageFetcher.cliAutoProbeTimeout)
            } catch {
                if error is CancellationError { throw error }
                guard Self.shouldRetryCLIProbe(after: error) else { throw error }
                return try await self.loadViaCLI(model: model, timeout: ClaudeUsageFetcher.cliRetryProbeTimeout)
            }
        }

        private func loadViaCLIWithRetry(model: String) async throws -> ClaudeUsageSnapshot {
            do {
                return try await self.loadViaCLI(model: model, timeout: ClaudeUsageFetcher.cliProbeTimeout)
            } catch {
                if error is CancellationError { throw error }
                guard Self.shouldRetryCLIProbe(after: error) else { throw error }
                return try await self.loadViaCLI(model: model, timeout: ClaudeUsageFetcher.cliRetryProbeTimeout)
            }
        }

        private func loadViaCLI(model: String, timeout: TimeInterval) async throws -> ClaudeUsageSnapshot {
            if ClaudeCLIRateLimitGate.blockedUntil() != nil {
                throw ClaudeUsageError.parseFailed(ClaudeCLIRateLimitGate.message)
            }

            var snapshot: ClaudeUsageSnapshot
            do {
                snapshot = try await self.fetcher.loadViaPTY(model: model, timeout: timeout)
            } catch {
                if error is CancellationError { throw error }
                if ClaudeUsageFetcher.isCLIRateLimitError(error) {
                    ClaudeCLIRateLimitGate.recordRateLimit()
                    throw error
                }
                guard Self.shouldTryDirectCLIUsage(after: error) else { throw error }
                let ptyError = error
                do {
                    snapshot = try await self.fetcher.loadViaDirectCLI(
                        timeout: Self.directCLIUsageTimeout(for: timeout))
                } catch let directError {
                    if directError is CancellationError { throw directError }
                    if ClaudeUsageFetcher.isCLIRateLimitError(directError) {
                        ClaudeCLIRateLimitGate.recordRateLimit()
                        throw directError
                    }
                    guard Self.directCLIErrorShouldReplacePTYError(directError) else { throw ptyError }
                    throw directError
                }
            }
            ClaudeCLIRateLimitGate.recordSuccess()
            snapshot = await self.fetcher.applyWebExtrasIfNeeded(to: snapshot)
            return snapshot
        }

        private static func directCLIUsageTimeout(for ptyTimeout: TimeInterval) -> TimeInterval {
            min(max(ptyTimeout / 3, 6), 8)
        }

        private static func directCLIErrorShouldReplacePTYError(_ error: Error) -> Bool {
            if case let ClaudeStatusProbeError.parseFailed(message) = error {
                return message.lowercased().contains("subscription")
            }
            if case let ClaudeUsageError.parseFailed(message) = error {
                return message.lowercased().contains("subscription")
            }
            return false
        }

        private static func shouldTryDirectCLIUsage(after error: Error) -> Bool {
            if case ClaudeStatusProbeError.timedOut = error { return true }
            if case let ClaudeStatusProbeError.parseFailed(message) = error {
                let lower = message.lowercased()
                return lower.contains("still loading usage") || lower.contains("could not load usage data")
            }
            let message = error.localizedDescription.lowercased()
            return message.contains("timed out") || message.contains("timeout")
        }

        private static func shouldRetryCLIProbe(after error: Error) -> Bool {
            if case ClaudeStatusProbeError.timedOut = error { return true }
            if case let ClaudeStatusProbeError.parseFailed(message) = error {
                return message.lowercased().contains("still loading usage")
            }
            let message = error.localizedDescription.lowercased()
            return message.contains("timed out") || message.contains("timeout")
        }
    }
}

extension ClaudeUsageFetcher {
    // MARK: - Parsing helpers

    public static func parse(json: Data) -> ClaudeUsageSnapshot? {
        guard let output = String(data: json, encoding: .utf8) else { return nil }
        return try? Self.parse(output: output)
    }

    private static func parse(output: String) throws -> ClaudeUsageSnapshot {
        guard
            let data = output.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClaudeUsageError.parseFailed(output.prefix(500).description)
        }

        if let ok = obj["ok"] as? Bool, !ok {
            let hint = obj["hint"] as? String ?? (obj["pane_preview"] as? String ?? "")
            throw ClaudeUsageError.parseFailed(hint)
        }

        func firstWindowDict(_ keys: [String]) -> [String: Any]? {
            for key in keys {
                if let dict = obj[key] as? [String: Any] { return dict }
            }
            return nil
        }

        func makeWindow(_ dict: [String: Any]?, windowMinutes: Int) -> RateWindow? {
            guard let dict else { return nil }
            let pct = (dict["pct_used"] as? NSNumber)?.doubleValue ?? 0
            let resetText = dict["resets"] as? String
            return RateWindow(
                usedPercent: pct,
                windowMinutes: windowMinutes,
                resetsAt: Self.parseReset(text: resetText),
                resetDescription: resetText)
        }

        guard let session = makeWindow(
            firstWindowDict(["session_5h"]),
            windowMinutes: Self.sessionWindowMinutes)
        else {
            throw ClaudeUsageError.parseFailed("missing session data")
        }
        let weekAll = makeWindow(
            firstWindowDict(["week_all_models", "week_all"]),
            windowMinutes: Self.weeklyWindowMinutes)

        let rawEmail = (obj["account_email"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let email = (rawEmail?.isEmpty ?? true) ? nil : rawEmail
        let rawOrg = (obj["account_org"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let org = (rawOrg?.isEmpty ?? true) ? nil : rawOrg
        let loginMethod = (obj["login_method"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let opusWindow: RateWindow? = {
            let candidates = firstWindowDict([
                "week_sonnet",
                "week_sonnet_only",
                "week_opus",
            ])
            guard let opus = candidates else { return nil }
            let pct = (opus["pct_used"] as? NSNumber)?.doubleValue ?? 0
            let resets = opus["resets"] as? String
            return RateWindow(
                usedPercent: pct,
                windowMinutes: Self.weeklyWindowMinutes,
                resetsAt: Self.parseReset(text: resets),
                resetDescription: resets)
        }()
        return ClaudeUsageSnapshot(
            primary: session,
            secondary: weekAll,
            opus: opusWindow,
            providerCost: nil,
            updatedAt: Date(),
            accountEmail: email,
            accountOrganization: org,
            loginMethod: loginMethod,
            rawText: output)
    }

    private static func parseReset(text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: "(")
        let timePart = parts.first?.trimmingCharacters(in: .whitespaces)
        let tzPart =
            parts.count > 1
                ? parts[1].replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
                : nil
        let tz = tzPart.flatMap(TimeZone.init(identifier:))
        let formats = ["ha", "h:mma", "MMM d 'at' ha", "MMM d 'at' h:mma"]
        for format in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = tz ?? TimeZone.current
            df.dateFormat = format
            if let t = timePart, let date = df.date(from: t) { return date }
        }
        return nil
    }

    // MARK: - Public API

    public func detectVersion() -> String? {
        ProviderVersionDetector.claudeVersion()
    }

    public func debugRawProbe(model: String = "sonnet") async -> String {
        do {
            let snap = try await self.loadViaPTY(model: model, timeout: Self.cliProbeTimeout)
            let opus = snap.opus?.remainingPercent ?? -1
            let email = snap.accountEmail ?? "nil"
            let org = snap.accountOrganization ?? "nil"
            let weekly = snap.secondary?.remainingPercent ?? -1
            let primary = snap.primary.remainingPercent
            return """
            session_left=\(primary) weekly_left=\(weekly)
            opus_left=\(opus) email \(email) org \(org)
            \(snap)
            """
        } catch {
            return "Probe failed: \(error)"
        }
    }

    public func loadLatestUsage(model: String = "sonnet") async throws -> ClaudeUsageSnapshot {
        try await StepExecutor(fetcher: self).loadLatestUsage(model: model)
    }

    public static func isCLIRateLimitError(_ error: Error) -> Bool {
        ClaudeCLIRateLimitGate.isRateLimitError(error)
    }
}

extension ClaudeUsageFetcher {
    // MARK: - OAuth API path

    private static func logOAuthBootstrapPromptDecision(
        allowKeychainPrompt: Bool,
        policy: ClaudeOAuthKeychainPromptPolicy,
        hasCache: Bool,
        startupBootstrapOverride: Bool)
    {
        guard allowKeychainPrompt else { return }
        self.log.info(
            "Claude OAuth keychain prompt allowed (bootstrap)",
            metadata: [
                "interaction": policy.interactionLabel,
                "promptMode": policy.mode.rawValue,
                "promptPolicyApplicable": "\(policy.isApplicable)",
                "hasCache": "\(hasCache)",
                "startupBootstrapOverride": "\(startupBootstrapOverride)",
            ])
    }

    private static func logDeferredBackgroundDelegatedRecoveryIfNeeded(
        delegatedOutcome: ClaudeOAuthDelegatedRefreshCoordinator.Outcome,
        didSyncSilently: Bool,
        policy: ClaudeOAuthKeychainPromptPolicy)
    {
        guard delegatedOutcome == .attemptedSucceeded else { return }
        guard !didSyncSilently else { return }
        guard policy.mode == .onlyOnUserAction else { return }
        guard policy.interaction == .background else { return }
        self.log.info(
            "Claude OAuth delegated refresh completed; background recovery deferred until user action",
            metadata: [
                "interaction": policy.interactionLabel,
                "promptMode": policy.mode.rawValue,
                "delegatedOutcome": self.delegatedRefreshOutcomeLabel(delegatedOutcome),
            ])
    }

    private func loadViaOAuth(allowDelegatedRetry: Bool) async throws -> ClaudeUsageSnapshot {
        try await OAuthExecutor(fetcher: self).load(allowDelegatedRetry: allowDelegatedRetry)
    }

    private static func loadOAuthCredentials(
        environment: [String: String],
        allowKeychainPrompt: Bool,
        respectKeychainPromptCooldown: Bool) async throws -> ClaudeOAuthCredentials
    {
        #if DEBUG
        if let override = loadOAuthCredentialsOverride {
            return try await override(environment, allowKeychainPrompt, respectKeychainPromptCooldown)
        }
        #endif
        return try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown)
    }

    private static func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        #if DEBUG
        if let override = fetchOAuthUsageOverride {
            return try await override(accessToken)
        }
        #endif
        return try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: accessToken)
    }

    private static func attemptDelegatedRefresh(
        now: Date = Date(),
        timeout: TimeInterval = 15,
        environment: [String: String] = ProcessInfo.processInfo.environment)
        async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome
    {
        #if DEBUG
        if let override = delegatedRefreshAttemptOverride {
            return await override(now, timeout, environment)
        }
        #endif
        return await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
            now: now,
            timeout: timeout,
            environment: environment)
    }

    private static func delegatedRefreshOutcomeLabel(
        _ outcome: ClaudeOAuthDelegatedRefreshCoordinator.Outcome) -> String
    {
        switch outcome {
        case .skippedByCooldown:
            "skippedByCooldown"
        case .cliUnavailable:
            "cliUnavailable"
        case .attemptedSucceeded:
            "attemptedSucceeded"
        case .attemptedFailed:
            "attemptedFailed"
        }
    }

    private static func delegatedRefreshFailureMessage(
        for outcome: ClaudeOAuthDelegatedRefreshCoordinator.Outcome,
        retryError: Error) -> String
    {
        if let oauthError = retryError as? ClaudeOAuthFetchError,
           case .rateLimited = oauthError
        {
            return oauthError.localizedDescription
        }

        switch outcome {
        case .skippedByCooldown:
            return "Claude OAuth token expired and delegated refresh is cooling down. "
                + "Please retry shortly, or run `claude login`."
        case .cliUnavailable:
            return "Claude OAuth token expired and Claude CLI is not available for delegated refresh. "
                + "Install/configure `claude`, or run `claude login`."
        case .attemptedSucceeded:
            return "Claude OAuth token is still unavailable after delegated Claude CLI refresh. "
                + "Run `claude login`, then retry."
        case let .attemptedFailed(message):
            return "Claude OAuth token expired and delegated Claude CLI refresh failed: \(message). "
                + "Run `claude login`, then retry."
        }
    }

    private static func delegatedRetryFailureMetadata(
        error: Error,
        oauthKeychainPromptCooldownEnabled: Bool,
        delegatedOutcome: ClaudeOAuthDelegatedRefreshCoordinator.Outcome) -> [String: String]
    {
        var metadata: [String: String] = [
            "errorType": String(describing: type(of: error)),
            "cooldownEnabled": "\(oauthKeychainPromptCooldownEnabled)",
            "delegatedOutcome": Self.delegatedRefreshOutcomeLabel(delegatedOutcome),
        ]

        // Avoid `localizedDescription` here: some error types include server response bodies in their
        // `errorDescription`, which can leak potentially identifying information into logs.
        if let oauthError = error as? ClaudeOAuthFetchError {
            switch oauthError {
            case .unauthorized:
                metadata["oauthError"] = "unauthorized"
            case let .rateLimited(retryAfter):
                metadata["oauthError"] = "rateLimited"
                metadata["retryAfter"] = retryAfter.map { "\($0.timeIntervalSince1970)" } ?? "nil"
            case .invalidResponse:
                metadata["oauthError"] = "invalidResponse"
            case let .serverError(statusCode, body):
                metadata["oauthError"] = "serverError"
                metadata["httpStatus"] = "\(statusCode)"
                metadata["bodyLength"] = "\(body?.utf8.count ?? 0)"
            case let .networkError(underlying):
                metadata["oauthError"] = "networkError"
                metadata["underlyingType"] = String(describing: type(of: underlying))
            }
        }

        return metadata
    }

    private static func mapOAuthUsage(
        _ usage: OAuthUsageResponse,
        credentials: ClaudeOAuthCredentials) throws -> ClaudeUsageSnapshot
    {
        func makeWindow(_ window: OAuthUsageWindow?, windowMinutes: Int?) -> RateWindow? {
            guard let window,
                  let utilization = window.utilization
            else { return nil }
            let resetDate = ClaudeOAuthUsageFetcher.parseISO8601Date(window.resetsAt)
            let resetDescription = resetDate.map(Self.formatResetDate)
            return RateWindow(
                usedPercent: utilization,
                windowMinutes: windowMinutes,
                resetsAt: resetDate,
                resetDescription: resetDescription)
        }

        let loginMethod = ClaudePlan.oauthLoginMethod(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier)
        let primary = makeWindow(usage.fiveHour, windowMinutes: 5 * 60)
            ?? makeWindow(usage.sevenDay, windowMinutes: 7 * 24 * 60)
            ?? makeWindow(usage.sevenDayOAuthApps, windowMinutes: 7 * 24 * 60)
            ?? makeWindow(usage.sevenDaySonnet, windowMinutes: 7 * 24 * 60)
            ?? makeWindow(usage.sevenDayOpus, windowMinutes: 7 * 24 * 60)
        let treatAsSpendLimit = primary == nil && usage.extraUsage?.isEnabled == true
        let providerCost = Self.oauthExtraUsageCost(
            usage.extraUsage,
            loginMethod: loginMethod,
            treatAsSpendLimit: treatAsSpendLimit)

        guard let primary else {
            if let spendLimit = Self.oauthSpendLimitWindow(from: providerCost, extraUsage: usage.extraUsage) {
                return ClaudeUsageSnapshot(
                    primary: spendLimit,
                    primaryWindowKind: .spendLimit,
                    secondary: nil,
                    opus: nil,
                    extraRateWindows: Self.oauthExtraRateWindows(from: usage),
                    providerCost: providerCost,
                    updatedAt: Date(),
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: loginMethod,
                    rawText: nil)
            }
            throw ClaudeUsageError.parseFailed("missing session data")
        }

        let weekly = makeWindow(usage.sevenDay, windowMinutes: 7 * 24 * 60)
        let modelSpecific = makeWindow(
            usage.sevenDaySonnet ?? usage.sevenDayOpus,
            windowMinutes: 7 * 24 * 60)
        let extraRateWindows = Self.oauthExtraRateWindows(from: usage)

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: weekly,
            opus: modelSpecific,
            extraRateWindows: extraRateWindows,
            providerCost: providerCost,
            updatedAt: Date(),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod,
            rawText: nil)
    }

    private static func oauthExtraUsageCost(
        _ extra: OAuthExtraUsage?,
        loginMethod: String?,
        treatAsSpendLimit: Bool = false) -> ProviderCostSnapshot?
    {
        guard let extra, extra.isEnabled == true else { return nil }
        guard let used = extra.usedCredits,
              let limit = extra.monthlyLimit
        else { return nil }
        let currency = extra.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = (currency?.isEmpty ?? true) ? "USD" : currency!
        let isSpendLimit = treatAsSpendLimit || ClaudePlan.fromCompatibilityLoginMethod(loginMethod) == .enterprise
        let normalized = Self.normalizeClaudeExtraUsageAmounts(
            used: used,
            limit: limit,
            treatAsMajorUnits: false)
        return ProviderCostSnapshot(
            used: normalized.used,
            limit: normalized.limit,
            currencyCode: code,
            period: isSpendLimit ? "Spend limit" : "Monthly cap",
            resetsAt: nil,
            updatedAt: Date())
    }

    private static func oauthSpendLimitWindow(
        from providerCost: ProviderCostSnapshot?,
        extraUsage: OAuthExtraUsage?) -> RateWindow?
    {
        guard let providerCost,
              providerCost.limit > 0
        else { return nil }
        let usedPercent = extraUsage?.utilization ?? (providerCost.used / providerCost.limit) * 100
        let used = UsageFormatter.currencyString(providerCost.used, currencyCode: providerCost.currencyCode)
        let limit = UsageFormatter.currencyString(providerCost.limit, currencyCode: providerCost.currencyCode)
        return RateWindow(
            usedPercent: min(100, max(0, usedPercent)),
            windowMinutes: nil,
            resetsAt: providerCost.resetsAt,
            resetDescription: "\(providerCost.period ?? "Spend limit"): \(used) / \(limit)")
    }

    private static func normalizeClaudeExtraUsageAmounts(
        used: Double,
        limit: Double,
        treatAsMajorUnits: Bool) -> (used: Double, limit: Double)
    {
        if treatAsMajorUnits {
            return (used: used, limit: limit)
        }

        // Claude's OAuth API returns values in cents (minor units), same as the Web API.
        // Always convert to dollars (major units) for display consistency.
        // See: ClaudeWebAPIFetcher.swift which always divides by 100.
        return (used: used / 100.0, limit: limit / 100.0)
    }

    private static func oauthExtraRateWindows(from usage: OAuthUsageResponse) -> [NamedRateWindow] {
        let definitions: [(id: String, title: String, window: OAuthUsageWindow?, sourceKey: String?)] = [
            (
                id: "claude-routines",
                title: "Daily Routines",
                window: usage.sevenDayRoutines,
                sourceKey: usage.sevenDayRoutinesSourceKey),
        ]
        if let routinesKey = usage.sevenDayRoutinesSourceKey {
            Self.log.debug("Claude OAuth extra usage key matched: routines=\(routinesKey)")
        }
        return definitions.compactMap { definition in
            let utilization: Double
            let resetDate: Date?
            if let window = definition.window, let parsedUtilization = window.utilization {
                utilization = parsedUtilization
                resetDate = ClaudeOAuthUsageFetcher.parseISO8601Date(window.resetsAt)
            } else if definition.sourceKey != nil {
                // Keep product bars visible when the API returns a known key with null payload.
                utilization = 0
                resetDate = nil
            } else {
                return nil
            }
            let resetDescription = resetDate.map(Self.formatResetDate)
            return NamedRateWindow(
                id: definition.id,
                title: definition.title,
                window: RateWindow(
                    usedPercent: utilization,
                    windowMinutes: Self.weeklyWindowMinutes,
                    resetsAt: resetDate,
                    resetDescription: resetDescription))
        }
    }

    // MARK: - Web API path (uses browser cookies)

    private func loadViaWebAPI() async throws -> ClaudeUsageSnapshot {
        let webData: ClaudeWebAPIFetcher.WebUsageData =
            if let header = self.manualCookieHeader {
                try await ClaudeWebAPIFetcher.fetchUsage(
                    cookieHeader: header,
                    targetOrganizationID: self.webOrganizationID)
                { msg in
                    Self.log.debug(msg)
                }
            } else {
                try await ClaudeWebAPIFetcher.fetchUsage(
                    browserDetection: self.browserDetection,
                    targetOrganizationID: self.webOrganizationID)
                { msg in
                    Self.log.debug(msg)
                }
            }
        // Convert web API data to ClaudeUsageSnapshot format
        let primary = RateWindow(
            usedPercent: webData.sessionPercentUsed,
            windowMinutes: 5 * 60,
            resetsAt: webData.sessionResetsAt,
            resetDescription: webData.sessionResetsAt.map { Self.formatResetDate($0) })

        let secondary: RateWindow? = webData.weeklyPercentUsed.map { pct in
            RateWindow(
                usedPercent: pct,
                windowMinutes: 7 * 24 * 60,
                resetsAt: webData.weeklyResetsAt,
                resetDescription: webData.weeklyResetsAt.map { Self.formatResetDate($0) })
        }

        let opus: RateWindow? = webData.opusPercentUsed.map { opusPct in
            RateWindow(
                usedPercent: opusPct,
                windowMinutes: 7 * 24 * 60,
                resetsAt: webData.weeklyResetsAt,
                resetDescription: webData.weeklyResetsAt.map { Self.formatResetDate($0) })
        }

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: secondary,
            opus: opus,
            extraRateWindows: webData.extraRateWindows,
            providerCost: webData.extraUsageCost,
            updatedAt: Date(),
            accountEmail: webData.accountEmail,
            accountOrganization: webData.accountOrganization,
            loginMethod: webData.loginMethod,
            rawText: nil)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: - PTY-based probe (no tmux)

    private func loadViaPTY(model: String, timeout: TimeInterval = 10) async throws -> ClaudeUsageSnapshot {
        guard let claudeBinary = ClaudeCLIResolver.resolvedBinaryPath(environment: self.environment) else {
            throw ClaudeUsageError.claudeNotInstalled
        }
        let probe = ClaudeStatusProbe(
            claudeBinary: claudeBinary,
            timeout: timeout,
            keepCLISessionsAlive: self.keepCLISessionsAlive)
        let snap = try await probe.fetch()

        return try Self.makeSnapshot(from: snap)
    }

    private func loadViaDirectCLI(timeout: TimeInterval) async throws -> ClaudeUsageSnapshot {
        guard let claudeBinary = ClaudeCLIResolver.resolvedBinaryPath(environment: self.environment) else {
            throw ClaudeUsageError.claudeNotInstalled
        }

        let workingDirectory = ClaudeStatusProbe.preparedProbeWorkingDirectoryURL()
        var environment = ClaudeCLISession.launchEnvironment(baseEnv: self.environment)
        environment["PWD"] = workingDirectory.path
        defer {
            ClaudeProbeSessionArtifactCleaner.cleanupProbeSessionArtifacts(
                probeDirectory: workingDirectory,
                environment: environment)
        }

        let result = try await SubprocessRunner.run(
            binary: claudeBinary,
            arguments: ["/usage"],
            environment: environment,
            timeout: timeout,
            standardInput: FileHandle.nullDevice,
            currentDirectoryURL: workingDirectory,
            label: "claude-direct-usage")
        let snap = try ClaudeStatusProbe.parse(text: result.stdout)
        return try Self.makeSnapshot(from: snap)
    }

    private static func makeSnapshot(from snap: ClaudeStatusSnapshot) throws -> ClaudeUsageSnapshot {
        guard let sessionPctLeft = snap.sessionPercentLeft else {
            throw ClaudeUsageError.parseFailed("missing session data")
        }

        func makeWindow(pctLeft: Int?, reset: String?, windowMinutes: Int) -> RateWindow? {
            guard let left = pctLeft else { return nil }
            let used = max(0, min(100, 100 - Double(left)))
            let resetClean = reset?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RateWindow(
                usedPercent: used,
                windowMinutes: windowMinutes,
                resetsAt: ClaudeStatusProbe.parseResetDate(from: resetClean),
                resetDescription: resetClean)
        }

        let primary = makeWindow(
            pctLeft: sessionPctLeft,
            reset: snap.primaryResetDescription,
            windowMinutes: Self.sessionWindowMinutes)!
        let weekly = makeWindow(
            pctLeft: snap.weeklyPercentLeft,
            reset: snap.secondaryResetDescription,
            windowMinutes: Self.weeklyWindowMinutes)
        let opus = makeWindow(
            pctLeft: snap.opusPercentLeft,
            reset: snap.opusResetDescription,
            windowMinutes: Self.weeklyWindowMinutes)

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: weekly,
            opus: opus,
            extraRateWindows: [],
            providerCost: nil,
            updatedAt: Date(),
            accountEmail: snap.accountEmail,
            accountOrganization: snap.accountOrganization,
            loginMethod: snap.loginMethod,
            rawText: snap.rawText)
    }

    private func applyWebExtrasIfNeeded(to snapshot: ClaudeUsageSnapshot) async -> ClaudeUsageSnapshot {
        guard self.useWebExtras, self.dataSource != .web else { return snapshot }
        do {
            let webData: ClaudeWebAPIFetcher.WebUsageData =
                if let header = self.manualCookieHeader {
                    try await ClaudeWebAPIFetcher.fetchUsage(
                        cookieHeader: header,
                        targetOrganizationID: self.webOrganizationID)
                    { msg in
                        Self.log.debug(msg)
                    }
                } else {
                    try await ClaudeWebAPIFetcher.fetchUsage(
                        browserDetection: self.browserDetection,
                        targetOrganizationID: self.webOrganizationID)
                    { msg in
                        Self.log.debug(msg)
                    }
                }
            // Only merge usage/cost extras; keep identity fields from the primary data source.
            let mergedExtraRateWindows = snapshot.extraRateWindows.isEmpty ? webData.extraRateWindows : snapshot
                .extraRateWindows
            let mergedProviderCost = snapshot.providerCost ?? webData.extraUsageCost
            if mergedProviderCost != snapshot.providerCost || mergedExtraRateWindows != snapshot.extraRateWindows {
                return ClaudeUsageSnapshot(
                    primary: snapshot.primary,
                    primaryWindowKind: snapshot.primaryWindowKind,
                    secondary: snapshot.secondary,
                    opus: snapshot.opus,
                    extraRateWindows: mergedExtraRateWindows,
                    providerCost: mergedProviderCost,
                    updatedAt: snapshot.updatedAt,
                    accountEmail: snapshot.accountEmail,
                    accountOrganization: snapshot.accountOrganization,
                    loginMethod: snapshot.loginMethod,
                    rawText: snapshot.rawText)
            }
        } catch {
            Self.log.debug("Claude web extras fetch failed: \(error.localizedDescription)")
        }
        return snapshot
    }

    // MARK: - Process helpers

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
        else { return nil }
        return path
    }

    private static func readString(cmd: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cmd)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func oauthCredentialProbeErrorLabel(_ error: Error) -> String {
        guard let oauthError = error as? ClaudeOAuthCredentialsError else {
            return String(describing: type(of: error))
        }

        return switch oauthError {
        case .decodeFailed:
            "decodeFailed"
        case .missingOAuth:
            "missingOAuth"
        case .missingAccessToken:
            "missingAccessToken"
        case .notFound:
            "notFound"
        case let .keychainError(status):
            "keychainError:\(status)"
        case .readFailed:
            "readFailed"
        case .refreshFailed:
            "refreshFailed"
        case .noRefreshToken:
            "noRefreshToken"
        case .refreshDelegatedToClaudeCLI:
            "refreshDelegatedToClaudeCLI"
        }
    }
}

#if DEBUG
extension ClaudeUsageFetcher {
    public static func _mapOAuthUsageForTesting(
        _ data: Data,
        rateLimitTier: String? = nil,
        subscriptionType: String? = nil) throws -> ClaudeUsageSnapshot
    {
        let usage = try ClaudeOAuthUsageFetcher.decodeUsageResponse(data)
        let creds = ClaudeOAuthCredentials(
            accessToken: "test",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: [],
            rateLimitTier: rateLimitTier,
            subscriptionType: subscriptionType)
        return try Self.mapOAuthUsage(usage, credentials: creds)
    }
}
#endif
