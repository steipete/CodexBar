import Foundation

public enum OpenCodeGoProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: OpenCodeGoSettingsReader.apiKeyEnvironmentKey,
        apiKeyDebugLabel: OpenCodeGoSettingsReader.apiKeyEnvironmentKey,
        resolve: OpenCodeGoSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "OpenCode Go accounts",
            subtitle: "Store multiple OpenCode Go API keys or Cookie headers.",
            placeholder: "API key or Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil,
            environmentOverride: { token in
                guard let key = OpenCodeGoSettingsReader.tokenAccountAPIKey(token) else { return nil }
                return [OpenCodeGoSettingsReader.apiKeyEnvironmentKey: key]
            },
            environmentScrubber: { environment, _ in
                environment.removeValue(forKey: OpenCodeGoSettingsReader.apiKeyEnvironmentKey)
            }),
        selectedAccountSourceModeResolver: { base, account, _ in
            guard base == .auto, let account,
                  OpenCodeGoSettingsReader.tokenAccountAPIKey(account.token) != nil else { return base }
            return .api
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .opencodego,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(
                supported: [.automatic, .primary, .secondary, .tertiary]),
            settingsSection: .init(
                OpenCodeGoProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .opencodego)
                    return OpenCodeProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        workspaceID: context.config?.workspaceID)
                }),
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 3),
            metadata: ProviderMetadata(
                id: .opencodego,
                displayName: "OpenCode Go",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenCode Go usage",
                cliName: "opencodego",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://opencode.ai/auth",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .opencodego),
                iconResourceName: "ProviderIcon-opencodego",
                color: ProviderColor(red: 59 / 255, green: 130 / 255, blue: 246 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x211E1E),
                    ProviderColor(hex: 0xA3BE8C),
                    ProviderColor(hex: 0xCFCECD),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: {
                    "No OpenCode Go local usage history found in ~/.local/share/opencode/opencode.db."
                },
                supportsTokenSnapshot: true),
            pace: ProviderPaceCapability(
                resetWindowPace: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                inferredMonthlyDuration: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                primary: .session(maximumMinutes: 300),
                secondary: .weekly,
                // Device-local costs cannot establish the account's quota usage or billing-cycle boundaries.
                allowsEstimatedUsage: false),
            history: .alwaysTracked,
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    let style: ProviderCostMenuCardStyle = snapshot.providerCost?.period == "Zen balance"
                        ? .zenBalance
                        : .generic
                    return ProviderCostPresentation(menuCardStyle: style)
                },
                switcherUsesAutomaticMenuBarWindow: true,
                menuBarWindowResolver: { context in
                    guard context.metric == .automatic else { return .unhandled }
                    return .automaticCandidates([
                        context.snapshot.primary,
                        context.snapshot.secondary,
                        context.snapshot.tertiary,
                    ].compactMap(\.self))
                },
                planUtilizationSeriesResolver: { snapshot in
                    var series: Set<ProviderPlanUtilizationSeries> = []
                    if snapshot.primary != nil {
                        series.insert(.session)
                    }
                    if snapshot.secondary != nil {
                        series.insert(.weekly)
                    }
                    if snapshot.tertiary != nil {
                        series.insert(.monthly)
                    }
                    return series
                },
                menuCard: ProviderMenuCardPresentation(
                    costVisibilityResolver: { context in
                        context.showOptionalUsage ||
                            (context.snapshot?.primary == nil &&
                                context.snapshot?.secondary == nil &&
                                context.snapshot?.providerCost?.period == "Zen balance")
                    },
                    supportsInlineTokenCostDashboard: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "opencodego",
                versionDetector: nil,
                supportsCostCommand: true,
                browserSupportExemption: { sourceMode, _, settings in
                    sourceMode == .auto || settings?.opencodego?.cookieSource == .manual
                }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        if context.sourceMode == .api {
            return [OpenCodeGoAPIUsageFetchStrategy()]
        }
        if context.sourceMode == .web {
            return [OpenCodeGoUsageFetchStrategy()]
        }
        if self.requiresScopedWebStrategy(context: context) {
            return [
                OpenCodeGoUsageFetchStrategy(),
                OpenCodeGoLocalUsageFetchStrategy(),
                OpenCodeGoAPIUsageFetchStrategy(),
            ]
        }
        return [
            OpenCodeGoLocalUsageFetchStrategy(),
            OpenCodeGoAPIUsageFetchStrategy(),
            OpenCodeGoUsageFetchStrategy(),
        ]
    }

    private static func requiresScopedWebStrategy(context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        return context.selectedTokenAccountID != nil || context.settings?.opencodego?.cookieSource == .manual ||
            [context.settings?.opencodego?.workspaceID, context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]]
            .contains { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
}

