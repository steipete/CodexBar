import Foundation

public protocol ClaudeUsageFetching: Sendable {
    func loadLatestUsage(model: String) async throws -> ClaudeUsageSnapshot
    func debugRawProbe(model: String) async -> String
    func detectVersion() -> String?
}

public struct ClaudeUsageSnapshot: Sendable {
    public let primary: RateWindow
    public let secondary: RateWindow?
    public let opus: RateWindow?
    public let providerCost: ProviderCostSnapshot?
    public let updatedAt: Date
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?
    public let rawText: String?

    public init(
        primary: RateWindow,
        secondary: RateWindow?,
        opus: RateWindow?,
        providerCost: ProviderCostSnapshot? = nil,
        updatedAt: Date,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?,
        rawText: String?)
    {
        self.primary = primary
        self.secondary = secondary
        self.opus = opus
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
            "Claude CLI is not installed. Install it from https://docs.claude.ai/claude-code."
        case let .parseFailed(details):
            "Could not parse Claude usage: \(details)"
        case let .oauthFailed(details):
            details
        }
    }
}

public struct ClaudeUsageFetcher: ClaudeUsageFetching, Sendable {
    private let environment: [String: String]
    private let dataSource: ClaudeUsageDataSource
    private let oauthKeychainPromptCooldownEnabled: Bool
    private let useWebExtras: Bool
    private let manualCookieHeader: String?
    private let keepCLISessionsAlive: Bool
    private let browserDetection: BrowserDetection
    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static var isClaudeOAuthFlowDebugEnabled: Bool {
        ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_CLAUDE_OAUTH_FLOW"] == "1"
    }

    private struct ClaudeOAuthKeychainPromptPolicy: Sendable {
        let mode: ClaudeOAuthKeychainPromptMode
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

    private static func currentClaudeOAuthKeychainPromptPolicy() -> ClaudeOAuthKeychainPromptPolicy {
        let policy = ClaudeOAuthKeychainPromptPolicy(
            mode: ClaudeOAuthKeychainPromptPreference.current(),
            interaction: ProviderInteractionContext.current)

        // User actions should be able to immediately retry a repair after a background cooldown was recorded.
        if policy.interaction == .userInitiated {
            if ClaudeOAuthKeychainAccessGate.clearDenied() {
                Self.log.info("Claude OAuth keychain cooldown cleared by user action")
            }
        }
        return policy
    }

    #if DEBUG
    @TaskLocal static var loadOAuthCredentialsOverride: (@Sendable (
        [String: String],
        Bool,
        Bool) async throws -> ClaudeOAuthCredentials)?
    @TaskLocal static var fetchOAuthUsageOverride: (@Sendable (String) async throws -> OAuthUsageResponse)?
    @TaskLocal static var delegatedRefreshAttemptOverride: (@Sendable (
        Date,
        TimeInterval) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome)?
    #endif

    /// Creates a new ClaudeUsageFetcher.
    /// - Parameters:
    ///   - environment: Process environment (default: current process environment)
    ///   - dataSource: Usage data source (default: OAuth API).
    ///   - useWebExtras: If true, attempts to enrich usage with Claude web data (cookies).
    public init(
        browserDetection: BrowserDetection,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        dataSource: ClaudeUsageDataSource = .oauth,
        oauthKeychainPromptCooldownEnabled: Bool = false,
        useWebExtras: Bool = false,
        manualCookieHeader: String? = nil,
        keepCLISessionsAlive: Bool = false)
    {
        self.browserDetection = browserDetection
        self.environment = environment
        self.dataSource = dataSource
        self.oauthKeychainPromptCooldownEnabled = oauthKeychainPromptCooldownEnabled
        self.useWebExtras = useWebExtras
        self.manualCookieHeader = manualCookieHeader
        self.keepCLISessionsAlive = keepCLISessionsAlive
    }

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

