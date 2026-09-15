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
        if HelmcodeCookieHeader.selectCredential(context: context) != nil {
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
        let deploymentSelection = HelmcodeDeploymentResolver.resolveSelection(
            settings: context.settings?.helmcode,
            environment: context.env)
        let transport = Self.transportOverrideForTesting
        let verbose = Self.verboseLogger(context)

        // F1: the selected credential decides both the header and its tenant, from one selection.
        if let credential = HelmcodeCookieHeader.selectCredential(context: context) {
            let tenant = HelmcodeDeploymentResolver.tenant(
                for: credential,
                deploymentSelection: deploymentSelection)
            verbose?(
                "helmcode: tenant \(tenant.sourceLabelName) " +
                    "\(Self.tenantDecisionText(credential, deploymentSelection))")
            let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
                cookieHeader: credential.cookieHeader,
                deployment: tenant,
                transport: transport,
                verbose: verbose)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: Self.sourceLabel(for: tenant))
        }
        // Automatic cookie mode only: manual and off never read or write the persisted session cache.
        guard Self.automaticCookieMode(context) else {
            throw HelmcodeUsageError.missingCookiesAny
        }

        return try await self.fetchAutomatic(
            context: context,
            deploymentSelection: deploymentSelection,
            transport: transport,
            verbose: verbose)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    /// Automatic mode builds an ordered candidate list — cached tenants (newest `storedAt` first),
    /// then, only with the user-initiated gate, imported tenants in Helmcode-Cloud-first order — and
    /// validates each: a rejection evicts that candidate's cache scope and moves on; a tenant is
    /// committed (cache stored, label published) only after a successful quota response (F3).
    private func fetchAutomatic(
        context: ProviderFetchContext,
        deploymentSelection: HelmcodeDeploymentSelection,
        transport: (any ProviderHTTPTransport)?,
        verbose: (@Sendable (String) -> Void)?) async throws -> ProviderFetchResult
    {
        let pinned = deploymentSelection.pinnedDeployment
        var lastCredentialError: HelmcodeUsageError?

        for tenant in HelmcodeDeploymentResolver.cachedTenantsByRecency()
            where pinned == nil || pinned == tenant
        {
            guard let stored = Self.cachedStoredSession(for: tenant) else { continue }
            verbose?("helmcode: candidate \(tenant.sourceLabelName) (cache)")
            // A legacy flat-header entry is not a session: treat it as a miss and clear the scope (F2).
            guard let session = stored.session else {
                verbose?("helmcode: candidate \(tenant.sourceLabelName) rejected (legacy cache entry), " +
                    "evicting cache scope, trying next")
                CookieHeaderCache.clear(provider: .helmcode, scope: Self.cacheScope(tenant))
                continue
            }
            do {
                let cookies = session.makeHTTPCookies()
                let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
                    cookies: cookies,
                    deployment: tenant,
                    transport: transport,
                    verbose: verbose)
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: Self.sourceLabel(for: tenant))
            } catch let error as HelmcodeUsageError
                where error == .invalidSession(tenant) || error == .missingCookies(tenant)
            {
                verbose?(
                    "helmcode: candidate \(tenant.sourceLabelName) rejected (invalid session), " +
                        "evicting cache scope, trying next")
                CookieHeaderCache.clear(provider: .helmcode, scope: Self.cacheScope(tenant))
                lastCredentialError = error
                continue
            }
        }

        #if os(macOS)
        if Self.allowsBrowserImport(context: context) {
            for tenant in HelmcodeDeployment.allCases
                where pinned == nil || pinned == tenant
            {
                let sessions = (try? Self.importSessions(deployment: tenant, context: context)) ?? []
                guard !sessions.isEmpty else { continue }
                verbose?("helmcode: candidate \(tenant.sourceLabelName) (import)")
                do {
                    let snapshot = try await Self.fetchImportedSessions(
                        sessions,
                        deployment: tenant)
                    { session in
                        try await Self.fetchAndCacheSession(
                            session,
                            deployment: tenant,
                            transport: transport,
                            verbose: verbose)
                    }
                    return self.makeResult(
                        usage: snapshot.toUsageSnapshot(),
                        sourceLabel: Self.sourceLabel(for: tenant))
                } catch let error as HelmcodeUsageError
                    where error == .invalidSession(tenant) || error == .missingCookies(tenant)
                {
                    verbose?("helmcode: candidate \(tenant.sourceLabelName) rejected (invalid session), trying next")
                    lastCredentialError = error
                    continue
                }
            }
        }
        #endif

        if let pinned {
            throw lastCredentialError ?? HelmcodeUsageError.missingCookies(pinned)
        }
        verbose?("helmcode: no dashboard session found for either tenant")
        // Every candidate was rejected and evicted: nothing is left pinned in the cache.
        throw HelmcodeUsageError.missingCookiesAny
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

    /// Loads and decodes a tenant's persisted session. A legacy flat-header entry decodes to nil —
    /// the caller treats that as a cache miss and clears the scope (F2).
    static func cachedStoredSession(
        for deployment: HelmcodeDeployment) -> (stored: String, session: HelmcodeCachedSession?)?
    {
        guard let entry = CookieHeaderCache.load(provider: .helmcode, scope: cacheScope(deployment)),
              !entry.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (entry.cookieHeader, HelmcodeCachedSession.decode(entry.cookieHeader))
    }

    static func verboseLogger(_ context: ProviderFetchContext) -> (@Sendable (String) -> Void)? {
        if let sink = verboseSinkForTesting {
            return sink
        }
        guard context.verbose else { return nil }
        return { @Sendable message in
            CodexBarLog.logger(LogCategories.provider(.helmcode)).verbose(message)
        }
    }

    /// Test sink for boundary diagnostics: captures the verbose lines without the logging system.
    @TaskLocal static var verboseSinkForTesting: (@Sendable (String) -> Void)?

    static func tenantDecisionText(
        _ credential: HelmcodeCredentialSelection,
        _ deploymentSelection: HelmcodeDeploymentSelection) -> String
    {
        if deploymentSelection.pinnedDeployment != nil {
            return "pinned"
        }
        return HelmcodeDeploymentResolver.detectTenant(fromCookieCapture: credential.rawCapture) == nil
            ? "defaulted from bare credential"
            : "detected from capture host"
    }

    @TaskLocal static var transportOverrideForTesting: (any ProviderHTTPTransport)?

    #if os(macOS)
    /// Fetches one imported session and persists it as cookie records (path and expiry preserved),
    /// scoped by deployment, only after a successful quota response.
    static func fetchAndCacheSession(
        _ session: HelmcodeCookieImporter.SessionInfo,
        deployment: HelmcodeDeployment,
        transport: (any ProviderHTTPTransport)?,
        verbose: (@Sendable (String) -> Void)? = nil) async throws -> HelmcodeUsageSnapshot
    {
        let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
            cookies: session.cookies,
            deployment: deployment,
            transport: transport,
            verbose: verbose)
        if let records = HelmcodeCachedSession.records(from: session.cookies, deployment: deployment),
           let encoded = records.encodedForStorage()
        {
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: Self.cacheScope(deployment),
                cookieHeader: encoded,
                sourceLabel: session.sourceLabel)
        }
        return snapshot
    }

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

    static func allowsBrowserImport(context: ProviderFetchContext) -> Bool {
        let source = context.settings?.helmcode?.cookieSource
        return context.runtime == .app &&
            ProviderInteractionContext.current == .userInitiated &&
            (source == nil || source == .auto)
    }
}