struct OpenCodeGoLocalUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencodego.local"
    let kind: ProviderFetchKind = .localProbe

    typealias LocalSnapshotLoader = @Sendable (ProviderFetchContext) throws -> OpenCodeGoUsageSnapshot
    typealias WebUsageOverlayFetcher = @Sendable (ProviderFetchContext, String) async throws
        -> OpenCodeGoUsageSnapshot?
    typealias APIUsageOverlayFetcher = @Sendable (ProviderFetchContext, String) async throws
        -> OpenCodeGoUsageSnapshot

    private let cookieHeaderResolver: @Sendable (ProviderFetchContext, Bool) throws -> String
    private let localSnapshotLoader: LocalSnapshotLoader
    private let webUsageOverlayFetcher: WebUsageOverlayFetcher
    private let apiUsageOverlayFetcher: APIUsageOverlayFetcher

    private struct OverlayCookie {
        let header: String
        let cachedEntry: CookieHeaderCache.Entry?
    }

    private struct SnapshotResult {
        let snapshot: OpenCodeGoUsageSnapshot
        let sourceLabel: String
        let quotaIsAuthoritative: Bool
    }

    init(
        cookieHeaderResolver: @escaping @Sendable (ProviderFetchContext, Bool) throws -> String =
            OpenCodeGoUsageFetchStrategy.resolveCookieHeader,
        localSnapshotLoader: @escaping LocalSnapshotLoader = { context in
            try OpenCodeGoLocalUsageReader().fetch(historyDays: context.costUsageHistoryDays)
        },
        webUsageOverlayFetcher: @escaping WebUsageOverlayFetcher = Self.liveWebUsageOverlay,
        apiUsageOverlayFetcher: @escaping APIUsageOverlayFetcher = { context, apiKey in
            try await OpenCodeGoUsageFetcher.fetchAPIUsage(
                apiKey: apiKey,
                timeout: context.webTimeout)
        })
    {
        self.cookieHeaderResolver = cookieHeaderResolver
        self.localSnapshotLoader = localSnapshotLoader
        self.webUsageOverlayFetcher = webUsageOverlayFetcher
        self.apiUsageOverlayFetcher = apiUsageOverlayFetcher
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let result = try await self.snapshot(context: context)
        let usage = result.snapshot.toUsageSnapshot()
        return self.makeResult(
            usage: result.quotaIsAuthoritative ? usage : usage.withDataConfidence(.estimated),
            sourceLabel: result.sourceLabel)
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        error is OpenCodeGoLocalUsageError
    }

    private func snapshot(context: ProviderFetchContext) async throws -> SnapshotResult {
        var snapshot = try self.localSnapshotLoader(context)
        var source = "local"
        if let apiKey = OpenCodeGoSettingsReader.apiKey(environment: context.env) {
            do {
                snapshot = try await snapshot.applyingWebUsage(self.apiUsageOverlayFetcher(context, apiKey))
                source = "local+api"
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                // A session can still provide authoritative quota when the API is unavailable.
            }
        }
        let fallback = SnapshotResult(
            snapshot: snapshot,
            sourceLabel: source,
            quotaIsAuthoritative: source == "local+api")
        guard context.settings?.opencodego?.cookieSource != .off else { return fallback }
        var cookie = Self.cachedOrManualCookie(context: context)
        do {
            if cookie == nil, source == "local", context.sourceMode == .auto,
               (context.settings?.opencodego?.cookieSource ?? .auto) == .auto
            {
                let header = try self.cookieHeaderResolver(context, false)
                let cached = Self.cachedOrManualCookie(context: context)
                cookie = OverlayCookie(
                    header: header,
                    cachedEntry: cached?.header == header ? cached?.cachedEntry : nil)
            }
            guard let cookie else { return fallback }
            if let web = try await self.webUsageOverlayFetcher(context, cookie.header) {
                if source == "local+api" {
                    return SnapshotResult(
                        snapshot: snapshot.withZenBalanceUSD(web.zenBalanceUSD ?? snapshot.zenBalanceUSD),
                        sourceLabel: source,
                        quotaIsAuthoritative: true)
                }
                return SnapshotResult(
                    snapshot: snapshot.applyingWebUsage(web),
                    sourceLabel: "local+web",
                    quotaIsAuthoritative: !web.isBalanceOnly)
            }
            guard source == "local", context.includeOptionalUsage else { return fallback }
            let workspaceOverride = context.settings?.opencodego?.workspaceID
                ?? context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
            let zenBalanceStart = ContinuousClock.now
            let zenBalanceTask = Task<Double?, Error> {
                do {
                    return try await OpenCodeGoUsageFetcher.fetchOptionalZenBalance(
                        cookieHeader: cookie.header,
                        timeout: context.webTimeout,
                        workspaceIDOverride: workspaceOverride)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return nil
                }
            }
            let balance = try await OpenCodeGoUsageFetcher.completedOptionalZenBalance(
                from: zenBalanceTask,
                timeout: OpenCodeGoUsageFetcher.optionalZenBalanceJoinTimeout(
                    since: zenBalanceStart,
                    waitForZenBalance: OpenCodeGoUsageFetchStrategy.shouldWaitForZenBalance(context: context)))
            return SnapshotResult(
                snapshot: snapshot.withZenBalanceUSD(balance), sourceLabel: source, quotaIsAuthoritative: false)
        } catch OpenCodeGoUsageError.invalidCredentials {
            #if os(macOS)
            if let cached = cookie?.cachedEntry {
                _ = CookieHeaderCache.clearIfCurrent(provider: .opencodego, expected: cached)
            }
            #endif
            // A manually configured credential is an explicit account selection.
            if source == "local", context.settings?.opencodego?.cookieSource == .manual {
                throw OpenCodeGoUsageError.invalidCredentials
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
        }
        return fallback
    }

    static func liveWebUsageOverlay(
        context: ProviderFetchContext,
        cookieHeader: String) async throws -> OpenCodeGoUsageSnapshot?
    {
        let workspaceOverride = context.settings?.opencodego?.workspaceID
            ?? context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
        do {
            return try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride,
                includeZenBalance: context.includeOptionalUsage,
                waitForZenBalance: OpenCodeGoUsageFetchStrategy.shouldWaitForZenBalance(context: context))
        } catch OpenCodeGoUsageError.invalidCredentials {
            throw OpenCodeGoUsageError.invalidCredentials
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return nil
        }
    }

    private static func cachedOrManualCookie(context: ProviderFetchContext) -> OverlayCookie? {
        if let settings = context.settings?.opencodego, settings.cookieSource == .manual {
            guard let header = OpenCodeWebCookieSupport.requestCookieHeader(from: settings.manualCookieHeader) else {
                return nil
            }
            return OverlayCookie(header: header, cachedEntry: nil)
        }

        #if os(macOS)
        let observation = CookieHeaderCache.observeForConditionalMutation(provider: .opencodego)
        guard let cached = observation.entry,
              let header = OpenCodeWebCookieSupport.requestCookieHeader(from: cached.cookieHeader)
        else { return nil }
        return OverlayCookie(header: header, cachedEntry: cached)
        #else
        return nil
        #endif
    }
}