        func makeWindow(_ dict: [String: Any]?) -> RateWindow? {
            guard let dict else { return nil }
            let pct = (dict["pct_used"] as? NSNumber)?.doubleValue ?? 0
            let resetText = dict["resets"] as? String
            return RateWindow(
                usedPercent: pct,
                windowMinutes: nil,
                resetsAt: Self.parseReset(text: resetText),
                resetDescription: resetText)
        }

        guard let session = makeWindow(firstWindowDict(["session_5h"])) else {
            throw ClaudeUsageError.parseFailed("missing session data")
        }
        let weekAll = makeWindow(firstWindowDict(["week_all_models", "week_all"]))

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
                windowMinutes: nil,
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
        // Avoid leaking terminal control sequences (some `claude` builds write to /dev/tty even when stdout is piped).
        guard TTYCommandRunner.which("claude") != nil else { return nil }
        do {
            let out = try TTYCommandRunner().run(
                binary: "claude",
                send: "",
                options: TTYCommandRunner.Options(
                    timeout: 5.0,
                    extraArgs: ["--allowed-tools", "", "--version"],
                    initialDelay: 0.0)).text
            return TextParsing.stripANSICodes(out).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    public func debugRawProbe(model: String = "sonnet") async -> String {
        do {
            let snap = try await self.loadViaPTY(model: model, timeout: 10)
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
        switch self.dataSource {
        case .auto:
            let oauthCreds = try? ClaudeOAuthCredentialsStore.load(
                environment: self.environment,
                allowKeychainPrompt: false,
                respectKeychainPromptCooldown: true)
            let hasOAuthCredentials = oauthCreds?.scopes.contains("user:profile") ?? false
            let hasWebSession =
                if let header = self.manualCookieHeader {
                    ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: header)
                } else {
                    ClaudeWebAPIFetcher.hasSessionKey(browserDetection: self.browserDetection)
                }
            let hasCLI = TTYCommandRunner.which("claude") != nil
            if hasOAuthCredentials {
                var snap = try await self.loadViaOAuth(allowDelegatedRetry: true)
                snap = await self.applyWebExtrasIfNeeded(to: snap)
                return snap
            }
            if hasWebSession {
                return try await self.loadViaWebAPI()
            }
            if hasCLI {
                do {
                    var snap = try await self.loadViaPTY(model: model, timeout: 10)
                    snap = await self.applyWebExtrasIfNeeded(to: snap)
                    return snap
                } catch {
                    // CLI failed; OAuth is the last resort.
                }
            }
            var snap = try await self.loadViaOAuth(allowDelegatedRetry: true)
            snap = await self.applyWebExtrasIfNeeded(to: snap)
            return snap
        case .oauth:
            var snap = try await self.loadViaOAuth(allowDelegatedRetry: true)
            snap = await self.applyWebExtrasIfNeeded(to: snap)
            return snap
        case .web:
            return try await self.loadViaWebAPI()
        case .cli:
            do {
                var snap = try await self.loadViaPTY(model: model, timeout: 10)
                snap = await self.applyWebExtrasIfNeeded(to: snap)
                return snap
            } catch {
                var snap = try await self.loadViaPTY(model: model, timeout: 24)
                snap = await self.applyWebExtrasIfNeeded(to: snap)
                return snap
            }
        }
    }

    // MARK: - OAuth API path

    private func loadViaOAuth(allowDelegatedRetry: Bool) async throws -> ClaudeUsageSnapshot {
        do {
            let promptPolicy = Self.currentClaudeOAuthKeychainPromptPolicy()

            // Allow keychain prompt when no cached credentials exist (bootstrap case)
            let hasCache = ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: self.environment)
            // Note: `hasCachedCredentials` intentionally returns true for expired Claude-CLI-owned creds, because the
            // repair path is delegated refresh via Claude CLI (followed by a silent re-sync) rather than immediately
            // prompting on the initial load.
            let allowKeychainPrompt = promptPolicy.canPromptNow && !hasCache
            if allowKeychainPrompt {
                Self.log.info(
                    "Claude OAuth keychain prompt allowed (bootstrap)",
                    metadata: [
                        "interaction": promptPolicy.interactionLabel,
                        "promptMode": promptPolicy.mode.rawValue,
                        "hasCache": "\(hasCache)",
                    ])
            }
            // Ownership-aware credential loading:
            // - Claude CLI-owned credentials delegate refresh to Claude CLI.
            // - CodexBar-owned credentials use direct token-endpoint refresh.
            let creds = try await Self.loadOAuthCredentials(
                environment: self.environment,
                allowKeychainPrompt: allowKeychainPrompt,
                respectKeychainPromptCooldown: promptPolicy.shouldRespectKeychainPromptCooldown)
            // The usage endpoint requires user:profile scope.
            if !creds.scopes.contains("user:profile") {
                throw ClaudeUsageError.oauthFailed(
                    "Claude OAuth token missing 'user:profile' scope (has: \(creds.scopes.joined(separator: ", "))). "
                        + "Run `claude setup-token` to re-generate credentials, or switch Claude Source to Web/CLI.")
            }
            let usage = try await Self.fetchOAuthUsage(accessToken: creds.accessToken)
            return try Self.mapOAuthUsage(usage, credentials: creds)
        } catch let error as CancellationError {
            throw error
        } catch let error as ClaudeUsageError {
            throw error
        } catch let error as ClaudeOAuthCredentialsError {
            if case .refreshDelegatedToClaudeCLI = error {
                guard allowDelegatedRetry else {
                    throw ClaudeUsageError.oauthFailed(
                        "Claude OAuth token expired and delegated Claude CLI refresh did not recover. "
                            + "Run `claude login`, then retry.")
                }

                try Task.checkCancellation()

                let delegatedOutcome = await Self.attemptDelegatedRefresh()
                Self.log.info(
                    "Claude OAuth delegated refresh attempted",
                    metadata: [
                        "outcome": Self.delegatedRefreshOutcomeLabel(delegatedOutcome),
                    ])

                do {
                    // In Auto mode, avoid forcing interactive Keychain prompts or blocking the fallback chain when
                    // delegation cannot run.
                    if self.oauthKeychainPromptCooldownEnabled {
                        switch delegatedOutcome {
                        case .skippedByCooldown, .cliUnavailable:
                            throw ClaudeUsageError.oauthFailed(
                                "Claude OAuth token expired; delegated refresh is unavailable (outcome="
                                    + "\(Self.delegatedRefreshOutcomeLabel(delegatedOutcome))).")
                        case .attemptedSucceeded:
                            break
                        case .attemptedFailed:
                            // Delegation ran but didn't observe a keychain change. We'll attempt a non-interactive
                            // reload below (allowKeychainPrompt=false) and then allow the Auto chain to fall back.
                            break
                        }
                    }

                    try Task.checkCancellation()

                    // After delegated refresh, reload credentials and retry OAuth once.
                    // In OAuth mode we allow an interactive Keychain prompt here; in Auto mode we keep it silent to
                    // avoid bypassing the prompt cooldown and to let the fallback chain proceed.
                    _ = ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()

                    let didSyncSilently: Bool = {
                        guard delegatedOutcome == .attemptedSucceeded else { return false }
                        return ClaudeOAuthCredentialsStore.syncFromClaudeKeychainWithoutPrompt(now: Date())
                    }()

                    let promptPolicy = Self.currentClaudeOAuthKeychainPromptPolicy()
                    let retryAllowKeychainPrompt = promptPolicy.canPromptNow && !didSyncSilently
                    if retryAllowKeychainPrompt {
                        Self.log.info(
                            "Claude OAuth keychain prompt allowed (post-delegation retry)",
                            metadata: [
                                "interaction": promptPolicy.interactionLabel,
                                "promptMode": promptPolicy.mode.rawValue,
                                "delegatedOutcome": Self.delegatedRefreshOutcomeLabel(delegatedOutcome),
                                "didSyncSilently": "\(didSyncSilently)",
                            ])
                    }
                    if Self.isClaudeOAuthFlowDebugEnabled {
                        Self.log.debug(
                            "Claude OAuth credential load (post-delegation retry start)",
                            metadata: [
                                "cooldownEnabled": "\(self.oauthKeychainPromptCooldownEnabled)",
                                "didSyncSilently": "\(didSyncSilently)",
                                "allowKeychainPrompt": "\(retryAllowKeychainPrompt)",
                                "delegatedOutcome": Self.delegatedRefreshOutcomeLabel(delegatedOutcome),
                                "interaction": promptPolicy.interactionLabel,
                                "promptMode": promptPolicy.mode.rawValue,
                            ])
                    }
                    let refreshedCreds = try await Self.loadOAuthCredentials(
                        environment: self.environment,
                        allowKeychainPrompt: retryAllowKeychainPrompt,
                        respectKeychainPromptCooldown: promptPolicy.shouldRespectKeychainPromptCooldown)
                    if Self.isClaudeOAuthFlowDebugEnabled {
                        Self.log.debug(
                            "Claude OAuth credential load (post-delegation retry)",
                            metadata: [
                                "cooldownEnabled": "\(self.oauthKeychainPromptCooldownEnabled)",
                                "didSyncSilently": "\(didSyncSilently)",
                                "allowKeychainPrompt": "\(retryAllowKeychainPrompt)",
                                "delegatedOutcome": Self.delegatedRefreshOutcomeLabel(delegatedOutcome),
                                "interaction": promptPolicy.interactionLabel,
                                "promptMode": promptPolicy.mode.rawValue,
                            ])
                    }

                    if !refreshedCreds.scopes.contains("user:profile") {
                        let scopes = refreshedCreds.scopes.joined(separator: ", ")
                        throw ClaudeUsageError.oauthFailed(
                            "Claude OAuth token missing 'user:profile' scope (has: \(scopes)). "
                                + "Run `claude setup-token` to re-generate credentials, "
                                + "or switch Claude Source to Web/CLI.")
                    }

                    let usage = try await Self.fetchOAuthUsage(accessToken: refreshedCreds.accessToken)
                    return try Self.mapOAuthUsage(usage, credentials: refreshedCreds)
                } catch {
                    Self.log.debug(
                        "Claude OAuth post-delegation retry failed",
                        metadata: Self.delegatedRetryFailureMetadata(
                            error: error,
                            oauthKeychainPromptCooldownEnabled: self.oauthKeychainPromptCooldownEnabled,
                            delegatedOutcome: delegatedOutcome))
                    throw ClaudeUsageError.oauthFailed(
                        Self.delegatedRefreshFailureMessage(for: delegatedOutcome, retryError: error))
                }
            }
            throw ClaudeUsageError.oauthFailed(error.localizedDescription)
        } catch let error as ClaudeOAuthFetchError {
            ClaudeOAuthCredentialsStore.invalidateCache()
            if case let .serverError(statusCode, body) = error,
               statusCode == 403,
               body?.contains("user:profile") ?? false
            {
                throw ClaudeUsageError.oauthFailed(
                    "Claude OAuth token does not meet scope requirement 'user:profile'. "
                        + "Run `claude setup-token` to re-generate credentials, or switch Claude Source to Web/CLI.")
            }
            throw ClaudeUsageError.oauthFailed(error.localizedDescription)
        } catch {
            throw ClaudeUsageError.oauthFailed(error.localizedDescription)
        }
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
        timeout: TimeInterval = 15) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome
    {
        #if DEBUG
        if let override = delegatedRefreshAttemptOverride {
            return await override(now, timeout)
        }
        #endif
        return await ClaudeOAuthDelegatedRefreshCoordinator.attempt(now: now, timeout: timeout)
    }

