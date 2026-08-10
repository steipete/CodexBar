import Foundation

public enum ClaudeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let ttyLaunch = ProviderTTYLaunchConfig(
        executableOverrideEnvironmentKey: "CLAUDE_CLI_PATH",
        bundledWatchdogHelperName: "CodexBarClaudeWatchdog",
        probeWorkingDirectory: { ClaudeStatusProbe.preparedProbeWorkingDirectoryURL() })
    private static let cli = ProviderCLIConfig(
        name: "claude",
        binaryLocator: { BinaryLocator.resolveClaudeBinary() },
        versionDetector: { browserDetection in
            ClaudeUsageFetcher(browserDetection: browserDetection).detectVersion()
        },
        supportsCostCommand: true,
        prefersBinaryLocatorForWhich: true,
        ttyLaunch: Self.ttyLaunch,
        browserSupportExemption: { sourceMode, _, _ in sourceMode == .auto })
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        environmentProjections: [.apiKey(ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey)],
        tokenResolver: { kind, environment, _ in
            guard kind == .primary,
                  let token = ClaudeAdminAPISettingsReader.apiKey(environment: environment)
            else { return nil }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        tokenAccountSupport: TokenAccountSupport(
            title: "Claude credentials",
            subtitle: "Store Claude sessionKey cookies, OAuth tokens, or Anthropic Admin API keys.",
            placeholder: "Paste sessionKey, OAuth token, or sk-ant-admin…",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: "sessionKey",
            showsOrganizationField: true,
            environmentOverride: { token in
                switch ClaudeCredentialRouting.resolve(tokenAccountToken: token, manualCookieHeader: nil) {
                case let .oauth(accessToken):
                    [ClaudeOAuthCredentialsStore.environmentTokenKey: accessToken]
                case let .adminAPIKey(apiKey):
                    [ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: apiKey]
                case .none, .webCookie:
                    nil
                }
            },
            environmentScrubber: { environment, _ in
                environment.removeValue(forKey: ClaudeOAuthCredentialsStore.environmentTokenKey)
                for key in ClaudeAdminAPISettingsReader.apiKeyEnvironmentKeys {
                    environment.removeValue(forKey: key)
                }
            }),
        authDetector: { environment, _ in
            ClaudeAdminAPISettingsReader.apiKey(environment: environment) == nil ? [] : ["api"]
        },
        selectedAccountSourceModeResolver: { base, account, _ in
            guard let account else { return base }
            return switch ClaudeCredentialRouting.resolve(tokenAccountToken: account.token, manualCookieHeader: nil) {
            case .adminAPIKey: .api
            case .oauth: .oauth
            case .webCookie: .web
            case .none: base
            }
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .claude,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(
                supported: [.automatic, .primary, .secondary, .primaryAndSecondary, .extraUsage]),
            settingsSection: .init(ClaudeProviderSettingsKey.self, credentialSettings: { context in
                let manualCookieHeader = context.account == nil ? context.config?.sanitizedCookieHeader : nil
                let routing = ClaudeCredentialRouting.resolve(
                    tokenAccountToken: context.account?.token,
                    manualCookieHeader: manualCookieHeader)
                let source: ClaudeUsageDataSource = if context.account != nil {
                    switch routing {
                    case .adminAPIKey: .api
                    case .oauth: .oauth
                    case .webCookie: .web
                    case .none: .auto
                    }
                } else if routing.adminAPIKey != nil {
                    .api
                } else if routing.isOAuth {
                    .oauth
                } else {
                    .auto
                }
                let cookieSource: ProviderCookieSource = routing.isOAuth || routing.adminAPIKey != nil
                    ? .off
                    : context.cookieSettings(for: .claude).cookieSource
                return ClaudeProviderSettings(
                    usageDataSource: source,
                    webExtrasEnabled: false,
                    cookieSource: cookieSource,
                    manualCookieHeader: routing.manualCookieHeader,
                    organizationID: context.account?.sanitizedOrganizationID)
            }),
            credentials: self.credentials,
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
                sharePlanLabels: [
                    "free": "Free", "claude free": "Free", "pro": "Pro", "claude pro": "Pro",
                    "max": "Max", "claude max": "Max", "max 5x": "Max 5x", "claude max 5x": "Max 5x",
                    "max 20x": "Max 20x", "claude max 20x": "Max 20x", "team": "Team",
                    "claude team": "Team", "claude team standard": "Team Standard",
                    "claude team premium": "Team Premium", "enterprise": "Enterprise",
                    "claude enterprise": "Enterprise", "ultra": "Ultra", "claude ultra": "Ultra",
                ],
                debugPane: ProviderDebugPaneCapabilities(
                    probeLogOrder: 1,
                    notificationSimulationOrder: 1,
                    errorSimulationOrder: 1),
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://console.anthropic.com/settings/billing",
                subscriptionDashboardURL: "https://claude.ai/settings/usage",
                changelogURL: "https://github.com/anthropics/claude-code/releases",
                statusPageURL: "https://status.claude.com/"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .claude),
                iconResourceName: "ProviderIcon-claude",
                color: ProviderColor(red: 204 / 255, green: 124 / 255, blue: 94 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xD97757),
                    ProviderColor(hex: 0xF0EEE6),
                    ProviderColor(hex: 0x141413),
                ],
                burnDownWidgetColor: ProviderColor(red: 0.880, green: 0.580, blue: 0.180)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: self.noDataMessage,
                menuHintLines: [.estimate],
                supportsTokenSnapshot: true,
                settingsStatusOrder: 0,
                estimateDisclaimer: "Estimated from local Claude logs at API rates; token totals include cache " +
                    "read/write tokens and may differ from Claude Code /status."),
            pace: ProviderPaceCapability(
                primary: .session(maximumMinutes: 300),
                secondary: .weekly,
                tertiary: .weekly,
                sessionPaceWindowRule: .custom { _, _ in true }),
            history: .alwaysTracked,
            presentation: ProviderUsagePresentation(
                identityPresenter: { provider, snapshot in
                    guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    let display = if plan.hasPrefix("Claude "),
                                     ClaudePlan.fromCompatibilityLoginMethod(plan) != nil
                    {
                        plan
                    } else {
                        plan.capitalized
                    }
                    return ProviderIdentityPresentation(badge: display, plan: display)
                },
                costPresenter: { snapshot in
                    guard let cost = snapshot.providerCost else { return ProviderCostPresentation() }
                    let balances = cost.balance.map {
                        [ProviderCostPresentation.Balance(
                            label: "Extra usage balance",
                            amount: $0,
                            currencyCode: cost.currencyCode)]
                    } ?? []
                    return ProviderCostPresentation(
                        showsGenericFallback: !(cost.used == 0 && cost.limit == 0 && cost.balance != nil),
                        balances: balances,
                        menuCardStyle: .claude)
                },
                iconDecorations: [.notches],
                automaticSelectionPrioritizesExhaustedWindow: false,
                menuBarWindowResolver: self.menuBarWindow,
                planUtilizationSeriesResolver: { snapshot in
                    var series: Set<ProviderPlanUtilizationSeries> = []
                    if snapshot.primary != nil {
                        series.insert(.session)
                    }
                    if snapshot.secondary != nil {
                        series.insert(.weekly)
                    }
                    if snapshot.tertiary != nil {
                        series.insert(.tertiary)
                    }
                    return series
                },
                secondaryGloballyCapsPrimary: true,
                menuCard: ProviderMenuCardPresentation(
                    costVisibilityResolver: { context in
                        context.showOptionalUsage || context.snapshot?.loginMethod(for: .claude) == "Admin API"
                    },
                    supportsInlineTokenCostDashboard: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web, .cli, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: self.cli)
    }

    private static func menuBarWindow(
        context: ProviderMenuBarWindowContext) -> ProviderMenuBarWindowResolution
    {
        guard context.metric == .automatic || context.metric == .primaryAndSecondary,
              let cost = context.snapshot.providerCost,
              cost.limit > 0,
              context.snapshot.secondary == nil,
              context.snapshot.tertiary == nil,
              context.snapshot.primary == nil || context.snapshot.primary?.isSyntheticPlaceholder == true
        else { return .unhandled }
        let usedPercent = max(0, min(100, (cost.used / cost.limit) * 100))
        return .resolved(RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: cost.resetsAt,
            resetDescription: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        // An explicitly selected account is the credential authority for this fetch. The global
        // source only controls ambient-account routing and must not redirect a selected account.
        if context.selectedTokenAccountID != nil {
            if ClaudeAdminAPIFetchStrategy.isSelectedAdminAPIAccount(context: context) {
                return [ClaudeAdminAPIFetchStrategy()]
            }
            if self.isSelectedOAuthTokenAccount(context: context) {
                return [ClaudeOAuthFetchStrategy()]
            }
            if self.isSelectedWebCookieTokenAccount(context: context) {
                return [ClaudeWebFetchStrategy(browserDetection: context.browserDetection)]
            }
            // A selected account is an authority boundary. Missing or malformed selected credentials must never
            // fall through to an ambient CLI, browser session, or global API key and be labeled as that account.
            return []
        }
        if context.claudeOwnerCLIRecoveryOnly {
            return [ClaudeCLIFetchStrategy(
                useWebExtras: false,
                includePrepaidBalance: false,
                manualCookieHeader: nil,
                browserDetection: context.browserDetection,
                hasWebFallback: false)]
        }
        if context.sourceMode == .api || self.hasAutoAdminAPIKey(context: context) {
            return [ClaudeAdminAPIFetchStrategy()]
        }

        let planningInput = Self.makePlanningInput(context: context)
        let plan = ClaudeSourcePlanner.resolve(input: planningInput)
        let webEnrichmentAccess = Self.webEnrichmentAccess(context: context)

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
                        && planningInput.webExtrasEnabled
                        && webEnrichmentAccess.isAvailable,
                    includePrepaidBalance: context.runtime == .app
                        && context.includeOptionalUsage
                        && webEnrichmentAccess.isAvailable,
                    manualCookieHeader: webEnrichmentAccess.manualCookieHeader,
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

    private static func isSelectedOAuthTokenAccount(context: ProviderFetchContext) -> Bool {
        guard context.selectedTokenAccountID != nil,
              context.settings?.claude?.usageDataSource == .oauth
        else {
            return false
        }
        return !(context.env[ClaudeOAuthCredentialsStore.environmentTokenKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
    }

    private static func isSelectedWebCookieTokenAccount(context: ProviderFetchContext) -> Bool {
        guard context.selectedTokenAccountID != nil,
              context.settings?.claude?.usageDataSource == .web,
              context.settings?.claude?.cookieSource == .manual
        else {
            return false
        }
        return CookieHeaderNormalizer.normalize(context.settings?.claude?.manualCookieHeader) != nil
    }

    private static func makePlanningInput(context: ProviderFetchContext) -> ClaudeSourcePlanningInput {
        let webExtrasEnabled = context.settings?.claude?.webExtrasEnabled ?? false
        let hasWebSession = Self.hasPlausibleWebSession(context: context)
        let shouldAttemptOAuth = context.runtime == .app &&
            (context.sourceMode == .auto || context.sourceMode == .oauth)

        return ClaudeSourcePlanningInput(
            runtime: context.runtime,
            selectedDataSource: Self.sourceDataSource(from: context.sourceMode),
            webExtrasEnabled: webExtrasEnabled,
            hasWebSession: hasWebSession,
            hasCLI: ClaudeCLIResolver.isAvailable(environment: context.env),
            // App Auto and explicit OAuth perform one real, noninteractive OAuth attempt. Do not preflight here:
            // a preflight can mutate cache state and make the real fetch misclassify a typed error.
            hasOAuthCredentials: shouldAttemptOAuth)
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

    fileprivate struct WebEnrichmentAccess {
        let isAvailable: Bool
        let manualCookieHeader: String?
    }

    fileprivate static func webEnrichmentAccess(context: ProviderFetchContext) -> WebEnrichmentAccess {
        switch context.settings?.claude?.cookieSource {
        case .off?:
            return WebEnrichmentAccess(isAvailable: false, manualCookieHeader: nil)
        case .manual?:
            let header = self.manualCookieHeader(from: context)
            return WebEnrichmentAccess(
                isAvailable: ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: header),
                manualCookieHeader: header)
        case .auto?, nil:
            let header = CookieHeaderCache.load(provider: .claude)?.cookieHeader
            return WebEnrichmentAccess(
                isAvailable: ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: header),
                manualCookieHeader: header)
        }
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
        if runtime == .app, sourceMode == .oauth {
            return !ClaudeOAuthFetchStrategy().directCredentialIsMissing(environment: environment)
        }
        return ClaudeOAuthFetchStrategy.isPlausiblyAvailable(
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
        if context.runtime == .app,
           context.sourceMode == .oauth,
           self.plannedStep.dataSource == .oauth
        {
            return true
        }
        guard context.sourceMode == .auto else {
            return await self.base.isAvailable(context)
        }
        guard self.plannedStep.isPlausiblyAvailable else { return false }
        if self.plannedStep.dataSource == .cli ||
            (context.runtime == .app && self.plannedStep.dataSource == .web)
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
        ProviderTokenResolver.token(for: .claude, environment: environment)
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
        if let override = Self.nonInteractiveCredentialRecordOverride {
            return override
        }
        #endif

        return try? ClaudeOAuthCredentialsStore.loadRecord(
            environment: environment,
            allowKeychainPrompt: false,
            respectKeychainPromptCooldown: true,
            allowClaudeKeychainRepairWithoutPrompt: false)
    }

    func directCredentialIsMissing(environment: [String: String]) -> Bool {
        #if DEBUG
        if Self.nonInteractiveCredentialRecordOverride != nil {
            return false
        }
        #endif

        do {
            _ = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: environment,
                allowKeychainPrompt: false,
                respectKeychainPromptCooldown: true,
                allowClaudeKeychainRepairWithoutPrompt: false,
                clearInvalidCache: false)
            return false
        } catch ClaudeOAuthCredentialsError.notFound {
            return true
        } catch {
            // A malformed, unreadable, or otherwise unusable direct credential remains an explicit
            // OAuth error. Do not hide it by silently switching credential authorities.
            return false
        }
    }

    private func isClaudeCLIAvailable(environment: [String: String]) -> Bool {
        #if DEBUG
        if let override = Self.claudeCLIAvailableOverride {
            return override
        }
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

        // Explicit OAuth is authoritative and must execute exactly once so its concrete credential
        // result is preserved. In particular, do not destructively probe a malformed cache here and
        // then misclassify the now-cleared cache as absent during fetch.
        guard sourceMode == .auto else { return true }

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
                guard sourceMode == .auto else { return true }
                guard claudeCLIAvailable else { return false }
                guard ProviderInteractionContext.current == .background else { return true }
                // An expired Claude CLI credential requires the delegated Claude CLI refresh path.
                // That child process can access Keychain outside CodexBar's no-UI controls, so do
                // not plan it during background Auto refresh without an explicit opt-in.
                guard !KeychainAccessGate.isDisabled,
                      ClaudeOAuthKeychainPromptPreference.storedMode() == .always
                else {
                    return false
                }
                return !Self.hasMcpOAuthOnlyClaudeKeychainPayload(environment: environment)
            case .environment:
                return sourceMode != .auto
            }
        }

        let promptPolicyApplicable = ClaudeOAuthKeychainPromptPreference.isApplicable()
        if ProviderInteractionContext.current == .userInitiated {
            _ = ClaudeOAuthKeychainAccessGate.clearDenied()
        }

        if promptPolicyApplicable,
           !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
        {
            return false
        }
        return ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt()
    }

    private static func hasMcpOAuthOnlyClaudeKeychainPayload(environment: [String: String]) -> Bool {
        ClaudeOAuthCredentialsStore.shouldBlockSelectedProfileForMcpOnlyClaudeKeychain(
            interaction: ProviderInteractionContext.current,
            environment: environment)
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.isPlausiblyAvailable(
            runtime: context.runtime,
            sourceMode: context.sourceMode,
            environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let webEnrichmentAccess = ClaudeProviderDescriptor.webEnrichmentAccess(context: context)
        let useWebExtras = context.runtime == .app &&
            (context.settings?.claude?.webExtrasEnabled ?? false) &&
            webEnrichmentAccess.isAvailable
        let includePrepaidBalance = context.runtime == .app &&
            context.includeOptionalUsage &&
            webEnrichmentAccess.isAvailable
        let fetcher = ClaudeUsageFetcher(
            browserDetection: context.browserDetection,
            environment: context.env,
            runtime: context.runtime,
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: context.sourceMode == .auto,
            oauthSafeCredentialSourcesOnly: context.sourceMode == .auto,
            preserveInvalidOAuthCache: context.sourceMode == .oauth,
            allowBackgroundDelegatedRefresh: false,
            useWebExtras: useWebExtras,
            manualCookieHeader: webEnrichmentAccess.manualCookieHeader,
            webOrganizationID: context.settings?.claude?.organizationID,
            webExtrasTimeout: context.webTimeout,
            includePrepaidBalance: includePrepaidBalance)
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
            claudeOAuthCredentialOwner: usage.oauthCredentialOwner,
            claudeOAuthKeychainCredentialMismatch: usage.oauthKeychainCredentialMismatch,
            claudeOAuthKeychainCredentialAbsent: usage.oauthKeychainCredentialAbsent,
            claudeOAuthKeychainCredentialUnavailable: usage.oauthKeychainCredentialUnavailable)
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard !Task.isCancelled, !ClaudeOAuthFetchError.isCancellation(error) else {
            return false
        }
        // The unreadable terminal state (#2634): Claude Code's Keychain item is closed to us (no consent)
        // and no credentials file exists. OAuth cannot recover, so hand off to the owner CLI usage fallback.
        if context.runtime == .app, error is ClaudeOAuthUnreadableCredentialsError {
            return true
        }
        if context.runtime == .app,
           context.sourceMode == .oauth,
           let credentialsError = error as? ClaudeOAuthCredentialsError
        {
            switch credentialsError {
            case .notFound, .refreshDelegatedToClaudeCLI:
                return true
            default:
                break
            }
        }
        // In Auto mode, fall back to the next strategy (cli/web) when safe credentials are absent or OAuth fails.
        // Cancellation itself is always terminal.
        return context.runtime == .app && context.sourceMode == .auto
    }

    fileprivate static func snapshot(
        from usage: ClaudeUsageSnapshot,
        dataConfidence: UsageDataConfidence = .unknown) -> UsageSnapshot
    {
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
            identity: identity,
            dataConfidence: dataConfidence)
    }

    static func _snapshotForTesting(
        from usage: ClaudeUsageSnapshot,
        dataConfidence: UsageDataConfidence = .unknown) -> UsageSnapshot
    {
        self.snapshot(from: usage, dataConfidence: dataConfidence)
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
                webOrganizationID: context.settings?.claude?.organizationID,
                includePrepaidBalance: context.includeOptionalUsage)
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
    let includePrepaidBalance: Bool
    let manualCookieHeader: String?
    let browserDetection: BrowserDetection
    let hasWebFallback: Bool

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard let binary = ClaudeCLIResolver.resolvedBinaryPath(environment: context.env) else { return false }

        if context.runtime == .cli {
            // A CodexBarCLI invocation is already an explicit user action. Preserve the definitive logged-out guard,
            // but do not let an unavailable credential-reading `auth status` child override the owner CLI's ability
            // to provide usage. The app keeps the stricter marker policy below for prompt-free scheduled refreshes.
            return await ClaudeCLIAuthStatusProbe.authenticationStatus(
                binary: binary,
                environment: context.env) != .loggedOut
        }

        let isBackgroundAppRefresh = ProviderInteractionContext.current == .background
        // Explicit OAuth may recover through the interactive owner CLI only from a user action. A scheduled
        // refresh with missing credentials must remain on the selected OAuth authority and fail without UI.
        if isBackgroundAppRefresh, context.sourceMode == .oauth {
            return false
        }

        let isBackgroundAutoRefresh = isBackgroundAppRefresh && context.sourceMode == .auto
        if isBackgroundAutoRefresh {
            // Every Claude child process is opaque to CodexBar's no-UI Keychain controls, including
            // `claude auth status`. Background Auto therefore reuses only availability established by a
            // successful user-initiated CLI fetch in this process. The narrow exception is the owner usage
            // fetch when Keychain access is explicitly disabled; version/auth children retain the global gate.
            return ClaudeCLIBackgroundAvailability.allowsBackgroundAutoUsageFetch(
                binary: binary,
                environment: context.env)
        }

        // App user actions intentionally launch the interactive path directly so the user can complete authentication.
        return true
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
            webExtrasTimeout: context.webTimeout,
            includePrepaidBalance: self.includePrepaidBalance && context.includeOptionalUsage,
            keepCLISessionsAlive: keepAlive)
        let binary = ClaudeCLIResolver.resolvedBinaryPath(environment: context.env)
        let backgroundAvailabilityMarker = binary.flatMap {
            ClaudeCLIBackgroundAvailability.captureMarker(binary: $0, environment: context.env)
        }
        let usage: ClaudeUsageSnapshot
        do {
            usage = try await fetcher.loadLatestUsage(model: "sonnet")
        } catch {
            if let backgroundAvailabilityMarker {
                ClaudeCLIBackgroundAvailability.revoke(backgroundAvailabilityMarker)
            }
            throw error
        }
        if context.runtime == .app,
           ProviderInteractionContext.current == .userInitiated,
           let backgroundAvailabilityMarker
        {
            ClaudeCLIBackgroundAvailability.establish(backgroundAvailabilityMarker)
        }
        return self.makeResult(
            // The PTY /usage panel exposes rendered percentages only, so CLI-sourced data carries an
            // explicit degraded-fidelity marker that the card surfaces as "via Claude CLI".
            usage: ClaudeOAuthFetchStrategy.snapshot(from: usage, dataConfidence: .percentOnly),
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

enum ClaudeCLIBackgroundAvailability {
    struct Marker: Hashable {
        let binary: String
        let accountScope: String
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var markers: Set<Marker> = []
        private var revokedMarkers: Set<Marker> = []

        func contains(_ marker: Marker) -> Bool {
            self.lock.withLock { self.markers.contains(marker) }
        }

        func insert(_ marker: Marker) {
            self.lock.withLock {
                _ = self.markers.insert(marker)
                self.revokedMarkers.remove(marker)
            }
        }

        func remove(_ marker: Marker) {
            self.lock.withLock {
                self.markers.remove(marker)
                _ = self.revokedMarkers.insert(marker)
            }
        }

        func isRevoked(_ marker: Marker) -> Bool {
            self.lock.withLock { self.revokedMarkers.contains(marker) }
        }
    }

    private static let sharedStore = Store()
    @TaskLocal private static var storeOverrideForTesting: Store?

    private static var store: Store {
        self.storeOverrideForTesting ?? self.sharedStore
    }

    static func isEstablished(binary: String, environment: [String: String]) -> Bool {
        guard let marker = self.captureMarker(binary: binary, environment: environment) else { return false }
        return self.store.contains(marker)
    }

    static func allowsOpaqueChildExecution(binary: String, environment: [String: String]) -> Bool {
        guard ProviderInteractionContext.current == .background else { return true }
        guard self.isEstablished(binary: binary, environment: environment) else { return false }
        // Disable Keychain is a complete opt-out, so no prompt policy applies. With Keychain enabled,
        // retain the explicit background opt-in introduced with the opaque-child safety gate.
        return KeychainAccessGate.isExplicitlyDisabled
            || ClaudeOAuthKeychainPromptPreference.storedMode() == .always
    }

    static func allowsBackgroundAutoUsageFetch(binary: String, environment: [String: String]) -> Bool {
        guard ProviderInteractionContext.current == .background else { return true }
        guard KeychainAccessGate.isExplicitlyDisabled else {
            return self.allowsOpaqueChildExecution(binary: binary, environment: environment)
        }
        // Disable Keychain explicitly permits one owner-CLI usage attempt on a cold profile. A failed attempt
        // records revocation below, preventing each background timer tick from retrying until a foreground success.
        guard let marker = self.captureMarker(binary: binary, environment: environment) else { return false }
        return !self.store.isRevoked(marker)
    }

    static func establish(binary: String, environment: [String: String]) {
        guard let marker = self.captureMarker(binary: binary, environment: environment) else { return }
        self.establish(marker)
    }

    static func establish(_ marker: Marker) {
        self.store.insert(marker)
    }

    static func revoke(_ marker: Marker) {
        self.store.remove(marker)
    }

    static func captureMarker(binary: String, environment: [String: String]) -> Marker? {
        guard let accountScope = ClaudeAccountProfile.identifiedSessionScope(environment: environment) else {
            return nil
        }
        return Marker(binary: binary, accountScope: accountScope)
    }

    #if DEBUG
    static func withIsolatedStoreForTesting<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$storeOverrideForTesting.withValue(Store()) {
            try await operation()
        }
    }
    #endif
}