struct OpenCodeGoAPIUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencodego.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = OpenCodeGoSettingsReader.apiKey(environment: context.env) else {
            throw OpenCodeGoSettingsError.missingAPIKey
        }
        let snapshot = try await OpenCodeGoUsageFetcher.fetchAPIUsage(
            apiKey: apiKey,
            timeout: context.webTimeout)
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if error is CancellationError {
            return false
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return false
        }
        return true
    }
}

struct OpenCodeGoUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencodego.web"
    let kind: ProviderFetchKind = .web

    /// Usage-snapshot reads (`codexbar usage`, `codexbar serve`) are foreground commands, so a
    /// Zen balance that is merely slower than the subscription page is worth waiting for, bounded
    /// by the optional-balance timeout. Guard and diagnostic commands keep the short optional join
    /// grace so a slow balance cannot consume their deadline.
    static func shouldWaitForZenBalance(context: ProviderFetchContext) -> Bool {
        context.requiresOptionalUsageCompleteness
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.opencodego?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let workspaceOverride = context.settings?.opencodego?.workspaceID
            ?? context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
        let cookieSource = context.settings?.opencodego?.cookieSource ?? .auto
        do {
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: true)
            let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride,
                includeZenBalance: context.includeOptionalUsage,
                waitForZenBalance: Self.shouldWaitForZenBalance(context: context))
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        } catch OpenCodeGoUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .opencodego)
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: false)
            let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride,
                includeZenBalance: context.includeOptionalUsage,
                waitForZenBalance: Self.shouldWaitForZenBalance(context: context))
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
            #else
            throw OpenCodeGoUsageError.invalidCredentials
            #endif
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        // Manual cookies include selected token accounts. Their authentication failures must be
        // surfaced instead of silently falling through to an account-agnostic local estimate.
        guard context.settings?.opencodego?.cookieSource != .manual,
              context.selectedTokenAccountID == nil
        else {
            return false
        }
        return switch error {
        case OpenCodeGoSettingsError.missingCookie,
             OpenCodeGoSettingsError.invalidCookie,
             OpenCodeGoUsageError.invalidCredentials:
            true
        default:
            false
        }
    }

    static func resolveCookieHeader(context: ProviderFetchContext, allowCached: Bool) throws -> String {
        try OpenCodeWebCookieSupport.resolveCookieHeader(
            context: OpenCodeWebCookieSupport.Context(
                settings: context.settings?.opencodego,
                provider: .opencodego,
                browserDetection: context.browserDetection,
                allowCached: allowCached),
            invalidCookie: OpenCodeGoSettingsError.invalidCookie,
            missingCookie: OpenCodeGoSettingsError.missingCookie)
    }
}

enum OpenCodeGoSettingsError: LocalizedError {
    case missingAPIKey
    case missingCookie
    case invalidCookie

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No OpenCode Go API key configured. Set OPENCODE_API_KEY or add apiKey to the CodexBar config."
        case .missingCookie:
            "No OpenCode Go session cookies found in browsers."
        case .invalidCookie:
            "OpenCode Go cookie header is invalid."
        }
    }
}
