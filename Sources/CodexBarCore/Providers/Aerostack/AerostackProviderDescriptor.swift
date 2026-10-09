import Foundation

public enum AerostackProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .aerostack,
        displayName: "Aerostack",
        sessionLabel: "Monthly AI tokens",
        weeklyLabel: "Weekly",
        dashboardURL: "https://app.aerostack.dev/settings/billing",
        color: .init(hex: 0x6366F1),
        confetti: [0x6366F1, 0xA5B4FC],
        noDataMessage: "Aerostack cost history is not available.",
        environmentKey: "AEROSTACK_TOKEN",
        missingCredentialMessage: { _ in "Set an Aerostack account JWT in Settings or AEROSTACK_TOKEN." },
        menuBarMetrics: .init(supported: [.automatic, .primary]),
        apiKeyField: .init(
            id: "aerostack-token",
            title: "Account JWT",
            subtitle: "Saved in CodexBar's local config file. Replace when expired; CodexBar does not refresh it.",
            placeholder: "Account JWT, not an Agent Endpoint key"),
        availability: .configuredKey)
}
