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
            presentation: ProviderUsagePresentation(rateWindowLabeler: { metadata, snapshot, now in
                ProviderRateWindowLabels(
                    primary: Self.displayLabel(window: snapshot.primary, now: now) ?? metadata.sessionLabel,
                    secondary: metadata.weeklyLabel,
                    tertiary: metadata.opusLabel ?? "Sonnet",
                    showsTertiary: metadata.supportsOpus)
            }),
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
        let resetLookup = Self.remainingResetLookup(
            snapshot: snap,
            includeOptionalUsage: context.includeOptionalUsage)
        return await self.makeUsageResult(
            snapshot: snap,
            context: context,
            resetLookup: resetLookup)
    }

    func makeUsageResult(
        snapshot: GrokUsageSnapshot,
        context: ProviderFetchContext,
        resetLookup: GrokRemainingResetsLookupResult) async -> ProviderFetchResult
    {
        let usage = snapshot.toUsageSnapshot()
        let resetResolution = await resetLookup.resolved(
            at: snapshot.updatedAt,
            requiresCompleteness: context.requiresOptionalUsageCompleteness)
        return self.makeResult(
            usage: usage
                .withGrokResetCredits(resetResolution.snapshot)
                .replacing(details: .value(
                    GrokRemainingResetsFetcher.detailSections(
                        snapshot: resetResolution.snapshot,
                        now: snapshot.updatedAt))),
            sourceLabel: "grok-cli",
            supplementalUsageTask: resetResolution.supplementalUsageTask,
            diagnostic: snapshot.diagnostic)
    }

    static func remainingResetTokens(
        snapshot: GrokUsageSnapshot,
        includeOptionalUsage: Bool,
        lookup: GrokRemainingResetsLookup = { credentials, cookieHeader, now in
            GrokRemainingResetsFetcher.cachedLookupAndRefresh(
                credentials: credentials,
                cookieHeader: cookieHeader,
                now: now)
        }) -> [GrokRemainingReset]
    {
        self.remainingResetLookup(
            snapshot: snapshot,
            includeOptionalUsage: includeOptionalUsage,
            lookup: lookup).tokens
    }

    static func remainingResetLookup(
        snapshot: GrokUsageSnapshot,
        includeOptionalUsage: Bool,
        lookup: GrokRemainingResetsLookup = { credentials, cookieHeader, now in
            GrokRemainingResetsFetcher.cachedLookupAndRefresh(
                credentials: credentials,
                cookieHeader: cookieHeader,
                now: now)
        }) -> GrokRemainingResetsLookupResult
    {
        guard includeOptionalUsage else { return .empty }
        return lookup(snapshot.credentials, nil, snapshot.updatedAt)
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

enum GrokWebBillingAuthContext: Sendable {
    case oauth(GrokCredentials)
    case cookie(String)

    var credentials: GrokCredentials? {
        guard case let .oauth(credentials) = self else { return nil }
        return credentials
    }

    var cookieHeader: String? {
        guard case let .cookie(cookieHeader) = self else { return nil }
        return cookieHeader
    }
}

struct GrokWebBillingResult: Sendable {
    let snapshot: GrokWebBillingSnapshot
    let sourceLabel: String
    let authContext: GrokWebBillingAuthContext
}

struct GrokOAuthFetchStrategy: ProviderFetchStrategy {
    enum Mode: Sendable {
        case proxyThenGrpc
        case proxy
        case grpc
    }

    let mode: Mode
    let kind: ProviderFetchKind = .oauth
    let proxyBilling: GrokWebFetchStrategy.ProxyBillingFetch
    let grpcBilling: GrokWebFetchStrategy.ProxyBillingFetch
    let webStrategy: GrokWebFetchStrategy
    let settingsTier: GrokWebFetchStrategy.SettingsTierFetch?

    init(
        mode: Mode = .proxyThenGrpc,
        proxyBilling: @escaping GrokWebFetchStrategy.ProxyBillingFetch = {
            try await GrokCreditsProxyFetcher.fetch(credentials: $0)
        },
        grpcBilling: @escaping GrokWebFetchStrategy.ProxyBillingFetch = {
            try await GrokWebBillingFetcher.fetch(credentials: $0)
        },
        webStrategy: GrokWebFetchStrategy = .init(),
        settingsTier: GrokWebFetchStrategy.SettingsTierFetch? = nil)
    {
        self.mode = mode
        self.proxyBilling = proxyBilling
        self.grpcBilling = grpcBilling
        self.webStrategy = webStrategy
        self.settingsTier = settingsTier
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
        try await self.webStrategy.fetch(context) { capturedCredentials in
            let credentials = try capturedCredentials.get()
            guard !credentials.isExpired else {
                throw GrokWebBillingError.missingCredentials
            }
            switch self.mode {
            case .grpc:
                let snapshot = try await self.grpcBilling(credentials)
                return GrokWebBillingResult(
                    snapshot: snapshot,
                    sourceLabel: "grok-web",
                    authContext: .oauth(credentials))
            case .proxy:
                let snapshot = try await self.proxyBilling(credentials)
                return try await Self.resolvingUnknownUsage(
                    snapshot, credentials: credentials, grpcBilling: self.grpcBilling)
            case .proxyThenGrpc:
                do {
                    let snapshot = try await self.proxyBilling(credentials)
                    return try await Self.resolvingUnknownUsage(
                        snapshot, credentials: credentials, grpcBilling: self.grpcBilling)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw error
                } catch {
                    let snapshot = try await self.grpcBilling(credentials)
                    return GrokWebBillingResult(
                        snapshot: snapshot,
                        sourceLabel: "grok-web",
                        authContext: .oauth(credentials))
                }
            }
        } settingsTier: { credentials in
            if let settingsTier = self.settingsTier {
                return try await settingsTier(credentials)
            }
            return try await GrokStatusProbe.loadSettingsTier(credentials: credentials)
        }
    }

    /// A credits payload that carries a billing period but no usage value is a successful
    /// response with unknown usage (#3157), and an unknown percent produces no rate window at
    /// all. Plans whose credits payload never publishes `creditUsagePercent` would therefore
    /// lose the usage bar entirely, so ask the grok.com bearer surface before that empty answer
    /// ends the fetch. This stays on the auth-file token: no browser cookie import is involved.
    /// grok.com remains best-effort — when it also has no percent, the proxy's period and plan
    /// metadata are kept with usage still unknown.
    ///
    /// Only published percentages and parser-validated implicit zeroes can enrich the proxy.
    /// A bare inferred zero is insufficient: the parser must validate an active current period.
    /// The short deadline keeps a grok.com outage from delaying already-valid proxy metadata.
    static let unknownUsageEnrichmentBudget: Duration = .seconds(6)

    static func resolvingUnknownUsage(
        _ proxySnapshot: GrokWebBillingSnapshot,
        credentials: GrokCredentials,
        budget: Duration = GrokOAuthFetchStrategy.unknownUsageEnrichmentBudget,
        grpcBilling: @escaping GrokWebFetchStrategy.ProxyBillingFetch = {
            try await GrokWebBillingFetcher.fetch(credentials: $0)
        }) async throws -> GrokWebBillingResult
    {
        guard proxySnapshot.usedPercent == nil else {
            return GrokWebBillingResult(
                snapshot: proxySnapshot,
                sourceLabel: "grok-cli-proxy",
                authContext: .oauth(credentials))
        }
        let proxyAnswer = GrokWebBillingResult(
            snapshot: proxySnapshot,
            sourceLabel: "grok-cli-proxy",
            authContext: .oauth(credentials))
        let join = BoundedTaskJoin(sourceTask: Task { try await grpcBilling(credentials) })
        switch await join.value(joinGrace: budget) {
        case let .value(grpcSnapshot):
            guard let percent = grpcSnapshot.usedPercent,
                  grpcSnapshot.usedPercentIsWirePublished || (percent == 0 && grpcSnapshot.usedPercentIsImplicitZero)
            else {
                return proxyAnswer
            }
            return GrokWebBillingResult(
                snapshot: grpcSnapshot.completing(with: proxySnapshot),
                sourceLabel: "grok-web",
                authContext: .oauth(credentials))
        case .timedOut:
            return proxyAnswer
        case let .failure(error):
            if error is CancellationError {
                throw CancellationError()
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw urlError
            }
            return proxyAnswer
        }
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

struct GrokWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "grok.web"
    let kind: ProviderFetchKind = .web
    var loadCredentials: @Sendable (ProviderFetchContext) -> Result<GrokCredentials, Error> = {
        Self.resolvedCredentialsResult(context: $0)
    }

    var localSummary: @Sendable ([String: String]) async throws -> GrokLocalSessionSummary? = {
        try await GrokLocalSessionScanner.summarizeOffMainThread(env: $0)
    }

    var cliVersion: @Sendable ([String: String]) -> String? = { GrokStatusProbe.detectVersion(env: $0) }
    typealias ProxyBillingFetch = @Sendable (GrokCredentials) async throws -> GrokWebBillingSnapshot
    typealias WebBillingFetch =
        @Sendable (Result<GrokCredentials, Error>) async throws -> GrokWebBillingResult
    typealias SettingsTierFetch = @Sendable (GrokCredentials?) async throws -> String?
    static let defaultRemainingResetsLookup: GrokRemainingResetsLookup = { credentials, cookieHeader, now in
        GrokRemainingResetsFetcher.cachedLookupAndRefresh(
            credentials: credentials,
            cookieHeader: cookieHeader,
            now: now)
    }

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
            webBilling: { [self] _ in
                try await self.fetchWebBilling(context: context)
            })
    }

    func fetch(
        _ context: ProviderFetchContext,
        webBilling fetchWebBilling: @escaping WebBillingFetch,
        settingsTier loadSettingsTier: SettingsTierFetch? = nil,
        remainingResets lookupRemainingResets: @escaping GrokRemainingResetsLookup =
            Self.defaultRemainingResetsLookup) async throws -> ProviderFetchResult
    {
        // Billing and enrichment share one capture even if `grok login` replaces auth.json during an await.
        let capturedCredentials = self.loadCredentials(context)
        let authCredentials = (try? capturedCredentials.get()).flatMap { credentials in
            credentials.isExpired ? nil : credentials
        }
        let resolveSettingsTier =
            loadSettingsTier ?? { credentials in
                try await GrokStatusProbe.loadSettingsTier(credentials: credentials)
            }

        let billingResult: GrokWebBillingResult
        do {
            billingResult = try await fetchWebBilling(capturedCredentials)
        } catch GrokWebBillingError.teamUsageUnsupported {
            guard let authState = authCredentials, authState.isTeamPrincipal else {
                throw GrokWebBillingError.teamUsageUnsupported
            }
            let subscriptionTier = try await resolveSettingsTier(authState)
            let identitySnapshot = try await GrokStatusProbe.identityOnlySnapshot(
                credentials: authState,
                localSummary: self.localSummary(context.env),
                cliVersion: self.cliVersion(context.env),
                subscriptionTier: subscriptionTier)
            return self.makeResult(
                usage: identitySnapshot.toUsageSnapshot(),
                sourceLabel: "grok-web",
                diagnostic: identitySnapshot.diagnostic)
        }
        let webBilling = billingResult.snapshot
        let credentials = billingResult.authContext.credentials
        // Cookie billing is a different browser session. Never attach the
        // auth.json account's settings tier onto that usage.
        let subscriptionTier: String? =
            if let credentials {
                try await resolveSettingsTier(credentials)
            } else {
                nil
            }
        let enrichedBilling = webBilling.applying(subscriptionTier: subscriptionTier)
        let snapshot = try await GrokUsageSnapshot(
            billing: nil,
            webBilling: enrichedBilling,
            credentials: GrokStatusProbe.credentialsForSnapshot(
                credentials: credentials,
                billing: nil,
                webBilling: enrichedBilling),
            localSummary: self.localSummary(context.env),
            cliVersion: self.cliVersion(context.env),
            updatedAt: Date(),
            subscriptionTier: subscriptionTier ?? enrichedBilling.subscriptionTier)
        let usage = snapshot.toUsageSnapshot()
        let resetLookup = context.includeOptionalUsage
            ? lookupRemainingResets(
                billingResult.authContext.credentials,
                billingResult.authContext.cookieHeader,
                snapshot.updatedAt)
            : .empty
        let resetResolution = await resetLookup.resolved(
            at: snapshot.updatedAt,
            requiresCompleteness: context.requiresOptionalUsageCompleteness)
        return self.makeResult(
            usage: usage
                .withGrokResetCredits(resetResolution.snapshot)
                .replacing(details: .value(
                    GrokRemainingResetsFetcher.detailSections(
                        snapshot: resetResolution.snapshot,
                        now: snapshot.updatedAt))),
            sourceLabel: billingResult.sourceLabel,
            supplementalUsageTask: resetResolution.supplementalUsageTask,
            diagnostic: enrichedBilling.usedPercent == nil ? GrokStatusProbe.usageUnavailableMessage : nil)
    }

    func fetchWebBilling(
        context: ProviderFetchContext,
        proxyBilling: ProxyBillingFetch = { try await GrokCreditsProxyFetcher.fetch(credentials: $0) }) async throws
        -> GrokWebBillingResult
    {
        try await self.fetchLegacyWebBilling(
            context: context,
            browserCredentials: nil)
    }

    static func fetchProxyFirst(
        credentials: GrokCredentials?,
        proxyBilling: ProxyBillingFetch,
        legacyBilling: () async throws -> GrokWebBillingResult) async throws -> GrokWebBillingResult
    {
        if let credentials, !credentials.isExpired {
            do {
                let snapshot = try await proxyBilling(credentials)
                return GrokWebBillingResult(
                    snapshot: snapshot,
                    sourceLabel: "grok-cli-proxy",
                    authContext: .oauth(credentials))
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
        browserCredentials: GrokCredentials?) async throws -> GrokWebBillingResult
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
                return GrokWebBillingResult(
                    snapshot: snapshot,
                    sourceLabel: "manual-cookie",
                    authContext: .cookie(manualHeader))
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
                return GrokWebBillingResult(
                    snapshot: snapshot,
                    sourceLabel: cached.sourceLabel,
                    authContext: .cookie(cached.cookieHeader))
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
                let (snapshot, sourceLabel, cookieHeader) = try await Self.fetchFirstValidCookieSession(
                    sessions,
                    credentials: browserCredentials,
                    cacheObservation: cacheObservation)
                return GrokWebBillingResult(
                    snapshot: snapshot,
                    sourceLabel: sourceLabel,
                    authContext: .cookie(cookieHeader))
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
        if let credentials = GrokSettingsReader.pastedCredentials(environment: context.env) {
            return .success(credentials)
        }
        return Result {
            try GrokCredentialsStore.load(env: context.env)
        }
    }

    #if os(macOS)
    static func fetchFirstValidCookieSession(
        _ sessions: [GrokCookieImporter.SessionInfo],
        credentials: GrokCredentials? = nil,
        cacheObservation: CookieHeaderCache.ConditionalMutationObservation? = nil,
        fetch: ((String, GrokCredentials?) async throws -> GrokWebBillingSnapshot)? = nil) async throws
        -> (GrokWebBillingSnapshot, String, String)
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
                return (snapshot, session.sourceLabel, session.cookieHeader)
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
