import Foundation

public enum DevinProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    /// Local storage does not need Chromium Safe Storage cookie decryption.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        ChromiumLocalStorageDiscovery.defaultBrowsers
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .devin,
            settingsSection: .init(
                DevinProviderSettingsKey.self,
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .devin)
                    return DevinProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualBearerToken: settings.manualCookieHeader,
                        organization: context.config?.sanitizedWorkspaceID)
                }),
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 4),
            metadata: ProviderMetadata(
                id: .devin,
                displayName: "Devin",
                sessionLabel: "Daily",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Devin usage",
                cliName: "devin",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free",
                    "core": "Core",
                    "pro": "Pro",
                    "team": "Team",
                    "enterprise": "Enterprise",
                ],
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://app.devin.ai",
                subscriptionDashboardURL: "https://app.devin.ai/settings/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .devin),
                iconResourceName: "ProviderIcon-devin",
                color: ProviderColor(hex: 0x317CFF),
                confettiPalette: [
                    ProviderColor(hex: 0x317CFF),
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(hex: 0x46B482)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Devin cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    guard let cost = snapshot.providerCost, cost.period == "Extra usage balance" else {
                        return ProviderCostPresentation()
                    }
                    return ProviderCostPresentation(
                        showsGenericFallback: false,
                        balances: [ProviderCostPresentation.Balance(
                            label: "Extra usage",
                            amount: cost.used,
                            currencyCode: cost.currencyCode)],
                        menuCardStyle: .extraUsageBalance)
                },
                menuCard: ProviderMenuCardPresentation(costVisibilityResolver: { $0.showOptionalUsage })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [DevinWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "devin",
                versionDetector: nil,
                browserSupportExemption: { _, environment, settings in
                    #if os(Linux)
                    settings?.devin?.cookieSource == .manual &&
                        DevinUsageFetcher.manualAuth(
                            from: settings?.devin?.bearerToken(environment: environment ?? [:])) != nil
                    #else
                    false
                    #endif
                }))
    }
}

struct DevinWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "devin.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let settings = context.settings?.devin
        let source = settings?.cookieSource ?? .auto
        guard source != .off else { return false }
        if source == .manual {
            return DevinUsageFetcher.manualAuth(from: settings?.bearerToken(environment: context.env)) != nil
        }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = DevinUsageFetcher(browserDetection: context.browserDetection)
        let settings = context.settings?.devin
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.provider(.devin)).verbose(msg) }
            : nil
        let snapshot = try await fetcher.fetch(
            bearerTokenOverride: settings?.cookieSource == .manual ? settings?
                .bearerToken(environment: context.env) : nil,
            organizationOverride: Self.organizationOverride(context: context),
            timeout: context.webTimeout,
            logger: logger)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func organizationOverride(context: ProviderFetchContext) -> String? {
        context.env["DEVIN_ORGANIZATION"]
            ?? context.env["DEVIN_ORG"]
            ?? context.settings?.devin?.organization
    }
}
