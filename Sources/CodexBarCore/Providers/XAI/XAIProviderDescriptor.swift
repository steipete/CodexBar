import Foundation

public enum XAIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: XAISettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.workspaceID(XAISettingsReader.teamIDEnvironmentKey)],
        resolve: XAISettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .xai,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 6),
            metadata: ProviderMetadata(
                id: .xai,
                displayName: "xAI",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show xAI usage",
                cliName: "xai",
                defaultEnabled: false,
                widgetSelectable: false,
                debugLogUnavailableMessage: "xAI debug log not yet implemented",
                dashboardURL: "https://console.x.ai",
                statusPageURL: nil,
                statusLinkURL: "https://status.x.ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .xai),
                iconResourceName: "ProviderIcon-xai",
                color: ProviderColor(red: 142 / 255, green: 142 / 255, blue: 147 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x1A1A1A),
                    ProviderColor(hex: 0x8E8E93),
                    ProviderColor(hex: 0xF5F5F7),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "xAI spend history comes from the Management API billing endpoints." }),
            presentation: ProviderUsagePresentation(
                identityPresenter: { provider, snapshot in
                    guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    let display = UsageFormatter.cleanPlanName(plan)
                    return ProviderIdentityPresentation(badge: display, plan: display)
                },
                costPresenter: { snapshot in
                    let showsFallback = snapshot.providerCost?.period != "Prepaid credits"
                    let style: ProviderCostMenuCardStyle = showsFallback ? .generic : .prepaidCredits
                    return ProviderCostPresentation(showsGenericFallback: showsFallback, menuCardStyle: style)
                }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "xai",
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let swift = XAIAPIFetchStrategy()
                #if canImport(JavaScriptCore)
                guard ProviderPluginPrototype.isEnabled(environment: context.env) else { return [swift] }
                return [
                    ScriptFetchStrategy(
                        id: "xai.js",
                        provider: .xai,
                        bundledPlugin: "xai",
                        secretKey: XAISettingsReader.apiKeyEnvironmentKey,
                        resolveValues: { context in
                            guard let key = XAISettingsReader.apiKey(environment: context.env),
                                  let teamID = XAISettingsReader.teamID(environment: context.env)
                            else { return nil }
                            return ScriptFetchStrategy.Values(
                                settings: [XAISettingsReader.teamIDEnvironmentKey: teamID],
                                secrets: [XAISettingsReader.apiKeyEnvironmentKey: key])
                        }),
                    swift,
                ]
                #else
                return [swift]
                #endif
            }))
    }
}

struct XAIAPIFetchStrategy: ProviderFetchStrategy {
    let id = "xai.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        XAISettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let key = XAISettingsReader.apiKey(environment: context.env) else {
            throw XAIBillingError.notConfigured
        }
        guard let teamID = XAISettingsReader.teamID(environment: context.env) else {
            throw XAIBillingError.missingTeamID
        }
        let usage = try await XAIBillingFetcher.fetchUsage(managementKey: key, teamID: teamID)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
