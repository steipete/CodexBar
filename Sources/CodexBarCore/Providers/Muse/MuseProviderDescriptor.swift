import Foundation
#if os(macOS)
import SweetCookieKit
#endif

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: MuseSettingsReader.apiKeyEnvironmentKeys[0],
        precedence: .environment,
        environmentHasValue: { MuseSettingsReader.apiKey(environment: $0) != nil },
        resolve: { env in MuseSettingsReader.apiKey(environment: env) },
        missingCredentialMessage: { _ in MuseUsageError.missingCredentials.errorDescription ?? "Missing Muse API key" })

    /// Prefer Chrome, then fall back to Brave. Previous Chrome-only order
    /// omitted Brave and broke users whose `dev.meta.ai` session lives in Brave
    /// (which stores cookies under `Brave Safe Storage` and requires a separate
    /// keychain prompt). Mirrors `Claude`/`Codex` which probe default order after
    /// their preferred prefix.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome, .brave]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            settingsSection: .init(
                MuseProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let s = context.cookieSettings(for: .muse)
                    return MuseProviderSettings(
                        baseURL: context.config?.sanitizedBaseURL,
                        browserSource: context.config?.museBrowserSource ?? .auto,
                        cookieSource: s.cookieSource,
                        manualCookieHeader: s.manualCookieHeader)
                }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Muse",
                shortDisplayName: "Muse",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Muse (Meta) usage",
                cliName: "muse",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://dev.meta.ai/usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .muse),
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 0.0 / 255, green: 100 / 255, blue: 224 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0064E0),
                    ProviderColor(hex: 0x0469FF),
                    ProviderColor(hex: 0x7B61FF),
                ],
                widgetColor: ProviderColor(red: 0.0 / 255, green: 100 / 255, blue: 224 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "Muse cost history is not available via API. " +
                        "Billing is pay-as-you-go at $1.25 / $4.25 per 1M tokens."
                }),
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    let style: ProviderCostMenuCardStyle = snapshot.providerCost == nil
                        ? .generic
                        : .payAsYouGoSpend
                    return ProviderCostPresentation(menuCardStyle: style)
                },
                planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    var strategies: [any ProviderFetchStrategy] = []
                    if context.sourceMode.usesWeb { strategies.append(MuseWebFetchStrategy()) }
                    strategies.append(MuseAPIFetchStrategy())
                    return strategies
                })),
            cli: ProviderCLIConfig(
                name: "muse",
                aliases: ["meta", "metamuse"],
                versionDetector: nil))
    }
}

struct MuseAPIFetchStrategy: ProviderFetchStrategy {
    let id = "muse.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        MuseSettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = MuseSettingsReader.apiKey(environment: context.env) else {
            throw MuseUsageError.missingCredentials
        }

        // Prefer config baseURL (via settings), then env, then default
        let baseURL: String? = context.settings?.muse?.baseURL ?? MuseSettingsReader.baseURL(environment: context.env)

        let usage = try await MuseUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURLString: baseURL,
            session: self.transport)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

struct MuseWebFetchStrategy: ProviderFetchStrategy {
    let id = "muse.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.sourceMode.usesWeb else { return false }
        let settings = context.settings?.muse
        if settings?.cookieSource == .off { return false }
        // If manual, require header; if auto, allow browser import attempt
        if settings?.cookieSource == .manual {
            return CookieHeaderNormalizer.normalize(settings?.manualCookieHeader) != nil
        }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Manual cookie header (Settings → Providers → Muse → Cookie source = Manual)
        if context.settings?.muse?.cookieSource == .manual {
            guard let h = CookieHeaderNormalizer.normalize(context.settings?.muse?.manualCookieHeader) else {
                throw MuseUsageError.apiError("Missing dev.meta.ai Cookie header (manual)")
            }
            let usage = try await MuseWebUsageFetcher.fetchUsage(cookieHeader: h, timeout: context.webTimeout)
            return self.makeResult(usage: usage, sourceLabel: "web")
        }

