import Foundation

public enum SyntheticProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .synthetic,
        displayName: "Synthetic",
        sessionLabel: "Five-hour quota",
        weeklyLabel: "Weekly tokens",
        opusLabel: "Search hourly",
        creditsHint: "Weekly token quota regenerates continuously.",
        sharePlanLabels: ["starter": "Starter", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"],
        dashboardURL: nil,
        color: ProviderColor(hex: 0x141414),
        confetti: [0x6366F1, 0x3E3E3E, 0xF7F6F3],
        noDataMessage: "Synthetic cost summary is not supported.",
        environmentKey: SyntheticSettingsReader.apiKeyKey,
        missingCredentialMessage: { _ in SyntheticSettingsError.missingToken.errorDescription },
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .hidden) },
            menuCard: ProviderMenuCardPresentation(usesSyntheticRollingRegen: true)),
        aliases: ["synthetic.new"],
        apiKeyField: .init(
            id: "synthetic-api-key",
            title: "API key",
            subtitle: "Stored in ~/.codexbar/config.json. Paste the key from the Synthetic dashboard.",
            placeholder: "Paste key…"),
        showsAPIDetail: true,
        availability: .configuredKey)
}
