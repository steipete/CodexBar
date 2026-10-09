import Foundation

public enum LinkupProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .linkup,
        displayName: "Linkup",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        toggleTitle: "Show Linkup balance",
        balanceOnly: true,
        dashboardURL: "https://app.linkup.so/organization/billing",
        color: .init(hex: 0x202020),
        confetti: [0x202020, 0x8C8C8C],
        noDataMessage: "No cost history data.",
        environmentKey: "LINKUP_API_KEY",
        missingCredentialMessage: { _ in "Set a Linkup API key in Settings or LINKUP_API_KEY." },
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Credit balance"]),
        apiKeyField: .init(
            id: "linkup-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file."))
}
