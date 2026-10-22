import Foundation

public enum SonioxProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .soniox,
        displayName: "Soniox",
        sessionLabel: "Monthly budget",
        weeklyLabel: "Usage",
        dashboardURL: "https://console.soniox.com",
        statusLinkURL: "https://status.soniox.com",
        color: ProviderColor(hex: 0x253772),
        confetti: [0x253772, 0xFFFFFF],
        progressColorStyle: .label,
        noDataMessage: "No cost history data.",
        environmentKey: "SONIOX_ORG_API_KEY",
        missingCredentialMessage: { _ in
            "Set a Soniox organization API key in Settings or SONIOX_ORG_API_KEY. Project API keys are not supported."
        },
        menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in
                ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .payAsYouGoSpend)
            },
            menuBarBalanceUsesPrepaidCost: true,
            menuCard: ProviderMenuCardPresentation(
                providerCostIsRequiredUsage: true,
                defaultHiddenUsageItemIDs: ["metric:primary"],
                primaryDescriptionPlacement: .detail,
                hidesPrimaryResetWithoutDate: true)),
        apiKeyField: .init(
            id: "soniox-organization-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file.",
            action: (
                id: "soniox-api-key-guide",
                title: "Open API Keys",
                url: "https://soniox.com/docs/guides/organization-api#organization-api-keys")),
        showsAPIDetail: true,
        availability: .configuredKey)
}
