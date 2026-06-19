import Foundation

public enum DevinProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .devin,
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
                browserCookieOrder: ProviderBrowserCookieDefaults.devinCookieImportOrder,
                dashboardURL: "https://app.devin.ai",
                subscriptionDashboardURL: "https://app.devin.ai/settings/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .devin,
                iconResourceName: "ProviderIcon-devin",
                color: ProviderColor(red: 70 / 255, green: 180 / 255, blue: 130 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Devin cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [DevinWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "devin",
                versionDetector: nil))
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
            return DevinUsageFetcher.manualAuth(from: Self.bearerTokenOverride(context: context)) != nil
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
            ? { msg in CodexBarLog.logger(LogCategories.devin).verbose(msg) }
            : nil
        let snapshot = try await fetcher.fetch(
            bearerTokenOverride: settings?.cookieSource == .manual ? Self.bearerTokenOverride(context: context) : nil,
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

    private static func bearerTokenOverride(context: ProviderFetchContext) -> String? {
        context.env["DEVIN_BEARER_TOKEN"]
            ?? context.env["DEVIN_AUTHORIZATION"]
            ?? context.settings?.devin?.manualBearerToken
    }

    private static func organizationOverride(context: ProviderFetchContext) -> String? {
        context.env["DEVIN_ORGANIZATION"]
            ?? context.env["DEVIN_ORG"]
            ?? context.settings?.devin?.organization
    }
}