    private static func delegatedRefreshOutcomeLabel(_ outcome: ClaudeOAuthDelegatedRefreshCoordinator
        .Outcome) -> String
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
        _ = retryError
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

        guard let primary = makeWindow(usage.fiveHour, windowMinutes: 5 * 60) else {
            throw ClaudeUsageError.parseFailed("missing session data")
        }

        let weekly = makeWindow(usage.sevenDay, windowMinutes: 7 * 24 * 60)
        let modelSpecific = makeWindow(
            usage.sevenDaySonnet ?? usage.sevenDayOpus,
            windowMinutes: 7 * 24 * 60)

        let loginMethod = Self.inferPlan(rateLimitTier: credentials.rateLimitTier)
        let providerCost = Self.oauthExtraUsageCost(usage.extraUsage, loginMethod: loginMethod)

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: weekly,
            opus: modelSpecific,
            providerCost: providerCost,
            updatedAt: Date(),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod,
            rawText: nil)
    }

    private static func oauthExtraUsageCost(
        _ extra: OAuthExtraUsage?,
        loginMethod: String?) -> ProviderCostSnapshot?
    {
        guard let extra, extra.isEnabled == true else { return nil }
        guard let used = extra.usedCredits,
              let limit = extra.monthlyLimit
        else { return nil }
        let currency = extra.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = (currency?.isEmpty ?? true) ? "USD" : currency!
        let normalized = Self.normalizeClaudeExtraUsageAmounts(used: used, limit: limit)
        let snapshot = ProviderCostSnapshot(
            used: normalized.used,
            limit: normalized.limit,
            currencyCode: code,
            period: "Monthly",
            resetsAt: nil,
            updatedAt: Date())
        return Self.rescaleClaudeExtraUsageCostIfNeeded(snapshot, loginMethod: loginMethod)
    }

    private static func normalizeClaudeExtraUsageAmounts(used: Double, limit: Double) -> (
        used: Double, limit: Double)
    {
        // Claude's OAuth API returns values in cents (minor units), same as the Web API.
        // Always convert to dollars (major units) for display consistency.
        // This removes the fragile heuristic that could fail on non-whole cent values
        // (e.g., 5472.50 cents would not be detected as needing conversion).
        // See: ClaudeWebAPIFetcher.swift which always divides by 100.
        (used: used / 100.0, limit: limit / 100.0)
    }

    /// Some non-enterprise plans report extra usage amounts 100x too high.
    /// Scale down again when limits are implausible.
    private static func rescaleClaudeExtraUsageCostIfNeeded(
        _ cost: ProviderCostSnapshot?,
        loginMethod: String?) -> ProviderCostSnapshot?
    {
        guard let cost else { return nil }
        guard let threshold = Self.extraUsageRescaleThreshold(for: loginMethod) else { return cost }
        guard cost.limit >= threshold else { return cost }

        return ProviderCostSnapshot(
            used: cost.used / 100.0,
            limit: cost.limit / 100.0,
            currencyCode: cost.currencyCode,
            period: cost.period,
            resetsAt: cost.resetsAt,
            updatedAt: cost.updatedAt)
    }

    private static func extraUsageRescaleThreshold(for loginMethod: String?) -> Double? {
        let normalized =
            loginMethod?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
        if normalized.contains("enterprise") { return nil }
        return 1000
    }

    private static func inferPlan(rateLimitTier: String?) -> String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        if tier.contains("max") { return "Claude Max" }
        if tier.contains("pro") { return "Claude Pro" }
        if tier.contains("team") { return "Claude Team" }
        if tier.contains("enterprise") { return "Claude Enterprise" }
        return nil
    }

    // MARK: - Web API path (uses browser cookies)

    private func loadViaWebAPI() async throws -> ClaudeUsageSnapshot {
        let webData: ClaudeWebAPIFetcher.WebUsageData =
            if let header = self.manualCookieHeader {
                try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: header) { msg in
                    Self.log.debug(msg)
                }
            } else {
                try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: self.browserDetection) { msg in
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

        let providerCost = Self.rescaleClaudeExtraUsageCostIfNeeded(
            webData.extraUsageCost,
            loginMethod: webData.loginMethod)

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: secondary,
            opus: opus,
            providerCost: providerCost,
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

    private func loadViaPTY(model: String, timeout: TimeInterval = 10) async throws
        -> ClaudeUsageSnapshot
    {
        guard TTYCommandRunner.which("claude") != nil else {
            throw ClaudeUsageError.claudeNotInstalled
        }
        let probe = ClaudeStatusProbe(
            claudeBinary: "claude",
            timeout: timeout,
            keepCLISessionsAlive: self.keepCLISessionsAlive)
        let snap = try await probe.fetch()

        guard let sessionPctLeft = snap.sessionPercentLeft else {
            throw ClaudeUsageError.parseFailed("missing session data")
        }

        func makeWindow(pctLeft: Int?, reset: String?) -> RateWindow? {
            guard let left = pctLeft else { return nil }
            let used = max(0, min(100, 100 - Double(left)))
            let resetClean = reset?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RateWindow(
                usedPercent: used,
                windowMinutes: nil,
                resetsAt: ClaudeStatusProbe.parseResetDate(from: resetClean),
                resetDescription: resetClean)
        }

        let primary = makeWindow(pctLeft: sessionPctLeft, reset: snap.primaryResetDescription)!
        let weekly = makeWindow(
            pctLeft: snap.weeklyPercentLeft, reset: snap.secondaryResetDescription)
        let opus = makeWindow(pctLeft: snap.opusPercentLeft, reset: snap.opusResetDescription)

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: weekly,
            opus: opus,
            providerCost: nil,
            updatedAt: Date(),
            accountEmail: snap.accountEmail,
            accountOrganization: snap.accountOrganization,
            loginMethod: snap.loginMethod,
            rawText: snap.rawText)
    }

    private func applyWebExtrasIfNeeded(to snapshot: ClaudeUsageSnapshot) async
        -> ClaudeUsageSnapshot
    {
        guard self.useWebExtras, self.dataSource != .web else { return snapshot }
        do {
            let webData: ClaudeWebAPIFetcher.WebUsageData =
                if let header = self.manualCookieHeader {
                    try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: header) { msg in
                        Self.log.debug(msg)
                    }
                } else {
                    try await ClaudeWebAPIFetcher.fetchUsage(
                        browserDetection: self.browserDetection)
                    { msg in
                        Self.log.debug(msg)
                    }
                }
            // Only merge cost extras; keep identity fields from the primary data source.
            if snapshot.providerCost == nil, let extra = webData.extraUsageCost {
                let normalizedExtra = Self.rescaleClaudeExtraUsageCostIfNeeded(
                    extra,
                    loginMethod: snapshot.loginMethod ?? webData.loginMethod)
                return ClaudeUsageSnapshot(
                    primary: snapshot.primary,
                    secondary: snapshot.secondary,
                    opus: snapshot.opus,
                    providerCost: normalizedExtra,
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
}

#if DEBUG
extension ClaudeUsageFetcher {
    public static func _mapOAuthUsageForTesting(
        _ data: Data,
        rateLimitTier: String? = nil) throws -> ClaudeUsageSnapshot
    {
        let usage = try ClaudeOAuthUsageFetcher.decodeUsageResponse(data)
        let creds = ClaudeOAuthCredentials(
            accessToken: "test",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: [],
            rateLimitTier: rateLimitTier)
        return try Self.mapOAuthUsage(usage, credentials: creds)
    }

    public static func _rescaleExtraUsageForTesting(
        _ cost: ProviderCostSnapshot?,
        snapshotLoginMethod: String?,
        webLoginMethod: String?) -> ProviderCostSnapshot?
    {
        let loginMethod = snapshotLoginMethod ?? webLoginMethod
        return Self.rescaleClaudeExtraUsageCostIfNeeded(cost, loginMethod: loginMethod)
    }
}
#endif
