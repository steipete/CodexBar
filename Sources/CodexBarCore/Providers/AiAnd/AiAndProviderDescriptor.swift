import Foundation

public enum AiAndProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .aiand,
        displayName: "ai&",
        sessionLabel: "Spend",
        weeklyLabel: "Spend",
        debugLogUnavailableMessage: "ai& debug log not yet implemented",
        dashboardURL: "https://console.aiand.com",
        color: ProviderColor(hex: 0xE25C2B),
        confetti: [0xE25C2B, 0xF2A17E, 0x33231C],
        noDataMessage: "ai& spend is summed from the request logs API.",
        environmentKey: "AIAND_API_KEY",
        presentation: ProviderUsagePresentation(costPresenter: { snapshot in
            let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0 ? .apiSpend : .generic
            return ProviderCostPresentation(menuCardStyle: style)
        }),
        aliases: ["ai&", "ai-and"],
        validateContext: { context in
            guard AiAndSettingsReader.apiKey(environment: context.env) != nil else {
                throw ProviderFetchClassifiedError(
                    kind: .missingCredential,
                    message: "Missing ai& API key. Add one in Settings or set AIAND_API_KEY.")
            }
        },
        apiKeyField: .init(
            id: "aiand-api-key",
            title: "API key",
            subtitle: "Stored in CodexBar's config file. Create a key in the ai& console (shown once).",
            placeholder: "sk-…",
            action: ("aiand-open-console", "Open ai& Console", "https://console.aiand.com")),
        showsAPIDetail: true,
        availability: .configuredKey)

    static func scriptStrategy(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy
    {
        self.spec.makeStrategy(transport: transport)
    }
}
