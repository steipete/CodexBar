import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: MuseSettingsReader.apiKeyEnvironmentKeys[0],
        precedence: .environment,
        environmentHasValue: { MuseSettingsReader.apiKey(environment: $0) != nil },
        resolve: { env in MuseSettingsReader.apiKey(environment: env) },
        missingCredentialMessage: { _ in MuseUsageError.missingCredentials.errorDescription ?? "Missing Muse API key" })

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
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
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

        // Automatic: try cached header, then fresh browser import for dev.meta.ai
        if let cached = CookieHeaderCache.load(provider: UsageProvider.muse),
           let header = CookieHeaderNormalizer.normalize(cached.cookieHeader)
        {
            do {
                let usage = try await MuseWebUsageFetcher.fetchUsage(cookieHeader: header, timeout: context.webTimeout)
                return self.makeResult(usage: usage, sourceLabel: "web")
            } catch {
                CookieHeaderCache.clear(provider: UsageProvider.muse)
            }
        }
        #if os(macOS)
        do {
            let logger: ((String) -> Void)? = context.verbose ? { msg in CodexBarLog.logger(LogCategories.provider(
                .muse,
                scope: "web-usage")).verbose(msg) } : nil
            if let session = try MuseCookieImporter.importCookieHeader(
                browserDetection: context.browserDetection,
                logger: logger),
                let header = CookieHeaderNormalizer.normalize(session.cookieHeader)
            {
                CookieHeaderCache.store(
                    provider: UsageProvider.muse,
                    cookieHeader: header,
                    sourceLabel: session.sourceLabel)
                let usage = try await MuseWebUsageFetcher.fetchUsage(cookieHeader: header, timeout: context.webTimeout)
                return self.makeResult(usage: usage, sourceLabel: "web")
            }
        } catch {}
        #endif
        throw MuseUsageError.apiError("No dev.meta.ai session cookies found — sign in at dev.meta.ai in Chrome/Safari")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        // Web failure should fall back to API-key probe in auto mode
        context.sourceMode == .auto
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
}
