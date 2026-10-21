import Foundation

public enum ExaProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .exa,
        displayName: "Exa",
        sessionLabel: "Spend",
        weeklyLabel: "Spend",
        dashboardURL: "https://dashboard.exa.ai/api-keys",
        color: .init(hex: 0x0143D9),
        confetti: [0x0143D9, 0x8CAFFF],
        noDataMessage: "No cost history data.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: "EXA_SERVICE_KEY",
        missingCredentialMessage: { _ in
            "Set an Exa Team Management service key and API key ID in Settings or EXA_SERVICE_KEY and EXA_API_KEY_ID."
        },
        menuBarMetrics: .automaticOnly,
        apiKeyField: .init(
            id: "exa-service-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file."),
        workspaceField: .init(
            environmentKey: "EXA_API_KEY_ID",
            field: .init(
                id: "exa-api-key-id",
                title: "Scope",
                subtitle: "Stored in the CodexBar config file.",
                placeholder: nil)))
}