        // Automatic: try the last validated browser session, then enumerate current
        // browser profiles and cache only the first session that the usage endpoint accepts.
        if let cached = CookieHeaderCache.load(provider: UsageProvider.muse),
           let header = CookieHeaderNormalizer.normalize(cached.cookieHeader)
        {
            let dashboardURL = MuseCookieImporter.dashboardURL(
                sourceLabel: cached.sourceLabel,
                browserDetection: context.browserDetection,
                preferredBrowsers: MuseCookieImporter.preferredBrowsers(
                    for: context.settings?.muse?.browserSource ?? .auto))
            let userAgent = MuseCookieImporter.userAgent(
                sourceLabel: cached.sourceLabel,
                browserDetection: context.browserDetection,
                preferredBrowsers: MuseCookieImporter.preferredBrowsers(
                    for: context.settings?.muse?.browserSource ?? .auto))
            if let dashboardURL {
                do {
                    let usage = try await MuseWebUsageFetcher.fetchUsage(
                        cookieHeader: header,
                        timeout: context.webTimeout,
                        dashboardURL: dashboardURL,
                        userAgent: userAgent)
                    return self.makeResult(usage: usage, sourceLabel: "web")
                } catch {
                    CookieHeaderCache.clear(provider: UsageProvider.muse)
                }
            } else {
                CookieHeaderCache.clear(provider: UsageProvider.muse)
            }
        }
        #if os(macOS)
        let logger: ((String) -> Void)? = context.verbose ? { msg in CodexBarLog.logger(LogCategories.provider(
            .muse,
            scope: "web-usage")).debug(msg) } : nil
        let sessions = try MuseCookieImporter.importSessions(
            browserDetection: context.browserDetection,
            preferredBrowsers: MuseCookieImporter.preferredBrowsers(
                for: context.settings?.muse?.browserSource ?? .auto),
            logger: logger)
        var lastFetchError: Error?
        var missingRouteSource: String?
        for session in sessions {
            guard let header = CookieHeaderNormalizer.normalize(session.cookieHeader) else { continue }
            guard let dashboardURL = session.dashboardURL else {
                missingRouteSource = session.sourceLabel
                continue
            }
            do {
                let usage = try await MuseWebUsageFetcher.fetchUsage(
                    cookieHeader: header,
                    timeout: context.webTimeout,
                    dashboardURL: dashboardURL,
                    userAgent: session.userAgent)
                CookieHeaderCache.store(
                    provider: UsageProvider.muse,
                    cookieHeader: header,
                    sourceLabel: session.sourceLabel)
                return self.makeResult(usage: usage, sourceLabel: "web")
            } catch {
                lastFetchError = error
                logger?("Rejected \(session.sourceLabel): \(error.localizedDescription)")
                if Self.canUseWebViewFallback(session) {
                    do {
                        let usage = try await MuseWebViewUsageFetcher.fetchUsage(
                            session: session,
                            timeout: context.webTimeout)
                        CookieHeaderCache.store(
                            provider: UsageProvider.muse,
                            cookieHeader: header,
                            sourceLabel: session.sourceLabel)
                        logger?("Accepted \(session.sourceLabel) through the WebKit fallback")
                        return self.makeResult(usage: usage, sourceLabel: "web")
                    } catch {
                        lastFetchError = error
                        logger?("WebKit rejected \(session.sourceLabel): \(error.localizedDescription)")
                    }
                }
            }
        }
        if let lastFetchError { throw lastFetchError }
        if let missingRouteSource {
            throw MuseUsageError.apiError(
                "Open Team usage at dev.meta.ai in \(missingRouteSource), then refresh Muse again.")
        }
        #endif
        throw MuseUsageError.apiError("No dev.meta.ai session cookies found — sign in at dev.meta.ai in Chrome/Brave")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        // Web failure should fall back to API-key probe in auto mode
        context.sourceMode == .auto
    }

    private static func canUseWebViewFallback(_ session: MuseCookieImporter.SessionInfo) -> Bool {
        let names = Set(session.cookies.map { $0.name.lowercased() })
        return names.contains("llm_sess") && names.contains("ecto_1_sess")
    }
}

// MARK: - ProviderConfig extension for baseURL

extension ProviderConfig {
    public var baseURL: String? {
        get { self.extensionValue(forKey: "baseURL") }
        set { self.setExtensionValue(newValue, forKey: "baseURL") }
    }

    public var sanitizedBaseURL: String? {
        Self.clean(self.baseURL)
    }

    public var museBrowserSource: MuseBrowserSource? {
        get {
            guard let raw: String = self.extensionValue(forKey: "museBrowserSource") else { return nil }
            return MuseBrowserSource(rawValue: raw)
        }
        set { self.setExtensionValue(newValue?.rawValue, forKey: "museBrowserSource") }
    }
}
