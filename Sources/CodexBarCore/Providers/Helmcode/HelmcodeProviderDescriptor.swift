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
                    let deploymentSelection = context.config?.sanitizedRegion
                        .flatMap(HelmcodeDeploymentSelection.init(rawValue:)) ?? .auto
                    return HelmcodeProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        deploymentSelection: deploymentSelection)
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
        if HelmcodeCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }
        guard Self.automaticCookieMode(context) else { return false }
        if HelmcodeDeploymentResolver.detectTenantFromCache() != nil {
            return true
        }
        #if os(macOS)
        if Self.allowsBrowserImport(context: context) {
            return Self.hasSessionForAnyTenant(context)
        }
        #endif
        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let selection = HelmcodeDeploymentResolver.resolveSelection(
            settings: context.settings?.helmcode,
            environment: context.env)
        let transport = Self.transportOverrideForTesting

        if let override = HelmcodeCookieHeader.resolveCookieOverride(context: context) {
            let tenant = HelmcodeDeploymentResolver.tenant(
                forManualCookie: Self.rawCookieOverride(context),
                selection: selection)
            let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
                cookieHeader: override.cookieHeader,
                deployment: tenant,
                transport: transport)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: Self.sourceLabel(for: tenant))
        }
        // Automatic cookie mode only: manual and off never read or write the persisted session cache.
        guard Self.automaticCookieMode(context) else {
            throw HelmcodeUsageError.missingCookiesAny
        }

        var cachedSessionError: HelmcodeUsageError?
        var tenant = selection.pinnedDeployment
        var cachedHeader = tenant.flatMap { Self.cachedHeader(for: $0) }

        #if os(macOS)
        if tenant == nil {
            if let detected = HelmcodeDeploymentResolver.detectTenantFromCache() {
                tenant = detected
                cachedHeader = Self.cachedHeader(for: detected)
            } else if Self.allowsBrowserImport(context: context),
                      let probed = try Self.detectTenantByImport(context: context)
            {
                tenant = probed.tenant
                cachedHeader = nil
                let snapshot = try await Self.fetchImportedSessions(
                    probed.sessions,
                    deployment: probed.tenant)
                { session in
                    try await Self.fetchAndCacheSession(
                        session,
                        deployment: probed.tenant,
                        transport: transport)
                }
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: Self.sourceLabel(for: probed.tenant))
            } else {
                throw HelmcodeUsageError.missingCookiesAny
            }
        }
        #else
        if tenant == nil {
            guard let detected = HelmcodeDeploymentResolver.detectTenantFromCache() else {
                throw HelmcodeUsageError.missingCookiesAny
            }
            tenant = detected
            cachedHeader = Self.cachedHeader(for: detected)
        }
        #endif

        guard let resolvedTenant = tenant else {
            throw HelmcodeUsageError.missingCookiesAny
        }
        let scope = Self.cacheScope(resolvedTenant)
        if let cached = cachedHeader,
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            do {
                let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
                    cookieHeader: cached,
                    deployment: resolvedTenant,
                    transport: transport)
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: Self.sourceLabel(for: resolvedTenant))
            } catch let error as HelmcodeUsageError where error == .invalidSession(resolvedTenant) {
                // The persisted session was rejected: evict the scoped entry and fall through to a
                // fresh browser import when the interaction policy allows one, otherwise rethrow.
                CookieHeaderCache.clear(provider: .helmcode, scope: scope)
                cachedSessionError = error
            }
        }

        #if os(macOS)
        guard Self.allowsBrowserImport(context: context) else {
            throw cachedSessionError ?? HelmcodeUsageError.missingCookies(resolvedTenant)
        }
        let sessions = try Self.importSessions(deployment: resolvedTenant, context: context)
        let snapshot = try await Self.fetchImportedSessions(sessions, deployment: resolvedTenant) { session in
            try await Self.fetchAndCacheSession(session, deployment: resolvedTenant, transport: transport)
        }
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: Self.sourceLabel(for: resolvedTenant))
        #else
        throw cachedSessionError ?? HelmcodeUsageError.missingCookies(resolvedTenant)
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

    static func sourceLabel(for deployment: HelmcodeDeployment) -> String {
        "web · \(deployment.sourceLabelName)"
    }

    static func cachedHeader(for deployment: HelmcodeDeployment) -> String? {
        guard let header = CookieHeaderCache.load(provider: .helmcode, scope: cacheScope(deployment))?
            .cookieHeader
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !header.isEmpty
        else { return nil }
        return header
    }

    /// The pasted cookie text before normalization, so cURL captures can be host-detected.
    static func rawCookieOverride(_ context: ProviderFetchContext) -> String? {
        if context.settings?.helmcode?.cookieSource == .off {
            return nil
        }
        if context.settings?.helmcode?.cookieSource == .manual {
            return context.settings?.helmcode?.manualCookieHeader
        }
        // The reader accepts both spellings; uppercase wins so callers that export both stay consistent.
        let upper = context.env[HelmcodeSettingsReader.cookieHeaderEnvironmentKey]
        let lower = context.env[HelmcodeSettingsReader.cookieHeaderEnvironmentKey.lowercased()]
        return upper ?? lower
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

    /// Test seam for tenant detection: returns simulated sessions per tenant without touching Chrome.
    @TaskLocal static var sessionImporterOverrideForTesting:
        (@Sendable (HelmcodeDeployment) -> [HelmcodeCookieImporter.SessionInfo]?)?

    static func importSessions(
        deployment: HelmcodeDeployment,
        context: ProviderFetchContext) throws -> [HelmcodeCookieImporter.SessionInfo]
    {
        if let override = sessionImporterOverrideForTesting {
            return override(deployment) ?? []
        }
        return try HelmcodeCookieImporter.importSessions(
            deployment: deployment,
            browserDetection: context.browserDetection)
    }

    static func hasSessionForAnyTenant(_ context: ProviderFetchContext) -> Bool {
        if let override = sessionImporterOverrideForTesting {
            return HelmcodeDeployment.allCases.contains { override($0)?.isEmpty == false }
        }
        return HelmcodeDeployment.allCases.contains { deployment in
            (try? HelmcodeCookieImporter.hasSession(
                deployment: deployment,
                browserDetection: context.browserDetection)) == true
        }
    }

    /// Automatic tenant detection by probing each tenant's cookie domains in order (Helmcode Cloud
    /// first). Each tenant's cookies are only ever sent to that tenant's hosts.
    static func detectTenantByImport(
        context: ProviderFetchContext) throws
        -> (tenant: HelmcodeDeployment, sessions: [HelmcodeCookieImporter.SessionInfo])?
    {
        for deployment in HelmcodeDeployment.allCases {
            // A tenant whose import fails (suppressed browser access, no profile) simply has no
            // session for detection purposes; the next tenant is still probed.
            let sessions = (try? Self.importSessions(deployment: deployment, context: context)) ?? []
            if !sessions.isEmpty {
                return (deployment, sessions)
            }
        }
        return nil
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
                case .invalidSession, .missingCookies, .missingCookiesAny:
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
