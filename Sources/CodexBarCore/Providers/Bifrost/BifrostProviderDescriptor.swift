import Foundation

public enum BifrostProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: BifrostSettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.enterpriseHost(BifrostSettingsReader.baseURLEnvironmentKey)],
        resolve: BifrostSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "Virtual keys",
            subtitle: "Store multiple Bifrost virtual keys.",
            placeholder: "Paste Bifrost virtual key…",
            injection: .environment(key: BifrostSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .bifrost,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .bifrost,
                displayName: "Bifrost",
                sessionLabel: "Budget",
                weeklyLabel: "Secondary budget",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Reads governance budgets and rate limits from the Bifrost virtual key quota endpoint.",
                toggleTitle: "Show Bifrost usage",
                cliName: "bifrost",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Bifrost debug log not yet implemented",
                usesDetailBackedWindow: true,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .bifrost),
                iconResourceName: "ProviderIcon-bifrost",
                color: ProviderColor(hex: 0x33C09E),
                confettiPalette: [
                    ProviderColor(hex: 0x33C09E),
                    ProviderColor(hex: 0x1F7A63),
                    ProviderColor(hex: 0x8FE0C7),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Bifrost spend is reported by the provider API." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                        ? .apiSpend
                        : .hidden
                    return ProviderCostPresentation(menuCardStyle: style)
                },
                menuBarWindowResolver: { context in
                    guard context.metric == .automatic else { return .unhandled }
                    return .resolved(
                        ProviderUsagePresentation.exhausted(context.snapshot.primary, context.snapshot.secondary)
                            ?? context.snapshot.secondary
                            ?? context.snapshot.primary)
                },
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    showsSecondaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true },
                    secondaryDescriptionMode: .detailWhenResetDatePresent)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [BifrostAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "bifrost",
                aliases: [],
                versionDetector: nil))
    }
}

struct BifrostAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "bifrost.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ProviderTokenResolver.token(for: .bifrost, environment: context.env) != nil &&
            BifrostSettingsReader.hasBaseURLOverride(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.token(for: .bifrost, environment: context.env) else {
            throw BifrostUsageError.missingCredentials
        }
        guard let baseURL = BifrostSettingsReader.baseURL(environment: context.env) else {
            // Distinguish "never configured" from "configured but rejected" so the user sees
            // which one applies instead of the provider silently going unavailable.
            throw BifrostSettingsReader.hasBaseURLOverride(environment: context.env)
                ? BifrostUsageError.invalidEndpointOverride(BifrostSettingsReader.baseURLEnvironmentKey)
                : BifrostUsageError.missingBaseURL
        }
        let usage = try await BifrostUsageFetcher.fetchUsage(
            apiKey: apiKey,
            baseURL: baseURL)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
