import Foundation

public enum ClawRouterProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .clawrouter,
        displayName: "ClawRouter",
        sessionLabel: "Monthly budget",
        weeklyLabel: "Requests",
        debugLogUnavailableMessage: "ClawRouter debug log not yet implemented",
        dashboardURL: "https://clawrouter.openclaw.ai/dashboard/access",
        color: ProviderColor(hex: 0x596EF6),
        confetti: [0x332CB3, 0x456FDD, 0xFFFFFF],
        noDataMessage: "ClawRouter spend is reported by its usage API.",
        environmentKey: ClawRouterSettingsReader.apiKeyEnvironmentKey,
        missingCredentialMessage: { _ in ClawRouterSettingsReader.missingCredentialsMessage },
        additionalProjections: [.enterpriseHost(ClawRouterSettingsReader.baseURLEnvironmentKey)],
        config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
        presentation: ProviderUsagePresentation(costPresenter: { _ in
            ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .clawRouter)
        }),
        aliases: ["claw-router"],
        scriptSettings: { context in
            [ClawRouterSettingsReader.baseURLEnvironmentKey:
                ClawRouterSettingsReader.baseURL(environment: context.env).absoluteString]
        },
        validateContext: { try ClawRouterSettingsReader.validateEndpointOverride(environment: $0.env) })
}
