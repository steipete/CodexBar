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
                supportsTokenCost: true,
                noDataMessage: {
                    "xAI daily spend requires a Management API key and team ID. "
                        + "Prepaid balance is not treated as spend."
                }),
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
                },
                optionalDetails: ProviderOptionalDetailsPresentation(
                    costSummaryTitles: ["Billing summary"])),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "xai",
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "xai.js",
                    provider: .xai,
                    bundledPlugin: "xai",
                    secretKey: XAISettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    validateContext: { context in
                        _ = try XAISettingsReader.validatedTeamID(environment: context.env)
                    },
                    resolveValues: { context in
                        guard let key = XAISettingsReader.apiKey(environment: context.env) else { return nil }
                        let settings = XAISettingsReader.teamID(environment: context.env).map {
                            [XAISettingsReader.teamIDEnvironmentKey: $0]
                        } ?? [:]
                        return ScriptFetchStrategy.Values(
                            settings: settings,
                            secrets: [XAISettingsReader.apiKeyEnvironmentKey: key])
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
