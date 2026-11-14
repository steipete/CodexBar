import Foundation

public enum XAIProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .xai,
        displayName: "xAI",
        sessionLabel: "Spend",
        weeklyLabel: "Spend",
        debugLogUnavailableMessage: "xAI debug log not yet implemented",
        dashboardURL: "https://console.x.ai",
        statusLinkURL: "https://status.x.ai",
        color: ProviderColor(hex: 0x8E8E93),
        confetti: [0x1A1A1A, 0x8E8E93, 0xF5F5F7],
        noDataMessage: "xAI daily spend requires a Management API key and team ID. "
            + "Prepaid balance is not treated as spend.",
        supportsTokenCost: true,
        isCostUsageUnavailable: { XAICostUsageMapping.isAnalyticsUnavailable($0) },
        environmentKey: XAISettingsReader.apiKeyEnvironmentKey,
        config: ProviderConfigCapabilities(workspaceIDValidationOrder: 6),
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
            optionalDetails: ProviderOptionalDetailsPresentation(costSummaryTitles: ["Billing summary"])),
        validateContext: { context in
            _ = try XAISettingsReader.validatedTeamID(environment: context.env)
        },
        apiKeyField: .init(
            id: "xai-management-api-key",
            title: "Management API key",
            subtitle: "Stored in ~/.codexbar/config.json. Create one at console.x.ai under "
                + "Settings > Management Keys; inference API keys are not accepted.",
            placeholder: "xai-..."),
        workspaceField: .init(
            environmentKey: XAISettingsReader.teamIDEnvironmentKey,
            field: .init(
                id: "xai-team-id",
                title: "Team ID",
                subtitle: "Required. Shown in the xAI Console URL and team settings.",
                placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")),
        showsAPIDetail: true,
        availability: .configuredKey)
}
