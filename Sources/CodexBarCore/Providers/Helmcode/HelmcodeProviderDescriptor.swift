import Foundation
import SweetCookieKit

public enum HelmcodeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        usesRegion: true,
        environmentProjections: [
            .cookieHeader(HelmcodeSettingsReader.cookieHeaderEnvironmentKey, onlyWhenManual: true),
        ])

    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .helmcode,
            settingsSection: .init(
                HelmcodeProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .helmcode)
                    let deployment = context.config?.sanitizedRegion
                        .flatMap(HelmcodeDeployment.init(rawValue:)) ?? .helmcode
                    return HelmcodeProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        deployment: deployment)
                }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .helmcode,
                displayName: "Helmcode",
                sessionLabel: "Monthly",
                weeklyLabel: "Monthly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Helmcode usage",
                cliName: "helmcode",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Helmcode debug log not yet implemented",
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://cloud.helmcode.com/dashboard",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .helmcode),
                iconResourceName: "ProviderIcon-helmcode",
                color: ProviderColor(hex: 0x4934E1),
                confettiPalette: [
                    ProviderColor(hex: 0x4934E1),
                    ProviderColor(hex: 0x8B7CF6),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Helmcode per-request cost history is not available in CodexBar." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in
                    ProviderCostPresentation(menuCardStyle: .prepaidCredits)
                },
                extraRateWindowSelector: { $0.extraRateWindows ?? [] },
                menuCard: ProviderMenuCardPresentation(showsPrimaryBalanceDescription: true),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [HelmcodeWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "helmcode",
                aliases: ["helm-code"],
                versionDetector: nil))
    }
}

struct HelmcodeWebFetchStrategy: ProviderFetchStrategy {
    let id = "helmcode.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let deployment = Self.deployment(for: context)
        if HelmcodeCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }
        guard Self.automaticCookieMode(context) else { return false }
        if let cached = CookieHeaderCache.load(provider: .helmcode, scope: Self.cacheScope(deployment)),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        #if os(macOS)
        if Self.allowsBrowserImport(context: context) {
            return HelmcodeCookieImporter.hasSession(deployment: deployment, browserDetection: context.browserDetection)
        }
        #endif
        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let deployment = Self.deployment(for: context)
        if let override = HelmcodeCookieHeader.resolveCookieOverride(context: context) {
            let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
                cookieHeader: override.cookieHeader,
                deployment: deployment)
            return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
        }
        // Automatic mode only: manual and off never read or write the persisted session cache.
        guard Self.automaticCookieMode(context) else {
            throw HelmcodeUsageError.missingCookies(deployment)
        }

        let scope = Self.cacheScope(deployment)
        let transport = Self.transportOverrideForTesting
        var cachedSessionError: HelmcodeUsageError?
        if let cached = CookieHeaderCache.load(provider: .helmcode, scope: scope),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            do {
                let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
                    cookieHeader: cached.cookieHeader,
                    deployment: deployment,
                    transport: transport)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
            } catch let error as HelmcodeUsageError where error == .invalidSession(deployment) {
                // The persisted session was rejected: evict the scoped entry and fall through to a
                // fresh browser import when the interaction policy allows one, otherwise rethrow.
                CookieHeaderCache.clear(provider: .helmcode, scope: scope)
                cachedSessionError = error
            }
        }

        #if os(macOS)
        guard Self.allowsBrowserImport(context: context) else {
            throw cachedSessionError ?? HelmcodeUsageError.missingCookies(deployment)
        }
        let sessions = try HelmcodeCookieImporter.importSessions(
            deployment: deployment,
            browserDetection: context.browserDetection)
        let snapshot = try await Self.fetchImportedSessions(sessions, deployment: deployment) { session in
            try await Self.fetchAndCacheSession(session, deployment: deployment, transport: transport)
        }
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
        #else
        throw cachedSessionError ?? HelmcodeUsageError.missingCookies(deployment)
        #endif
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    /// Cache entries are scoped by deployment so a NaN Builders session is never replayed to
    /// `cloud-api.helmcode.com` and vice versa.
    static func cacheScope(_ deployment: HelmcodeDeployment) -> CookieHeaderCache.Scope {
        .providerVariant(deployment.rawValue)
    }

    static func automaticCookieMode(_ context: ProviderFetchContext) -> Bool {
        let source = context.settings?.helmcode?.cookieSource
        return source == nil || source == .auto
    }

    /// Fetches one imported session and persists the header actually sent, scoped by deployment.
    static func fetchAndCacheSession(
        _ session: HelmcodeCookieImporter.SessionInfo,
        deployment: HelmcodeDeployment,
        transport: (any ProviderHTTPTransport)?) async throws -> HelmcodeUsageSnapshot
    {
        let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
            cookies: session.cookies,
            deployment: deployment,
            transport: transport)
        if let header = HelmcodeCookieHeader.header(from: session.cookies, for: deployment.quotaURL) {
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: Self.cacheScope(deployment),
                cookieHeader: header,
                sourceLabel: session.sourceLabel)
        }
        return snapshot
    }

    @TaskLocal static var transportOverrideForTesting: (any ProviderHTTPTransport)?

    static func deployment(for context: ProviderFetchContext) -> HelmcodeDeployment {
        self.deployment(settings: context.settings?.helmcode, environment: context.env)
    }

    /// An explicit `HELMCODE_DEPLOYMENT` environment value overrides stored settings; otherwise
    /// settings decide (defaulting to the Helmcode Cloud tenant).
    static func deployment(
        settings: HelmcodeProviderSettings?,
        environment: [String: String]) -> HelmcodeDeployment
    {
        let hasEnvironmentOverride = environment[HelmcodeDeployment.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasEnvironmentOverride {
            return HelmcodeDeployment.resolve(environment: environment)
        }
        return settings?.deployment ?? .helmcode
    }

    static func allowsBrowserImport(context: ProviderFetchContext) -> Bool {
        let source = context.settings?.helmcode?.cookieSource
        return context.runtime == .app &&
            ProviderInteractionContext.current == .userInitiated &&
            (source == nil || source == .auto)
    }

    #if os(macOS)
    static func fetchImportedSessions(
        _ sessions: [HelmcodeCookieImporter.SessionInfo],
        deployment: HelmcodeDeployment,
        fetch: (HelmcodeCookieImporter.SessionInfo) async throws -> HelmcodeUsageSnapshot) async throws
        -> HelmcodeUsageSnapshot
    {
        var lastCredentialError: HelmcodeUsageError?
        for session in sessions {
            do {
                return try await fetch(session)
            } catch let error as HelmcodeUsageError {
                switch error {
                case .invalidSession, .missingCookies:
                    lastCredentialError = error
                case .rateLimited, .apiError, .parseFailed:
                    throw error
                }
            }
        }
        throw lastCredentialError ?? HelmcodeUsageError.missingCookies(deployment)
    }
    #endif
}
