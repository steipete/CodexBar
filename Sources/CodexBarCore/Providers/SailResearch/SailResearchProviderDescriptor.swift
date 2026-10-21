import Foundation

public enum SailResearchProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .sailresearch,
        displayName: "Sail Research",
        sessionLabel: "Balance",
        weeklyLabel: "Spend",
        toggleTitle: "Show Sail Research balance",
        balanceOnly: true,
        dashboardURL: "https://app.sailresearch.com",
        color: .init(hex: 0x2C4681),
        confetti: [0x2C4681, 0x6266D1],
        noDataMessage: "Sail Research cost history is not available.",
        environmentKey: "SAIL_API_KEY",
        missingCredentialMessage: { _ in "Set a Sail Research API key in Settings or SAIL_API_KEY." },
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Credit balance"]),
        apiKeyField: .init(
            id: "sailresearch-api-key",
            title: "Sail Research API key",
            subtitle: "Saved in CodexBar's local config file. Or set SAIL_API_KEY."))
}
