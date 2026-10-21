import Foundation

public enum MunitoProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .munito,
        displayName: "Munito",
        sessionLabel: "Today",
        weeklyLabel: "This month",
        toggleTitle: "Show Munito usage",
        dashboardURL: "https://console.munito.ai",
        color: .init(hex: 0x702CF6),
        confetti: [0x702CF6, 0x9A68FA],
        noDataMessage: "Munito reports Admin API spend and limits, not local token cost history.",
        environmentKey: "MUNITO_API_KEY",
        environmentAliases: ["MUNITO_ADMIN_KEY"],
        missingCredentialMessage: { _ in "Set a Munito admin API key in Settings or MUNITO_API_KEY." },
        menuBarMetrics: .init(supported: [.automatic, .primary, .secondary, .extraUsage]),
        apiKeyField: .init(
            id: "munito-api-key",
            title: "Admin API key",
            subtitle: "Key with Read account data (Admin API) permission. Or set MUNITO_API_KEY.",
            action: ("munito-api-keys", "Open Munito API keys", "https://console.munito.ai/keys")))
}
