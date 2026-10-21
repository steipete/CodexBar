import Foundation

public enum FalProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .fal,
        displayName: "fal",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        toggleTitle: "Show fal balance",
        balanceOnly: true,
        dashboardURL: "https://fal.ai/dashboard/billing",
        color: .init(hex: 0x7C3AED),
        confetti: [0x7C3AED, 0xC4B5FD],
        noDataMessage: "No cost history data.",
        environmentKey: "FAL_KEY",
        missingCredentialMessage: { _ in "Set a fal API key with billing read access in Settings or FAL_KEY." },
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Credit balance"]),
        apiKeyField: .init(
            id: "fal-api-key",
            title: "API key",
            subtitle: "Key with billing read access (BILLING or READONLY preset). Or set FAL_KEY.",
            action: ("fal-api-keys", "Open fal API keys", "https://fal.ai/dashboard/keys")))
}
