import Foundation

public enum SofyaProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .sofya,
        displayName: "Sofya",
        sessionLabel: "Credits",
        weeklyLabel: "Credits",
        toggleTitle: "Show Sofya credits",
        balanceOnly: true,
        dashboardURL: "https://sofya.co/dashboard",
        color: .init(hex: 0xB0B820),
        confetti: [0xB0B820, 0xE8A820],
        noDataMessage: "Sofya cost history is not available.",
        environmentKey: "SOFYA_API_KEY",
        missingCredentialMessage: { _ in "Set a Sofya API key in Settings or SOFYA_API_KEY." },
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Available credits"]),
        apiKeyField: .init(
            id: "sofya-api-key",
            title: "Sofya API key",
            subtitle: "Saved in CodexBar's local config file. Or set SOFYA_API_KEY.",
            action: ("sofya-dashboard", "Open Sofya", "https://sofya.co/dashboard")))
}
