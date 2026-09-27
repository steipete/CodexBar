import Foundation

public enum ChutesProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .chutes,
        displayName: "Chutes",
        sessionLabel: "4-hour quota",
        weeklyLabel: "Monthly quota",
        creditsHint: "Subscription usage from the Chutes API.",
        debugLogUnavailableMessage: "Chutes debug log not yet implemented",
        usesDetailBackedWindow: true,
        dashboardURL: "https://chutes.ai",
        color: ProviderColor(hex: 0x3184FF),
        confetti: [0x121212, 0xFFFFFF, 0x63D297],
        widgetColor: ProviderColor(hex: 0x18A058),
        noDataMessage: "Chutes cost history is not available from CodexBar.",
        environmentKey: ChutesSettingsReader.apiKeyEnvironmentKey,
        presentation: ProviderUsagePresentation(
            primaryBindingQuotaLanes: [.secondary],
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                showsSecondaryBalanceDescription: true,
                hidesPrimaryResetWithoutDate: true),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true },
                secondaryDescriptionMode: .detailWhenResetDatePresent)),
        aliases: ["chutes.ai"],
        scriptSettings: { ["BASE_URL": ChutesSettingsReader.apiURL(environment: $0.env).absoluteString] },
        validateContext: { context in
            guard ChutesSettingsReader.apiKey(environment: context.env) != nil else {
                throw ProviderFetchClassifiedError(
                    kind: .missingCredential,
                    message: ChutesSettingsError.missingToken.localizedDescription)
            }
            try ChutesSettingsReader.validateEndpointOverrides(environment: context.env)
        },
        apiKeyField: .init(
            id: "chutes-api-key",
            title: "API key",
            subtitle: "Stored in ~/.codexbar/config.json. Paste a Chutes API key.",
            placeholder: "chutes key..."),
        showsAPIDetail: true,
        availability: .configuredKey)
}
