import Foundation
import SweetCookieKit

public enum GrokProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        tokenAccountSupport: TokenAccountSupport(
            title: "SuperGrok tokens",
            subtitle:
            "Paste a SuperGrok bearer or grok.com cookie. Open token file opens ~/.grok/auth.json.",
            placeholder: "Bearer … or Cookie: …",
            injection: .environment(key: GrokSettingsReader.oauthTokenEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            environmentKeysToScrub: [GrokSettingsReader.oauthTokenEnvironmentKey],
            environmentOverride: { token in
                guard let oauth = GrokCredentialRouting.normalizedOAuthToken(token) else { return nil }
                return [GrokSettingsReader.oauthTokenEnvironmentKey: oauth]
            }),
        selectedAccountSourceModeResolver: { base, account, _ in
            guard base == .auto, let account else { return base }
            return GrokCredentialRouting.resolve(
                tokenAccountToken: account.token,
                manualCookieHeader: nil).sourceMode ?? base
        })

    /// Grok is normally signed in through Chrome; avoid touching unrelated browser keychains.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .grok,
            settingsSection: .init(
                GrokProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let cookies = context.cookieSettings(for: .grok)
                    let resolved = GrokCredentialRouting.cookieSettings(
                        configuredSource: cookies.cookieSource,
                        configuredHeader: cookies.manualCookieHeader,
                        selectedAccountToken: context.account?.token)
                    return GrokProviderSettings(
                        cookieSource: resolved.cookieSource,
                        manualCookieHeader: resolved.manualCookieHeader)
                }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .grok,
                displayName: "Grok",
                sessionLabel: "Credits",
                weeklyLabel: "On-demand",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Grok usage",
                cliName: "grok",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Grok debug log not yet implemented",
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://grok.com/?_s=usage",
                changelogURL: "https://x.ai/news",
                statusPageURL: nil,
                statusLinkURL: "https://status.x.ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .grok),
                iconResourceName: "ProviderIcon-grok",
                color: ProviderColor(red: 16 / 255, green: 163 / 255, blue: 127 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x868686),
                    ProviderColor(hex: 0xFDFDFD),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: {
                    "Grok token totals come from local ~/.grok/sessions logs. "
                        + "Subscription credits are not converted to dollars."
                }),
            pace: ProviderPaceCapability(
                resetWindowPace: .custom { window, now in
                    guard Self.primaryLabel(window: window, now: now) == "Weekly",
                          let resetsAt = window.resetsAt
                    else { return false }
                    let windowMinutes = window.windowMinutes ?? 7 * 24 * 60
                    let timeUntilReset = resetsAt.timeIntervalSince(now)
                    return windowMinutes > 0
                        && timeUntilReset > 0
                        && timeUntilReset <= TimeInterval(windowMinutes) * 60
                }),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, now in
                    ProviderRateWindowLabels(
                        primary: Self.displayLabel(window: snapshot.primary, now: now) ?? metadata.sessionLabel,
                        secondary: metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                },
                iconDecorations: [.grok]),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "grok",
                versionDetector: { _ in GrokStatusProbe.detectVersion() },
                browserSupportExemption: { _, _, _ in true }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async
        -> [any ProviderFetchStrategy]
    {
        switch context.sourceMode {
        case .auto:
            [
                GrokCLIFetchStrategy(),
                GrokOAuthFetchStrategy(mode: .proxy),
                GrokWebFetchStrategy(),
                GrokOAuthFetchStrategy(mode: .grpc),
            ]
        case .cli:
            [GrokCLIFetchStrategy()]
        case .oauth:
            [GrokOAuthFetchStrategy()]
        case .web:
            [GrokWebFetchStrategy()]
        case .api:
            []
        }
    }

    /// Returns a contextual label for Grok's primary usage bar ("Weekly" or "Monthly").
    /// Prefer the billing period duration when available; fall back to reset distance for
    /// web billing payloads that expose only a reset timestamp.
    public static func primaryLabel(window: RateWindow?, now: Date = .now) -> String? {
        if let minutes = window?.windowMinutes {
            return self.primaryLabel(duration: TimeInterval(minutes) * 60)
        }
        return self.primaryLabel(resetsAt: window?.resetsAt, now: now)
    }

    public static func primaryLabel(resetsAt: Date?, now: Date = .now) -> String? {
        guard let resetsAt else { return nil }
        return self.primaryLabel(duration: resetsAt.timeIntervalSince(now))
    }

    /// Grok's current untyped credits surface is the weekly credit pool (#2929). Keep explicit
    /// durations authoritative, but do not lose the weekly label near the end of an untyped window.
    public static func displayLabel(window: RateWindow?, now: Date = .now) -> String? {
        guard let window else { return nil }
        if let label = self.primaryLabel(window: window, now: now) {
            return label
        }
        guard window.windowMinutes == nil, window.resetsAt != nil else { return nil }
        return "Weekly"
    }

    private static func primaryLabel(duration seconds: TimeInterval) -> String? {
        guard seconds > 3600 else { return nil }
        let days = Int((seconds / 86400).rounded(.toNearestOrAwayFromZero))
        if (4...12).contains(days) {
            return "Weekly"
        }
        if (20...45).contains(days) {
            return "Monthly"
        }
        return nil
    }
}

