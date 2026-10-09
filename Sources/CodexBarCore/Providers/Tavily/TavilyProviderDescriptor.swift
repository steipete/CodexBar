import Foundation

public enum TavilyProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .tavily,
        displayName: "Tavily",
        sessionLabel: "Plan credits",
        weeklyLabel: "API key",
        dashboardURL: "https://app.tavily.com",
        color: .init(hex: 0x78B0A1),
        confetti: [0x78B0A1, 0x817FFF],
        noDataMessage: "No cost history data.",
        environmentKey: "TAVILY_API_KEY",
        missingCredentialMessage: { _ in "Set a Tavily API key in Settings or TAVILY_API_KEY." },
        apiKeyField: .init(
            id: "tavily-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file."))
}