struct GrokCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "grok.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveGrokBinary(env: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GrokStatusProbe()
        let snap = try await probe.fetch(env: context.env)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "grok-cli",
            diagnostic: snap.diagnostic)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

struct GrokOAuthFetchStrategy: ProviderFetchStrategy {
    enum Mode: Sendable {
        case proxyThenGrpc
        case proxy
        case grpc
    }

    let mode: Mode
    let kind: ProviderFetchKind = .oauth

    init(mode: Mode = .proxyThenGrpc) {
        self.mode = mode
    }

    var id: String {
        switch self.mode {
        case .proxyThenGrpc, .proxy: "grok.oauth"
        case .grpc: "grok.oauth-grpc"
        }
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        GrokSettingsReader.resolvedCredentials(environment: context.env) != nil
            || FileManager.default.fileExists(
                atPath: GrokCredentialsStore.authFileURL(env: context.env).path)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try await GrokWebFetchStrategy().fetch(context) {
            let credentials = try GrokWebFetchStrategy.resolvedCredentialsResult(context: context).get()
            guard !credentials.isExpired else {
                throw GrokWebBillingError.missingCredentials
            }
            switch self.mode {
            case .grpc:
                let snapshot = try await GrokWebBillingFetcher.fetch(credentials: credentials)
                return (snapshot, "grok-web", true)
            case .proxy:
                let snapshot = try await GrokCreditsProxyFetcher.fetch(credentials: credentials)
                return (snapshot, "grok-cli-proxy", true)
            case .proxyThenGrpc:
                do {
                    let snapshot = try await GrokCreditsProxyFetcher.fetch(credentials: credentials)
                    return (snapshot, "grok-cli-proxy", true)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw error
                } catch {
                    let snapshot = try await GrokWebBillingFetcher.fetch(credentials: credentials)
                    return (snapshot, "grok-web", true)
                }
            }
        }
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

struct GrokWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "grok.web"
    let kind: ProviderFetchKind = .web
    typealias ProxyBillingFetch = @Sendable (GrokCredentials) async throws -> GrokWebBillingSnapshot
    typealias WebBillingFetch =
        @Sendable () async throws -> (
            snapshot: GrokWebBillingSnapshot,
            sourceLabel: String,
            authenticatedByAuthFile: Bool)
    typealias SettingsTierFetch = @Sendable (GrokCredentials?) async throws -> String?

    /// Browser-cookie import must stay limited to surfaces where a person explicitly asked for it:
    /// the menu-bar app runtime, a `userInitiated` interaction (set only by explicit refresh
    /// commands and app UI gestures), or the environment override. Scheduled and background work
    /// must keep the default `.background` context so it can never reach Chromium Keychain prompts.
    static func canImportBrowserCookies(runtime: ProviderRuntime, env: [String: String]) -> Bool {
        runtime == .app || ProviderInteractionContext.current == .userInitiated
            || env["CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT"] == "1"
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let cookieSource = context.settings?.grok?.cookieSource ?? .auto
        if cookieSource != .off,
           GrokCredentialRouting.normalizedWebCookie(
               context.settings?.grok?.manualCookieHeader) != nil
        {
            return true
        }
        #if os(macOS)
        if cookieSource == .auto, CookieHeaderCache.load(provider: .grok) != nil {
            return true
        }
        if cookieSource == .auto,
           Self.canImportBrowserCookies(runtime: context.runtime, env: context.env),
           GrokCookieImporter.hasSession(browserDetection: context.browserDetection)
        {
            return true
        }
        #endif
        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try await self.fetch(
            context,
            webBilling: { [self] in
                try await self.fetchWebBilling(context: context)
            })
    }

    func fetch(
        _ context: ProviderFetchContext,
        webBilling fetchWebBilling: @escaping WebBillingFetch,
        settingsTier loadSettingsTier: SettingsTierFetch? = nil) async throws -> ProviderFetchResult
    {
        let authCredentials = GrokSettingsReader.resolvedCredentials(environment: context.env).flatMap { credentials in
            credentials.isExpired ? nil : credentials
        }
        let resolveSettingsTier =
            loadSettingsTier ?? { credentials in
                try await GrokStatusProbe.loadSettingsTier(credentials: credentials)
            }

        let webBilling: GrokWebBillingSnapshot
        let sourceLabel: String
        let authenticatedByAuthFile: Bool
        do {
            (webBilling, sourceLabel, authenticatedByAuthFile) = try await fetchWebBilling()
        } catch GrokWebBillingError.teamUsageUnsupported {
            guard let authState = authCredentials, authState.isTeamPrincipal else {
                throw GrokWebBillingError.teamUsageUnsupported
            }
            let subscriptionTier = try await resolveSettingsTier(authState)
            let identitySnapshot = GrokStatusProbe.identityOnlySnapshot(
                credentials: authState,
                localSummary: GrokLocalSessionScanner.summarize(env: context.env),
                cliVersion: GrokStatusProbe.detectVersion(env: context.env),
                subscriptionTier: subscriptionTier)
            return self.makeResult(
                usage: identitySnapshot.toUsageSnapshot(),
                sourceLabel: "grok-web",
                diagnostic: identitySnapshot.diagnostic)
        }
        let credentials = Self.credentialsForWebBillingSnapshot(
            credentials: GrokSettingsReader.resolvedCredentials(environment: context.env),
            authenticatedByAuthFile: authenticatedByAuthFile)
        // Cookie/gRPC fallback is a different browser session. Never attach the
        // auth.json account's settings tier onto that usage.
        let subscriptionTier: String? =
            if authenticatedByAuthFile {
                try await resolveSettingsTier(authCredentials)
            } else {
                nil
            }
        let enrichedBilling = webBilling.applying(subscriptionTier: subscriptionTier)
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: enrichedBilling,
            credentials: GrokStatusProbe.credentialsForSnapshot(
                credentials: credentials,
                billing: nil,
                webBilling: enrichedBilling),
            localSummary: GrokLocalSessionScanner.summarize(env: context.env),
            cliVersion: GrokStatusProbe.detectVersion(env: context.env),
            updatedAt: Date(),
            subscriptionTier: subscriptionTier ?? enrichedBilling.subscriptionTier)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: sourceLabel)
    }

    func fetchWebBilling(
        context: ProviderFetchContext,
        proxyBilling: ProxyBillingFetch = { try await GrokCreditsProxyFetcher.fetch(credentials: $0) }) async throws
        -> (
            snapshot: GrokWebBillingSnapshot,
            sourceLabel: String,
            authenticatedByAuthFile: Bool)
    {
        try await self.fetchLegacyWebBilling(
            context: context,
            browserCredentials: nil)
    }

    static func fetchProxyFirst(
        credentials: GrokCredentials?,
        proxyBilling: ProxyBillingFetch,
        legacyBilling: () async throws -> (
            snapshot: GrokWebBillingSnapshot,
            sourceLabel: String,
            authenticatedByAuthFile: Bool)) async throws -> (
        snapshot: GrokWebBillingSnapshot,
        sourceLabel: String,
        authenticatedByAuthFile: Bool)
    {
        if let credentials, !credentials.isExpired {
            do {
                let snapshot = try await proxyBilling(credentials)
                return (snapshot, "grok-cli-proxy", true)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                // The legacy cookie and bearer paths remain available when the CLI proxy fails.
            }
        }
        return try await legacyBilling()
    }

    private func fetchLegacyWebBilling(
        context: ProviderFetchContext,
        browserCredentials: GrokCredentials?) async throws -> (
        snapshot: GrokWebBillingSnapshot,
        sourceLabel: String,
        authenticatedByAuthFile: Bool)
    {
        let cookieSettings = context.settings?.grok
        let cookieSource = cookieSettings?.cookieSource ?? .auto
        let manualHeader = GrokCredentialRouting.normalizedWebCookie(cookieSettings?.manualCookieHeader)
        var lastCookieError: Error?

        if cookieSource != .off,
           let manualHeader, !manualHeader.isEmpty
        {
            do {
                let snapshot = try await GrokWebBillingFetcher.fetch(
                    cookieHeader: manualHeader,
                    credentials: browserCredentials)
                return (snapshot, "manual-cookie", false)
            } catch {
                lastCookieError = error
                if cookieSource == .manual {
                    throw error
                }
            }
        }

        #if os(macOS)
        var cacheObservation = CookieHeaderCache.observeForConditionalMutation(provider: .grok)
        if cookieSource == .auto, let cached = cacheObservation.entry {
            do {
                let snapshot = try await Self.fetchValidCookieHeader(
                    cached.cookieHeader,
                    credentials: browserCredentials,
                    preferTrailingAuthenticationFailure: true)
                return (snapshot, cached.sourceLabel, false)
            } catch {
                guard Self.isCookieAuthenticationFailure(error) else { throw error }
                if CookieHeaderCache.clearIfCurrent(provider: .grok, expected: cached) {
                    cacheObservation = cacheObservation.afterOwnedClear()
                }
                lastCookieError = error
            }
        }

        if cookieSource == .auto,
           Self.canImportBrowserCookies(runtime: context.runtime, env: context.env)
        {
            do {
                let sessions = try GrokCookieImporter.importSessions(
                    browserDetection: context.browserDetection)
                let (snapshot, sourceLabel) = try await Self.fetchFirstValidCookieSession(
                    sessions,
                    credentials: browserCredentials,
                    cacheObservation: cacheObservation)
                return (snapshot, sourceLabel, false)
            } catch {
                lastCookieError = error
            }
            throw lastCookieError ?? GrokWebBillingError.missingCredentials
        }
        #endif

        throw lastCookieError ?? GrokWebBillingError.missingCredentials
    }

    static func resolvedCredentialsResult(context: ProviderFetchContext) -> Result<
        GrokCredentials, Error,
    > {
        if let credentials = GrokSettingsReader.resolvedCredentials(environment: context.env) {
            return .success(credentials)
        }
        return Result {
            try GrokCredentialsStore.load(env: context.env)
        }
    }

    static func credentialsForWebBillingSnapshot(
        credentials: GrokCredentials?,
        authenticatedByAuthFile: Bool) -> GrokCredentials?
    {
        authenticatedByAuthFile ? credentials : nil
    }

    #if os(macOS)
    static func fetchFirstValidCookieSession(
        _ sessions: [GrokCookieImporter.SessionInfo],
        credentials: GrokCredentials? = nil,
        cacheObservation: CookieHeaderCache.ConditionalMutationObservation? = nil,
        fetch: ((String, GrokCredentials?) async throws -> GrokWebBillingSnapshot)? = nil) async throws
        -> (GrokWebBillingSnapshot, String)
    {
        let fetchSnapshot =
            fetch ?? { cookieHeader, credentials in
                try await GrokWebBillingFetcher.fetch(
                    cookieHeader: cookieHeader,
                    credentials: credentials)
            }
        var lastError: Error?
        var teamUsageUnsupportedError: Error?
        for session in sessions {
            do {
                let snapshot = try await Self.fetchValidCookieHeader(
                    session.cookieHeader,
                    credentials: credentials,
                    fetch: fetchSnapshot)
                if let cacheObservation {
                    CookieHeaderCache.storeIfObservationCurrent(
                        provider: .grok,
                        expected: cacheObservation,
                        cookieHeader: session.cookieHeader,
                        sourceLabel: session.sourceLabel)
                }
                return (snapshot, session.sourceLabel)
            } catch {
                if case GrokWebBillingError.teamUsageUnsupported = error {
                    teamUsageUnsupportedError = error
                }
                lastError = error
            }
        }
        throw teamUsageUnsupportedError ?? lastError ?? GrokWebBillingError.missingCredentials
    }

    /// `preferTrailingAuthenticationFailure` lets a cached-cookie caller surface a trailing
    /// 401/403 over the team classification so stale sessions still trigger cache eviction.
    /// Non-authentication trailing errors keep `teamUsageUnsupported` so team principals
    /// degrade to identity-only data instead of failing outright.
    static func fetchValidCookieHeader(
        _ cookieHeader: String,
        credentials: GrokCredentials? = nil,
        preferTrailingAuthenticationFailure: Bool = false,
        fetch: ((String, GrokCredentials?) async throws -> GrokWebBillingSnapshot)? = nil) async throws
        -> GrokWebBillingSnapshot
    {
        let fetchSnapshot =
            fetch ?? { cookieHeader, credentials in
                try await GrokWebBillingFetcher.fetch(
                    cookieHeader: cookieHeader,
                    credentials: credentials)
            }
        var lastError: Error?
        var teamUsageUnsupportedError: Error?
        for authCredentials in Self.cookieAuthAttempts(credentials: credentials) {
            do {
                return try await fetchSnapshot(cookieHeader, authCredentials)
            } catch {
                if case GrokWebBillingError.teamUsageUnsupported = error {
                    teamUsageUnsupportedError = error
                }
                lastError = error
            }
        }
        if let teamUsageUnsupportedError {
            let trailingAuthenticationFailure =
                preferTrailingAuthenticationFailure
                    && lastError.map(Self.isCookieAuthenticationFailure) == true
            if !trailingAuthenticationFailure {
                throw teamUsageUnsupportedError
            }
        }
        throw lastError ?? GrokWebBillingError.missingCredentials
    }

    static func cookieAuthAttempts(credentials: GrokCredentials?) -> [GrokCredentials?] {
        guard let credentials, !credentials.isExpired else { return [nil] }
        return [credentials, nil]
    }

    static func isCookieAuthenticationFailure(_ error: Error) -> Bool {
        guard let error = error as? GrokWebBillingError else { return false }
        switch error {
        case let .requestFailed(status, _):
            return status == 401 || status == 403
        case let .rpcFailed(status, message):
            return GrokWebBillingError.isAuthenticationFailure(status: status, message: message)
        case .missingCredentials, .emptyResponse, .invalidResponse, .teamUsageUnsupported, .parseFailed:
            return false
        }
    }
    #endif

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}
